# Incremental Rendering: Approaches and Trade-offs

Issue: #97

## Problem Statement

Every UI event triggers a full clear-and-rebuild cycle. `Bridge.clear` destroys
all native views, `resetCallbacks` wipes the Haskell callback registry (including
resetting the ID counter to 0), and the entire widget tree is recreated from
scratch via `renderNode`.

For a screen with 50 widgets where only 1 counter label changes, this means
50 `destroyNode` calls + 50 `createNode` calls + ~150 property-setting calls.
On Android, each FFI call crosses JNI, which adds overhead per call. More
importantly, destroying and recreating native views can cause visible flicker,
loss of focus state in TextInput fields, and scroll position resets in
ScrollViews.

The goal: diff old and new widget trees and emit only minimal bridge operations.

## Current Architecture (Baseline)

```
User event
  -> Haskell callback fires
  -> callback calls renderWidget
  -> Bridge.clear (destroy ALL native views)
  -> resetCallbacks (wipe IntMaps, reset rsNextId to 0)
  -> renderNode (walk entire Widget tree, create all native views)
  -> Bridge.setRoot
```

Key types on master:

```haskell
-- Widget.hs: no type parameter, callbacks are bare IO
data ButtonConfig = ButtonConfig
  { bcLabel  :: Text
  , bcAction :: IO ()            -- can't derive Eq
  , bcFontConfig :: Maybe FontConfig
  }

data Widget
  = Text TextConfig              -- has Eq (no callbacks)
  | Button ButtonConfig          -- no Eq (IO () field)
  | TextInput TextInputConfig    -- no Eq (Text -> IO () field)
  | Column [Widget]
  | ...

-- Render.hs: full rebuild every time
renderWidget :: RenderState -> Widget -> IO ()
renderWidget rs widget = do
  Bridge.clear
  resetCallbacks rs
  rootId <- renderNode rs widget
  Bridge.setRoot rootId
```

The fundamental blocker for diffing is that `Widget` can't derive `Eq` because
`ButtonConfig`, `TextInputConfig`, and `WebViewConfig` contain `IO ()` /
`Text -> IO ()` callbacks. Without equality comparison, you can't tell whether
a widget has changed.

## The Core Dilemma: Comparing Widgets That Contain Callbacks

Any incremental rendering approach must solve: "Has this widget changed since
last render?" Five approaches are considered below.

---

## Approach A: Trees That Grow (TTG) + toUnit Stripping

