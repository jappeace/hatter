{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
-- | Rendering engine that converts a 'Widget' tree into native UI
-- via the C bridge.
--
-- Uses an incremental diff strategy: on each render, the new widget
-- tree is compared (via derived 'Eq') against the previously rendered
-- tree.  Only changed subtrees are destroyed and recreated; unchanged
-- nodes keep their native views.
--
-- Callbacks are stored in a shared 'ActionState' registry that is
-- never cleared during rendering — handles inside widget configs
-- reference stable entries in the registry.
module Hatter.Render
  ( RenderState(..)
  , RenderedNode(..)
  , renderedNodeId
  , newRenderState
  , renderWidget
  , resetRender
  , dispatchEvent
  , dispatchTextEvent
  , reattachments
  , bindLazyRow
  , lazyItemKey
  , dispatchScrollEvent
  )
where

import           Control.Monad         (unless, when)
import           Data.Foldable         (asum)
import           Data.Int              (Int32)
import           Data.IntMap.Strict    (IntMap)
import qualified Data.IntMap.Strict    as IntMap
import           Data.IntSet           (IntSet)
import qualified Data.IntSet           as IntSet
import           Data.IORef            (IORef, newIORef, readIORef, writeIORef)
import           Data.List             (sortBy)
import           Data.Maybe            (isNothing)
import           Data.Ord              (comparing)
import           Data.Sequence         (Seq)
import qualified Data.Sequence         as Seq
import           Data.Text             (Text, pack)
import           Data.Time.Clock       (NominalDiffTime)
import           Hatter.Action         (Action (..), ActionState, OnChange (..),
                                        OnScroll (..), lookupAction,
                                        lookupScrollAction, lookupTextAction)
import           Hatter.Animation      (AnimationState (..), registerTween)
import           Hatter.Style          (applyStyle, clearStyle)
import           Hatter.Widget         (AnimatedConfig (..), ButtonConfig (..),
                                        Color (..),
                                        FontConfig (..), FontFamily (..),
                                        FontSlant (..), FontWeight (..),
                                        ImageConfig (..), ImageSource (..),
                                        InputType (..), Keyframe (..),
                                        LayoutItem (..), LayoutSettings (..),
                                        MapViewConfig (..), ResourceName (..),
                                        ScaleType (..),
                                        SwitchConfig (..),
                                        TextConfig (..),
                                        TextInputConfig (..),
                                        WebViewConfig (..), Widget (..),
                                        WidgetStyle (..), colorToHex,
                                        normalizeAnimated, resolveKeyAtIndex)
import qualified Unwitch.Convert.Int   as Int
import qualified Unwitch.Convert.Int32 as Int32

import qualified Hatter.UIBridge       as Bridge
import           System.IO             (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Rendered tree: retained structure for incremental diffing
-- ---------------------------------------------------------------------------

-- | A snapshot of a rendered widget, retaining the widget value
-- (for equality comparison) and native node IDs.
data RenderedNode
  = RenderedLeaf
      Widget         -- ^ Widget value for equality comparison.
      Int32          -- ^ Native node ID from the platform bridge.
  | RenderedContainer
      Widget              -- ^ Widget value (Column/Row/Stack with children).
      Int32               -- ^ Native node ID.
      [(Int, RenderedNode)] -- ^ Rendered children, keyed by resolved WidgetKey value.
  | RenderedStyled
      Widget         -- ^ Widget value (Styled wrapper).
      WidgetStyle    -- ^ Applied style (for change detection).
      RenderedNode   -- ^ Child (Styled doesn't own a native node).
  | RenderedAnimated
      Widget         -- ^ Full Animated widget (Animated config child) for Eq comparison.
      RenderedNode   -- ^ Child's rendered node (owns native node IDs).
  | RenderedHandler
      Widget         -- ^ Widget value ('Tappable', 'LongPressable' or 'Scrolled').
      RenderedNode   -- ^ Child, whose node has the handler.
  | RenderedLazy
      Widget         -- ^ Widget value (LazyColumn with its items).
      Int32          -- ^ Native node ID of the list.
      LazyRows       -- ^ What its rows show, filled as the platform asks.

-- | A 'LazyColumn''s items, and the rows the platform made for it so far,
-- each a native column node with the position and item it shows last.
data LazyRows = LazyRows
  { lrItems :: IORef (Seq LayoutItem)
  , lrRows  :: IORef (IntMap (Int, RenderedNode))
  }

-- | Get the native node ID for a rendered node.
-- 'RenderedStyled' follows through to its child's node ID.
renderedNodeId :: RenderedNode -> Int32
renderedNodeId (RenderedLeaf _ nodeId)        = nodeId
renderedNodeId (RenderedContainer _ nodeId _) = nodeId
renderedNodeId (RenderedStyled _ _ child)     = renderedNodeId child
renderedNodeId (RenderedAnimated _ child)     = renderedNodeId child
renderedNodeId (RenderedHandler _ child)      = renderedNodeId child
renderedNodeId (RenderedLazy _ nodeId _)      = nodeId

-- | Get the widget value for a rendered node.
renderedWidget :: RenderedNode -> Widget
renderedWidget (RenderedLeaf widget _)        = widget
renderedWidget (RenderedContainer widget _ _) = widget
renderedWidget (RenderedStyled widget _ _)    = widget
renderedWidget (RenderedAnimated widget _)    = widget
renderedWidget (RenderedHandler widget _)     = widget
renderedWidget (RenderedLazy widget _ _)      = widget

-- | Update the widget stored in a RenderedNode to reflect an animation target.
-- The native node ID and children are preserved; only the bookkeeping fields
-- (widget, style) change so the next diff sees the post-animation state.
updateRenderedTarget :: Widget -> RenderedNode -> RenderedNode
updateRenderedTarget target (RenderedLeaf _ nodeId) =
  RenderedLeaf target nodeId
updateRenderedTarget target (RenderedContainer _ nodeId children) =
  RenderedContainer target nodeId children
updateRenderedTarget (Styled newStyle _) (RenderedStyled _ _ child) =
  RenderedStyled (Styled newStyle (renderedWidget child)) newStyle child
updateRenderedTarget target (RenderedStyled _ oldStyle child) =
  RenderedStyled target oldStyle child
updateRenderedTarget target (RenderedAnimated _ child) =
  RenderedAnimated target child
updateRenderedTarget target (RenderedHandler _ child) =
  RenderedHandler target child
updateRenderedTarget target (RenderedLazy _ nodeId rows) =
  RenderedLazy target nodeId rows

-- ---------------------------------------------------------------------------
-- Render state
-- ---------------------------------------------------------------------------

-- | Mutable state for the rendering engine.
-- Holds a reference to the shared 'ActionState' callback registry
-- and the previously rendered tree for incremental diffing.
data RenderState = RenderState
  { rsActionState    :: ActionState
    -- ^ Shared callback registry (never cleared during rendering).
  , rsRenderedTree   :: IORef (Maybe RenderedNode)
    -- ^ The previously rendered tree, or 'Nothing' for the first render.
  , rsAnimationState :: AnimationState
    -- ^ Mutable animation tween registry.
  }

-- | Create a fresh 'RenderState' wrapping the given 'ActionState'
-- and 'AnimationState'.
newRenderState :: ActionState -> AnimationState -> IO RenderState
newRenderState actionState animState = do
  renderedTree <- newIORef Nothing
  pure RenderState
    { rsActionState    = actionState
    , rsRenderedTree   = renderedTree
    , rsAnimationState = animState
    }

-- ---------------------------------------------------------------------------
-- Bridge helpers
-- ---------------------------------------------------------------------------

-- | Map an 'InputType' to the numeric code sent to the platform bridge.
inputTypeToInt :: InputType -> Int32
inputTypeToInt InputText      = 0
inputTypeToInt InputNumber    = 1
inputTypeToInt InputMultiline = 2
inputTypeToInt InputPassword  = 3

-- | Apply a 'FontConfig' to a rendered node if present.
applyFontConfig :: Int32 -> Maybe FontConfig -> IO ()
applyFontConfig nodeId (Just font) = do
  Bridge.setNumProp nodeId Bridge.PropFontSize (fontSize font)
  Bridge.setNumProp nodeId Bridge.PropFontStyle
    ((if fontWeight font == FontBold then 1 else 0) + (if fontFamily font == FontMonospace then 2 else 0)
       + (if fontSlant font == FontItalic then 4 else 0))
applyFontConfig _nodeId Nothing = pure ()

-- | Apply a text color to a rendered node if present (the per-config
-- color, see 'tcTextColor').
applyTextColor :: Int32 -> Maybe Color -> IO ()
applyTextColor nodeId (Just color) =
  Bridge.setStrProp nodeId Bridge.PropColor (colorToHex color)
applyTextColor _nodeId Nothing = pure ()

-- | Map a 'ScaleType' to the numeric code sent to the platform bridge.
scaleTypeToDouble :: ScaleType -> Double
scaleTypeToDouble ScaleFit  = 0
scaleTypeToDouble ScaleFill = 1
scaleTypeToDouble ScaleNone = 2

-- | A switch's state for the platform bridge.
checked :: SwitchConfig -> Double
checked config = if swOn config then 1 else 0

-- | Set a field on a node where it differs from the old widget's, or
-- where there is no old one, on a new node.
changed :: Eq a => Maybe c -> c -> (c -> a) -> (a -> IO ()) -> IO ()
changed old new field set = when ((field <$> old) /= Just (field new)) (set (field new))

-- | A text's fields on its node, all or those that changed from the old
-- one's (see 'changed').
setText :: Int32 -> Maybe TextConfig -> TextConfig -> IO ()
setText nodeId old new = do
  changed old new tcLabel (Bridge.setStrProp nodeId Bridge.PropText)
  changed old new tcFontConfig (applyFontConfig nodeId)
  changed old new tcTextColor (applyTextColor nodeId)

setButton :: Int32 -> Maybe ButtonConfig -> ButtonConfig -> IO ()
setButton nodeId old new = do
  changed old new bcLabel (Bridge.setStrProp nodeId Bridge.PropText)
  changed old new (actionId . bcAction) (Bridge.setHandler nodeId Bridge.EventClick)
  changed old new bcFontConfig (applyFontConfig nodeId)
  changed old new bcTextColor (applyTextColor nodeId)

setSwitch :: Int32 -> Maybe SwitchConfig -> SwitchConfig -> IO ()
setSwitch nodeId old new = do
  changed old new checked (Bridge.setNumProp nodeId Bridge.PropChecked)
  changed old new (actionId . swAction) (Bridge.setHandler nodeId Bridge.EventClick)

-- | A text input's fields: as 'setText', keeping the node and so the
-- cursor, focus and keyboard. It takes the focus only when it's new.
setTextInput :: Int32 -> Maybe TextInputConfig -> TextInputConfig -> IO ()
setTextInput nodeId old new = do
  changed old new tiValue (Bridge.setStrProp nodeId Bridge.PropText)
  changed old new tiHint (Bridge.setStrProp nodeId Bridge.PropHint)
  changed old new tiInputType (Bridge.setNumProp nodeId Bridge.PropInputType . Int32.toDouble . inputTypeToInt)
  changed old new (onChangeId . tiOnChange) (Bridge.setHandler nodeId Bridge.EventTextChange)
  changed old new tiFontConfig (applyFontConfig nodeId)
  changed old new tiTextColor (applyTextColor nodeId)
  when (isNothing old && tiAutoFocus new) $
    Bridge.setNumProp nodeId Bridge.PropAutoFocus 1

-- | Where a leaf's node can show another widget of its kind, setting what
-- changed.
inPlace :: Widget -> Widget -> Maybe (Int32 -> IO ())
inPlace (Text old) (Text new)           = Just (\nodeId -> setText nodeId (Just old) new)
inPlace (Button old) (Button new)       = Just (\nodeId -> setButton nodeId (Just old) new)
inPlace (Switch old) (Switch new)       = Just (\nodeId -> setSwitch nodeId (Just old) new)
inPlace (TextInput old) (TextInput new) = Just (\nodeId -> setTextInput nodeId (Just old) new)
inPlace _ _                             = Nothing

-- | The event a handler widget has its child's node fire, the handler, and
-- the child.
handlerOf :: Widget -> Maybe (Bridge.EventType, Int32, Widget)
handlerOf (Tappable action child)      = Just (Bridge.EventClick, actionId action, child)
handlerOf (LongPressable action child) = Just (Bridge.EventLongPress, actionId action, child)
handlerOf (Scrolled onScroll _ child)  = Just (Bridge.EventScrolled, onScrollId onScroll, child)
handlerOf _                            = Nothing

-- ---------------------------------------------------------------------------
-- Creating rendered nodes from scratch
-- ---------------------------------------------------------------------------

-- | Create a container native node, recursively rendering each child
-- and attaching it via the bridge.  Used by Column, Row, and Stack which
-- share identical child-processing logic.
createContainerNode :: AnimationState -> Widget -> Bridge.NodeType
                    -> [LayoutItem] -> IO RenderedNode
createContainerNode animState widget nodeType layoutItems = do
  nodeId <- Bridge.createNode nodeType
  keyedChildren <- mapM (\(index, layoutItem) -> do
    let keyVal = resolveKeyAtIndex index layoutItem
    childNode <- createRenderedNode animState (liWidget layoutItem)
    Bridge.addChild nodeId (renderedNodeId childNode)
    pure (keyVal, childNode)
    ) (zip [0..] layoutItems)
  pure (RenderedContainer widget nodeId keyedChildren)

-- | Create a native node from a 'Widget', returning a 'RenderedNode'
-- snapshot. Used for fresh creation (no old node to diff against).
createRenderedNode :: AnimationState -> Widget -> IO RenderedNode
createRenderedNode _animState widget@(Text config) =
  leaf widget Bridge.NodeText (\nodeId -> setText nodeId Nothing config)
createRenderedNode _animState widget@(Button config) =
  leaf widget Bridge.NodeButton (\nodeId -> setButton nodeId Nothing config)
createRenderedNode _animState widget@(Switch config) =
  leaf widget Bridge.NodeSwitch (\nodeId -> setSwitch nodeId Nothing config)
createRenderedNode _animState widget@(TextInput config) =
  leaf widget Bridge.NodeTextInput (\nodeId -> setTextInput nodeId Nothing config)
createRenderedNode animState widget@(Column settings) = do
  let nodeType = if lsScrollable settings
        then Bridge.NodeScrollView
        else Bridge.NodeColumn
  createContainerNode animState widget nodeType (lsWidgets settings)
createRenderedNode animState widget@(Row settings) = do
  let nodeType = if lsScrollable settings
        then Bridge.NodeHorizontalScrollView
        else Bridge.NodeRow
  createContainerNode animState widget nodeType (lsWidgets settings)
createRenderedNode animState widget@(Stack items) =
  createContainerNode animState widget Bridge.NodeStack items
createRenderedNode _animState widget@(LazyColumn items) = do
  nodeId <- Bridge.createNode Bridge.NodeLazyColumn
  rows <- LazyRows <$> newIORef (Seq.fromList items) <*> newIORef IntMap.empty
  setItemCount nodeId (length items)
  pure (RenderedLazy widget nodeId rows)
createRenderedNode _animState widget@(Image config) = do
  nodeId <- Bridge.createNode Bridge.NodeImage
  case icSource config of
    ImageResource (ResourceName name) -> Bridge.setStrProp nodeId Bridge.PropImageResource name
    ImageData bytes                   -> Bridge.setImageData nodeId bytes
    ImageFile path                    -> Bridge.setStrProp nodeId Bridge.PropImageFile (pack path)
    ImageStream key                   -> Bridge.setStrProp nodeId Bridge.PropImageStream key
  Bridge.setNumProp nodeId Bridge.PropScaleType (scaleTypeToDouble (icScaleType config))
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(WebView config) = do
  nodeId <- Bridge.createNode Bridge.NodeWebView
  Bridge.setStrProp nodeId Bridge.PropWebViewUrl (wvUrl config)
  mapM_ (Bridge.setHandler nodeId Bridge.EventClick . actionId) (wvOnPageLoad config)
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(MapView config) = do
  nodeId <- Bridge.createNode Bridge.NodeMapView
  Bridge.setNumProp nodeId Bridge.PropMapLat (mvLatitude config)
  Bridge.setNumProp nodeId Bridge.PropMapLon (mvLongitude config)
  Bridge.setNumProp nodeId Bridge.PropMapZoom (mvZoom config)
  Bridge.setNumProp nodeId Bridge.PropMapShowUserLoc
    (if mvShowUserLocation config then 1.0 else 0.0)
  mapM_ (Bridge.setHandler nodeId Bridge.EventTextChange . onChangeId) (mvOnRegionChange config)
  pure (RenderedLeaf widget nodeId)
createRenderedNode animState widget@(Styled style child) = do
  childNode <- createRenderedNode animState child
  applyStyle (renderedNodeId childNode) style
  pure (RenderedStyled widget style childNode)
createRenderedNode animState widget@(Tappable _ _) = createHandler animState widget
createRenderedNode animState widget@(Scrolled {}) = createHandler animState widget
createRenderedNode animState widget@(LongPressable _ _) = createHandler animState widget
createRenderedNode animState (Animated config child) = do
  let normalized = normalizeAnimated config child
  case normalized of
    -- normalizeAnimated distributed into a container — render the container directly
    -- (each child is now individually wrapped in Animated).
    Column _     -> createRenderedNode animState normalized
    Row _        -> createRenderedNode animState normalized
    Stack _      -> createRenderedNode animState normalized
    -- Everything else (Styled, leaves): wrap in RenderedAnimated for tween interpolation.
    -- Apply first keyframe's style, register tween if >1 keyframe.
    _            -> do
      let finalWidget = Animated config normalized
          sortedKeyframes = sortBy (comparing kfAt) (anKeyframes config)
      childNode <- createRenderedNode animState normalized
      -- Apply the first keyframe's style as the initial visual state
      mapM_ (applyStyle (renderedNodeId childNode) . kfStyle) (take 1 sortedKeyframes)
      tween animState (renderedNodeId childNode) (anDuration config) sortedKeyframes
      pure (RenderedAnimated finalWidget childNode)

-- | A leaf's new node, with its fields set.
leaf :: Widget -> Bridge.NodeType -> (Int32 -> IO ()) -> IO RenderedNode
leaf widget nodeType set = do
  nodeId <- Bridge.createNode nodeType
  set nodeId
  pure (RenderedLeaf widget nodeId)

-- | A handler widget's child, with the handler on its node.
createHandler :: AnimationState -> Widget -> IO RenderedNode
createHandler animState widget = case handlerOf widget of
  Just (event, handler, child) -> do
    childNode <- createRenderedNode animState child
    Bridge.setHandler (renderedNodeId childNode) event handler
    pure (RenderedHandler widget childNode)
  Nothing -> createRenderedNode animState widget

-- | Animate a node through keyframes, where there are two or more.
tween :: AnimationState -> Int32 -> NominalDiffTime -> [Keyframe] -> IO ()
tween animState nodeId duration keyframes =
  when (length keyframes >= 2) $ registerTween animState nodeId keyframes duration

-- ---------------------------------------------------------------------------
-- Destroying rendered subtrees
-- ---------------------------------------------------------------------------

-- | Recursively destroy all native nodes in a rendered subtree.
destroyRenderedSubtree :: RenderedNode -> IO ()
destroyRenderedSubtree (RenderedLeaf _ nodeId) =
  Bridge.destroyNode nodeId
destroyRenderedSubtree (RenderedContainer _ nodeId keyedChildren) = do
  mapM_ (destroyRenderedSubtree . snd) keyedChildren
  Bridge.destroyNode nodeId
destroyRenderedSubtree (RenderedHandler _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedStyled _ _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedAnimated _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedLazy _ nodeId rows) = do
  shown <- readIORef (lrRows rows)
  mapM_ (\(rowId, (_, item)) -> do
    destroyRenderedSubtree item
    mapM_ Bridge.destroyNode (Int.toInt32 rowId)
    ) (IntMap.toList shown)
  Bridge.destroyNode nodeId

-- ---------------------------------------------------------------------------
-- Incremental diff algorithm
-- ---------------------------------------------------------------------------

-- | Check whether two widgets use the same constructor (node type).
-- Does not compare contents — just the outermost constructor tag.
sameNodeType :: Widget -> Widget -> Bool
sameNodeType (Text _)        (Text _)        = True
sameNodeType (Button _)      (Button _)      = True
sameNodeType (TextInput _)   (TextInput _)   = True
sameNodeType (Switch _)      (Switch _)      = True
sameNodeType (Column a)      (Column b)      = lsScrollable a == lsScrollable b
sameNodeType (Row a)         (Row b)         = lsScrollable a == lsScrollable b
sameNodeType (Stack _)       (Stack _)       = True
sameNodeType (Image _)       (Image _)       = True
sameNodeType (WebView _)     (WebView _)     = True
sameNodeType (MapView _)     (MapView _)     = True
sameNodeType (Styled _ _)    (Styled _ _)    = True
sameNodeType (Tappable _ _)  (Tappable _ _)  = True
sameNodeType (LongPressable _ _) (LongPressable _ _) = True
sameNodeType (Scrolled _ _ _) (Scrolled _ _ _) = True
sameNodeType (Animated _ _)  (Animated _ _)  = True
sameNodeType (LazyColumn _)  (LazyColumn _)  = True
sameNodeType _               _               = False

-- | Whether a widget has no widgets in it.
isLeaf :: Widget -> Bool
isLeaf = \case
  Text _       -> True
  Button _     -> True
  TextInput _  -> True
  Switch _     -> True
  Image _      -> True
  WebView _    -> True
  MapView _    -> True
  Column _     -> False
  Row _        -> False
  Stack _      -> False
  LazyColumn _ -> False
  Styled _ _   -> False
  Tappable _ _ -> False
  Scrolled {}  -> False
  LongPressable _ _ -> False
  Animated _ _ -> False

-- | Diff the old rendered tree against a new 'Widget' and produce
-- an updated 'RenderedNode', emitting only the necessary bridge calls.
-- A node of the same kind is kept, with what's in it diffed and what
-- changed set; any other is destroyed, and the new one created.
diffRenderNode :: AnimationState -> Maybe RenderedNode -> Widget -> IO RenderedNode
-- No previous node: create from scratch.
diffRenderNode animState Nothing newWidget =
  createRenderedNode animState newWidget

-- An unchanged leaf: keep it as it is. Widgets with children aren't
-- compared whole: each node is then compared once, rather than again for
-- each node above it, and a 'LazyColumn''s items are made only for the
-- rows the platform shows.
diffRenderNode _animState (Just oldNode) newWidget
  | isLeaf newWidget && newWidget == renderedWidget oldNode =
    pure oldNode

-- Animated wrapping a container: normalize (distribute to children) and recurse.
diffRenderNode animState maybeOld (Animated config child@(Column _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
diffRenderNode animState maybeOld (Animated config child@(Row _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
diffRenderNode animState maybeOld (Animated config child@(Stack _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
-- Nested Animated: inner config wins.
diffRenderNode animState maybeOld (Animated _outerConfig child@(Animated _ _)) =
  diffRenderNode animState maybeOld child

-- Both are Animated (leaf): diff the child, possibly registering a tween.
diffRenderNode animState (Just (RenderedAnimated _ oldChildNode)) (Animated newConfig newChild) = do
  let oldChildWidget = renderedWidget oldChildNode
      sortedKeyframes = sortBy (comparing kfAt) (anKeyframes newConfig)
  if sameNodeType oldChildWidget newChild
    then do
      -- Same child node type: keep native node, register tween if properties differ
      when (oldChildWidget /= newChild) $
        tween animState (renderedNodeId oldChildNode) (anDuration newConfig) sortedKeyframes
      -- Update the RenderedAnimated to reflect the new target
      let updatedChildNode = updateRenderedTarget newChild oldChildNode
      pure (RenderedAnimated (Animated newConfig newChild) updatedChildNode)
    else do
      -- Different child type: can't animate, destroy+create
      destroyRenderedSubtree oldChildNode
      newChildNode <- createRenderedNode animState newChild
      pure (RenderedAnimated (Animated newConfig newChild) newChildNode)

-- Both are Styled: diff the child, setting the style again if it or the
-- child's node changed.
diffRenderNode animState (Just (RenderedStyled _ oldStyle oldChild)) (Styled newStyle newChild) = do
  diffedChild <- diffRenderNode animState (Just oldChild) newChild
  let nodeChanged = renderedNodeId diffedChild /= renderedNodeId oldChild
  when (newStyle /= oldStyle || nodeChanged) $ do
    unless nodeChanged $ clearStyle (renderedNodeId diffedChild) oldStyle newStyle
    applyStyle (renderedNodeId diffedChild) newStyle
  pure (RenderedStyled (Styled newStyle newChild) newStyle diffedChild)

-- Both are the same handler widget: diff the child, and point its node at
-- the new handler if that or the node changed. A 'Scrolled' also goes to
-- its end when its number changed.
diffRenderNode animState (Just (RenderedHandler oldWidget oldChild)) newWidget
  | Just (oldEvent, oldHandler, _) <- handlerOf oldWidget
  , Just (event, handler, newChild) <- handlerOf newWidget
  , event == oldEvent = do
      diffedChild <- diffRenderNode animState (Just oldChild) newChild
      let node = renderedNodeId diffedChild
      when (handler /= oldHandler || node /= renderedNodeId oldChild) $
        Bridge.setHandler node event handler
      case (oldWidget, newWidget) of
        (Scrolled _ oldJump _, Scrolled _ newJump _) | newJump /= oldJump ->
          Bridge.setNumProp node Bridge.PropScrollToEnd (fromIntegral newJump)
        _ -> pure ()
      pure (RenderedHandler newWidget diffedChild)

-- Same container type: keep the container, diff its children.
diffRenderNode animState (Just oldNode@(RenderedContainer _ containerNodeId oldKeyedChildren)) newWidget
  | sameNodeType (renderedWidget oldNode) newWidget =
    case newWidget of
      Column settings        -> diffContainer animState containerNodeId oldKeyedChildren (lsWidgets settings) newWidget
      Row settings           -> diffContainer animState containerNodeId oldKeyedChildren (lsWidgets settings) newWidget
      Stack newItems         -> diffContainer animState containerNodeId oldKeyedChildren newItems newWidget
      -- Non-container but same type at container level shouldn't happen,
      -- but fall through to destroy+create for safety.
      _ -> replaceNode animState oldNode newWidget

-- Both are LazyColumn: keep the list and its rows. With the same keys in
-- the same places, render the new items into the rows made so far; else
-- have the platform show the items again, which renders each row's new
-- item into it.
diffRenderNode animState (Just (RenderedLazy _ nodeId rows)) newWidget@(LazyColumn items) = do
  let new = Seq.fromList items
  old <- readIORef (lrItems rows)
  writeIORef (lrItems rows) new
  if keys old == keys new
    then readIORef (lrRows rows)
      >>= IntMap.traverseWithKey (\row (position, shown) -> case (Int.toInt32 row, Seq.lookup position new) of
            (Just rowId, Just item) -> (,) position <$> intoRow animState rowId (Just shown) (liWidget item)
            _                       -> pure (position, shown))
      >>= writeIORef (lrRows rows)
    else setItemCount nodeId (length items)
  pure (RenderedLazy newWidget nodeId rows)
  where keys = Seq.mapWithIndex resolveKeyAtIndex

-- Same kind of leaf: keep the node, setting only what changed. Making it
-- again would also take it out of its parent, and an EditText taken out
-- loses its focus and keyboard.
diffRenderNode _animState (Just (RenderedLeaf oldWidget nodeId)) newWidget
  | Just set <- inPlace oldWidget newWidget = do
      set nodeId
      pure (RenderedLeaf newWidget nodeId)

-- Different node types: destroy the old one and create the new one.
diffRenderNode animState (Just oldNode) newWidget =
  replaceNode animState oldNode newWidget

-- | Diff container children by key.  Matches new children against old
-- by resolved 'WidgetKey', so inserting a child at position 0 no longer
-- causes all subsequent children to mismatch.
--
-- Native children are removed and added only where the order changed:
-- the ones gone are removed, the ones that stay in front are left
-- alone, and those after them are added again in the new order.  A
-- child taken out of the view hierarchy loses its state, such as an
-- EditText's focus and IME connection, so appending or removing
-- children leaves the others attached.
diffContainer :: AnimationState -> Int32 -> [(Int, RenderedNode)] -> [LayoutItem]
              -> Widget -> IO RenderedNode
diffContainer animState containerNodeId oldKeyedChildren newLayoutItems newWidget = do
  -- Build IntMap from old children's stored keys (first occurrence wins on dup)
  let oldKeyMap = IntMap.fromList oldKeyedChildren
  -- Match new children against old by key (index-based for unkeyed items)
  (diffedKeyedChildren, usedKeySet) <- matchNewChildren animState oldKeyMap newLayoutItems
  let unusedOld = IntMap.elems (IntMap.withoutKeys oldKeyMap usedKeySet)
      unusedIds = map renderedNodeId unusedOld
      -- What stays attached, in its native order, once the unused are gone.
      keptIds = filter (`notElem` unusedIds) (map (renderedNodeId . snd) oldKeyedChildren)
      (detached, added) = reattachments keptIds (map (renderedNodeId . snd) diffedKeyedChildren)
  mapM_ (\oldChild -> do
    Bridge.removeChild containerNodeId (renderedNodeId oldChild)
    destroyRenderedSubtree oldChild
    ) unusedOld
  mapM_ (Bridge.removeChild containerNodeId) detached
  mapM_ (Bridge.addChild containerNodeId) added
  pure (RenderedContainer newWidget containerNodeId diffedKeyedChildren)

-- | Which of a container's native children to take out and which to add,
-- in order, to go from the attached ones to the new ones: all after the
-- ones both start with.
reattachments :: [Int32] -> [Int32] -> ([Int32], [Int32])
reattachments attached new = (drop inFront attached, drop inFront new)
  where
    inFront = length (takeWhile id (zipWith (==) attached new))

-- | Match new children against old children by resolved key.
-- Children without explicit keys use their list index as the key,
-- so they match by position.  Children with explicit keys match by key
-- regardless of position.
matchNewChildren :: AnimationState -> IntMap RenderedNode
                 -> [LayoutItem] -> IO ([(Int, RenderedNode)], IntSet)
matchNewChildren animState oldKeyMap newItems =
    go IntSet.empty (zip [0..] newItems)
  where
    go :: IntSet -> [(Int, LayoutItem)]
       -> IO ([(Int, RenderedNode)], IntSet)
    go usedKeys [] = pure ([], usedKeys)
    go usedKeys ((index, layoutItem) : rest) = do
      let keyVal = resolveKeyAtIndex index layoutItem
          newChild = liWidget layoutItem
          maybeOld = if IntSet.member keyVal usedKeys
                     then Nothing
                     else IntMap.lookup keyVal oldKeyMap
      diffedChild <- case maybeOld of
        Just oldChild ->
          if sameNodeType (renderedWidget oldChild) newChild
            then diffRenderNode animState (Just oldChild) newChild
            else do
              destroyRenderedSubtree oldChild
              createRenderedNode animState newChild
        Nothing ->
          createRenderedNode animState newChild
      let usedKeys' = case maybeOld of
            Just _  -> IntSet.insert keyVal usedKeys
            Nothing -> usedKeys
      (restNodes, finalUsed) <- go usedKeys' rest
      pure ((keyVal, diffedChild) : restNodes, finalUsed)

-- | Destroy an old node and create a fresh replacement.
replaceNode :: AnimationState -> RenderedNode -> Widget -> IO RenderedNode
replaceNode animState oldNode newWidget = do
  destroyRenderedSubtree oldNode
  createRenderedNode animState newWidget

-- | Render a 'LazyColumn''s item into one of its rows, as the platform
-- asks while it scrolls: into the row with the given node ID, or a new
-- one for 0.  Gives the row's node ID, or 0 if there is no such list or
-- item, as after the platform dropped the views.
bindLazyRow :: RenderState -> Int32 -> Int32 -> Int -> IO Int32
bindLazyRow rs listId rowId position = do
  tree <- readIORef (rsRenderedTree rs)
  case tree >>= findLazy listId of
    Nothing -> pure 0
    Just rows -> do
      items <- readIORef (lrItems rows)
      case Seq.lookup position items of
        Nothing -> pure 0
        Just item -> do
          row <- if rowId == 0 then Bridge.createNode Bridge.NodeColumn else pure rowId
          shown <- readIORef (lrRows rows)
          let old = snd <$> IntMap.lookup (Int32.toInt row) shown
          new <- intoRow (rsAnimationState rs) row old (liWidget item)
          writeIORef (lrRows rows) (IntMap.insert (Int32.toInt row) (position, new) shown)
          pure row

-- | Render a widget into a lazy list's row, over what it showed.
intoRow :: AnimationState -> Int32 -> Maybe RenderedNode -> Widget -> IO RenderedNode
intoRow animState row old widget = do
  new <- diffRenderNode animState old widget
  when (fmap renderedNodeId old /= Just (renderedNodeId new)) $
    Bridge.addChild row (renderedNodeId new)
  pure new

-- | The key of a 'LazyColumn''s item, for the platform to keep it on
-- screen when items before it change: its own, else its position.
lazyItemKey :: RenderState -> Int32 -> Int -> IO Int
lazyItemKey rs listId position = do
  tree <- readIORef (rsRenderedTree rs)
  items <- maybe (pure Seq.empty) (readIORef . lrItems) (tree >>= findLazy listId)
  pure (maybe position (resolveKeyAtIndex position) (Seq.lookup position items))

setItemCount :: Int32 -> Int -> IO ()
setItemCount nodeId count =
  mapM_ (Bridge.setNumProp nodeId Bridge.PropItemCount . Int32.toDouble) (Int.toInt32 count)

-- | The rows of the 'LazyColumn' with this node ID, outside any other
-- list's items.
findLazy :: Int32 -> RenderedNode -> Maybe LazyRows
findLazy listId = go
  where
    go (RenderedLazy _ nodeId rows)
      | nodeId == listId = Just rows
      | otherwise = Nothing
    go (RenderedLeaf _ _) = Nothing
    go (RenderedContainer _ _ children) = asum (map (go . snd) children)
    go (RenderedStyled _ _ child) = go child
    go (RenderedAnimated _ child) = go child
    go (RenderedHandler _ child) = go child

-- ---------------------------------------------------------------------------
-- Top-level render entry point
-- ---------------------------------------------------------------------------

-- | Forget the rendered tree and its tweens, after the platform dropped
-- their native views.  The next render creates them all again.
resetRender :: RenderState -> IO ()
resetRender rs = do
  writeIORef (rsRenderedTree rs) Nothing
  writeIORef (ansTweens (rsAnimationState rs)) IntMap.empty
  writeIORef (ansLoopActive (rsAnimationState rs)) False

-- | Incremental render: diffs the new widget tree against the previously
-- rendered tree and emits only the necessary bridge operations.
--
-- On the first call (no previous tree), performs a full creation.
-- On subsequent calls, reuses unchanged native nodes.
renderWidget :: RenderState -> Widget -> IO ()
renderWidget rs widget = do
  oldTree <- readIORef (rsRenderedTree rs)
  newTree <- diffRenderNode (rsAnimationState rs) oldTree widget
  -- Set root if this is the first render or the root node changed.
  case oldTree of
    Nothing -> Bridge.setRoot (renderedNodeId newTree)
    Just old
      | renderedNodeId old /= renderedNodeId newTree ->
          Bridge.setRoot (renderedNodeId newTree)
      | otherwise -> pure ()
  writeIORef (rsRenderedTree rs) (Just newTree)

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

-- | Dispatch a native click event to the registered Haskell callback.
-- Logs an error to stderr if the callbackId is not found.
dispatchEvent :: RenderState -> Int32 -> IO ()
dispatchEvent rs callbackId = do
  maybeAction <- lookupAction (rsActionState rs) callbackId
  case maybeAction of
    Just action -> action
    Nothing     -> hPutStrLn stderr $
      "dispatchEvent: unknown callback ID " ++ show callbackId

-- | Dispatch a native text-change event to the registered Haskell callback.
-- The caller ('Hatter.haskellOnUITextChange') triggers a re-render
-- after dispatch; the diff algorithm updates TextInput nodes in-place
-- so the native widget is preserved (no cursor reset or flicker).
-- Logs an error to stderr if the callbackId is not found.
dispatchTextEvent :: RenderState -> Int32 -> Text -> IO ()
dispatchTextEvent rs callbackId newText = do
  maybeAction <- lookupTextAction (rsActionState rs) callbackId
  case maybeAction of
    Just action -> action newText
    Nothing     -> hPutStrLn stderr $
      "dispatchTextEvent: unknown callback ID " ++ show callbackId

-- | Dispatch where a list is, by the platform's number for it.
dispatchScrollEvent :: RenderState -> Int32 -> Int -> IO ()
dispatchScrollEvent rs callbackId position = do
  maybeAction <- lookupScrollAction (rsActionState rs) callbackId
  case (maybeAction, [p | p <- [minBound .. maxBound], fromEnum p == position]) of
    (Just action, p : _) -> action p
    (Just _, [])         -> hPutStrLn stderr $
      "dispatchScrollEvent: unknown position " ++ show position
    (Nothing, _)         -> hPutStrLn stderr $
      "dispatchScrollEvent: unknown callback ID " ++ show callbackId