**Branch:** `feature/incremental-render` (PR #125)

### Mechanism

Parameterise `Widget` over a phase type `p`. Use closed type families to resolve
callback types per phase:

```haskell
data User  -- user-facing phase

type family ButtonCb p where
  ButtonCb User = IO ()
  ButtonCb p    = p

data ButtonConfig p = ButtonConfig
  { bcLabel  :: Text
  , bcAction :: ButtonCb p
  , bcFontConfig :: Maybe FontConfig
  }

data Widget p = Text TextConfig | Button (ButtonConfig p) | ...

deriving instance Eq (Widget ())  -- all callbacks become (), which has Eq
```

Strip callbacks with `toUnit :: Widget p -> Widget ()`, then compare:

```haskell
toUnit newWidget == storedUnitWidget  -- structural equality
```

A retained `RenderedNode` tree maps each widget to its native node ID and
callback ID. On re-render: walk both trees in lockstep, compare via `toUnit`,
skip unchanged subtrees, destroy/create only what changed.

### Strengths

- **Compiler-verified completeness:** `toUnit` constructs records field-by-field.
  Adding a field without updating `toUnit` causes a compile error. Derived `Eq`
  covers all fields automatically.
- **No user-visible API change in construction syntax:** `ButtonCb User = IO ()`,
  so existing `Button ButtonConfig { bcAction = putStrLn "hi" }` works unchanged.
- **Clean phase separation:** Could later use `Widget Int32` for a phase where
  callbacks are registered IDs rather than closures.

### Weaknesses

1. **Callback atomicity gap:** The implementation clears both callback IntMaps at
   the start of each render (`clearCallbackMaps`), then re-registers callbacks as
   the diff walk proceeds. If a native event fires during this window, the
   callback ID maps to nothing and the event is silently dropped. This is the main
   fragility concern.

2. **Over-comparison on every render:** `toUnit` allocates a full `Widget ()` mirror
   of the tree on every render cycle, just to compare it. For a 500-widget tree,
   that's 500 allocations even if nothing changed. Haskell's GC handles short-lived
   allocations well, but it's still work.

3. **No in-place property patching:** When a Text label changes from "Count: 5" to
   "Count: 6", the current implementation destroys the old Text node and creates a
   new one. It should instead call `setStrProp` on the existing node. This requires
   comparing individual properties, not just whole-widget equality — but `toUnit`
   only gives a binary same/different answer.

4. **Type signature pollution:** Every function touching a `Widget` gains a phase
   parameter (`Widget User` instead of `Widget`). All 16 demo apps, the test suite,
   and downstream consumers must update signatures. The change is mechanical but
   wide-reaching.

5. **Callback ID growth:** `rsNextId` monotonically increases and never reclaims
   IDs. After thousands of renders with changing widgets, the counter grows
   unboundedly. The IntMap itself is rebuilt each render so memory is bounded, but
   native view tags may hit platform limits on some implementations.

---

## Approach B: Explicit Widget Keys + Keyed Diffing

### Mechanism

Add an optional user-supplied key to each widget, similar to React's `key` prop:

```haskell
data Widget
  = Text TextConfig
  | Button ButtonConfig
  | Keyed Text Widget    -- user-supplied stable identity
  | ...
```

The renderer maintains a `Map Text NativeNodeId`. On re-render, instead of
comparing widget equality, match widgets by key. Matched widgets get in-place
property updates; unmatched ones get destroyed/created.

For keyless widgets, fall back to positional matching (same index in the child
list = same widget).

### Strengths

- **No type system changes:** `Widget` stays as-is, no phase parameter, no
  type families.
- **User controls identity:** Keys express intent ("this is the same counter")
  rather than structural equality ("these two trees look the same").
- **Natural property patching:** Since you know *which* old node corresponds to
  which new widget, you can diff individual properties and emit `setStrProp`
  calls for just what changed.
- **Familiar pattern:** React, Flutter, and SwiftUI all use keys/identity for
  reconciliation.

### Weaknesses

- **User burden:** Users must remember to add keys to dynamic lists, or diffs
  produce pathological results (same problem React has).
- **No compiler enforcement:** Forgetting a key silently falls back to
  positional matching, which can produce subtle bugs with reordering.
- **Callback comparison still unsolved:** Two `ButtonConfig` values with the
  same label but different `IO ()` callbacks look identical to a key-based diff.
  The renderer must always re-register callbacks even for "unchanged" widgets.
  This is fine in practice (re-registering a closure in an IntMap is cheap)
  but means the Haskell side always does O(n) work.
- **Not clear how to handle `Styled`:** A `Styled` wrapper changes visual
  properties without changing identity. Key-based matching would need to
  look through `Styled` to find the keyed child.

---

## Approach C: Generation Counter (Dirty Flagging)

### Mechanism

Instead of comparing the full widget tree, track *which* parts of the state
changed and only re-render those subtrees:

```haskell
data RenderState = RenderState
  { rsGeneration    :: IORef Word64
  , rsDirtyWidgets  :: IORef (Set WidgetPath)
  , rsNativeNodes   :: IORef (Map WidgetPath Int32)
  , ...
  }

-- When state changes, mark the affected widget path as dirty
markDirty :: RenderState -> WidgetPath -> IO ()

-- Re-render only walks dirty paths
renderWidget :: RenderState -> Widget -> IO ()
```

The app's state management layer (currently just `IORef UserState`) would need
to integrate with the dirty-tracking system.

### Strengths

- **Minimal work on each render:** Only dirty subtrees are visited at all.
  No tree walk, no allocation of comparison structures.
- **No type system changes** to `Widget`.
- **Scales well:** O(dirty nodes) instead of O(total nodes).

### Weaknesses

- **Invasive to user code:** The user must explicitly mark dirty paths or use
  a state management system that does it automatically. This is a fundamentally
  different programming model (push-based vs pull-based).
- **WidgetPath fragility:** Paths like `[Column, 0, Row, 2, Button]` break
  when the tree structure changes (e.g., wrapping a widget in a Styled node).
- **Missed updates:** If the dirty tracking fails to mark a node, the UI is
  silently stale. Hard to debug.
- **Doesn't leverage Haskell's strengths:** Haskell's pure functions naturally
  produce new widget trees. Dirty tracking fights this by requiring imperative
  mutation tracking alongside the pure view function.

---

## Approach D: Stable Callback IDs (User-Assigned)

### Mechanism

Instead of the renderer assigning callback IDs, the user provides stable IDs
at widget construction:

```haskell
data ButtonConfig = ButtonConfig
  { bcLabel      :: Text
  , bcCallbackId :: CallbackId    -- user-assigned, stable across renders
  , bcAction     :: IO ()
  , bcFontConfig :: Maybe FontConfig
  }

-- Callbacks registered separately from the widget tree
registerCallback :: RenderState -> CallbackId -> IO () -> IO ()
```

The widget tree becomes pure data (no IO callbacks inline), and can derive `Eq`
naturally. The renderer diffs the pure tree and emits bridge calls. Callbacks
are managed in a separate registry keyed by stable IDs.

### Strengths

- **Widget derives Eq naturally:** No phase parameter, no type families,
  no toUnit.
- **Callback stability for free:** Native views keep the same callback ID
  tag across renders because the user assigned it.
- **Clean separation of concerns:** View description (pure) vs event handling
  (separate registration) — similar to Elm architecture.
- **No atomicity gap:** Callback IntMaps are never cleared, only updated.

### Weaknesses

- **Significant API change:** Users must manage callback IDs manually. This
  is error-prone and boilerplate-heavy: `bcCallbackId = CallbackId "increment-btn"`.
- **Namespace collisions:** If two widgets accidentally share a callback ID,
  one silently overwrites the other.
- **Stale callbacks:** If a widget is removed but its callback isn't
  unregistered, the IntMap leaks closures that reference stale state.
- **Doesn't match React/Flutter mental model:** Modern UI frameworks let you
  write callbacks inline. Extracting them to a separate registry is ergonomic
  regression.

---

## Approach E: Hybrid — Structural Comparison Function + Callback Re-registration

### Mechanism

Write a manual `structuralEq :: Widget -> Widget -> Bool` that compares all
fields except callbacks:

```haskell
structuralEq :: Widget -> Widget -> Bool
structuralEq (Text c1) (Text c2) = c1 == c2
structuralEq (Button c1) (Button c2) =
  bcLabel c1 == bcLabel c2 && bcFontConfig c1 == bcFontConfig c2
structuralEq (Column cs1) (Column cs2) =
  length cs1 == length cs2 && and (zipWith structuralEq cs1 cs2)
structuralEq _ _ = False
```

No type system changes. The retained tree stores old widgets and their native
node IDs. On re-render, walk both trees, use `structuralEq` to detect changes,
and always re-register callbacks from the new tree.

### Strengths

- **No type changes at all:** `Widget` stays exactly as-is. No downstream
  signature changes.
- **Simple to understand:** One function, one concept.
- **Can do property-level patching:** Since `structuralEq` examines fields
  individually, it could also return *which* fields changed and emit targeted
  `setStrProp` / `setNumProp` calls.

### Weaknesses

- **Not compiler-verified:** Adding a new field to `ButtonConfig` without
  updating `structuralEq` silently misses that field in comparisons. This is
  the main argument against this approach — it's the kind of bug that only
  manifests at runtime.
- **Maintenance burden:** Every new widget type or config field requires
  updating `structuralEq`. With TTG, derived `Eq` handles this automatically.
- **Still needs callback re-registration:** Even when `structuralEq` says
  "unchanged", the renderer must re-register callbacks because the closures
  may have captured new state. Same O(n) callback overhead as Approach B.

---

## Comparison Matrix

| Concern | A: TTG | B: Keys | C: Dirty | D: Stable IDs | E: Manual Eq |
|---|---|---|---|---|---|
| Compiler-verified | Yes (derived Eq) | N/A | N/A | Yes (derived Eq) | No |
| Type signature changes | Yes (`Widget User`) | No | No | Yes (`CallbackId`) | No |
| User API change | Minimal (signatures only) | Keys on dynamic lists | State management | Major (ID assignment) | None |
| Callback atomicity | Gap exists | N/A (always re-register) | N/A | No gap | N/A (always re-register) |
| Property-level patching | No (binary equal/not) | Yes | Yes | Yes | Yes |
| GC pressure per render | O(n) toUnit allocation | Low | O(dirty) | Low | Low |
| Missed-field risk | None | None | N/A | None | High |
| Familiar to React/Flutter devs | No | Yes | Somewhat | No | No |

## Bridge API Constraints

Any approach must work within the existing C bridge (`UIBridge.h`):

- `createNode(nodeType) -> nodeId` — allocates a native view, returns ID
- `setStrProp(nodeId, propId, value)` — set a string property on existing node
- `setNumProp(nodeId, propId, value)` — set a numeric property on existing node
- `setHandler(nodeId, eventType, callbackId)` — associate a callback ID with a node
- `addChild(parentId, childId)` / `removeChild(parentId, childId)` — tree structure
- `destroyNode(nodeId)` — free a native view
- `setRoot(nodeId)` — set the display root
- `clear()` — destroy all nodes

Notably, the bridge already supports `setStrProp` / `setNumProp` on existing
nodes and `removeChild` / `destroyNode` for targeted mutations. The current
renderer just doesn't use them — it always clears everything and rebuilds.

Property-level patching (calling `setStrProp` to update just a label) is
already supported by the bridge and would be the most efficient approach.
Approaches B, D, and E naturally support this. Approach A would need additional
per-field comparison logic beyond `toUnit` equality.

## Callback Lifecycle: The Central Challenge

All approaches share a tension between two requirements:

1. **Callback closures must reflect current state.** A button's `IO ()` action
   typically closes over an `IORef` or `MVar` — the closure itself may be
   identical across renders, or the user may construct a fresh closure each
   time (e.g., `bcAction = modifyIORef' counter (+ amount)` where `amount`
   changes). We can't compare closures, so we must assume they always change.

2. **Native views carry callback ID tags.** When the user taps a button,
   Android/iOS sends the callback ID back to Haskell. The Haskell side looks
   up the ID in an IntMap to find the closure.

The safest lifecycle is:
- Build the new callback IntMap during the diff walk
- Swap the new IntMap into the RenderState atomically after the walk completes
- Never clear + rebuild with a gap in between

This eliminates the atomicity gap from Approach A and applies to any approach.

## Recommendation

No single approach is clearly superior. Key considerations:

- If **type safety** is the priority (can't forget a field), Approach A (TTG)
  or D (Stable IDs) provide compiler verification. A is less invasive to user
  code.
- If **minimal API churn** is the priority, Approach E (manual structuralEq)
  or B (keys) avoid type parameter changes entirely.
- If **performance** is the priority (minimal work per render), Approach C
  (dirty flagging) does the least work but requires the most invasive changes
  to the programming model.
- Approach A's atomicity gap should be fixed regardless — building new IntMaps
  and swapping at the end is strictly better than clear-then-rebuild.
- Property-level patching (`setStrProp` on the existing node instead of
  destroy+create) gives the biggest real-world performance win and is
  independent of which diffing strategy is chosen.

A pragmatic path forward might combine elements: use TTG for the type-safe
comparison foundation (Approach A), add property-level patching to avoid
unnecessary destroy/create, and fix the callback atomicity gap by building
new maps during the walk and swapping at the end.
