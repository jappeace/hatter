{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | Lays out a widget tree in character cells, the way Android lays out its
-- views: columns and rows measure their children in turn, weights share
-- what is left, and stacks put their children over each other.
module Hatter.Terminal.Layout
  ( Scale (..)
  , defaultScale
  , Path
  , Rect (..)
  , inside
  , Scroll (..)
  , Inputs (..)
  , Look (..)
  , plain
  , Op (..)
  , Target (..)
  , Focusable (..)
  , Viewport (..)
  , Frame (..)
  , layout
  , textWidth
  , charWidth
  , breakLines
  , cursorAt
  ) where

import Data.List (mapAccumL)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Graphics.Text.Width (safeWcwidth)
import Hatter.Action (Action, OnChange, OnScroll)
import Hatter.Widget

-- | Density-independent pixels per character cell.
data Scale = Scale
  { scaleColumn :: Double
  , scaleRow    :: Double
  } deriving (Eq, Show)

-- | A phone's 360dp come out as 45 columns. A row takes three columns' dp,
-- more than it is tall, so screens made for phones aren't spread out.
defaultScale :: Scale
defaultScale = Scale 8 24

-- | Where a widget is in the tree: the positions, or keys, of the children
-- leading to it, innermost first.
type Path = [Int]

data Rect = Rect
  { rectX :: !Int
  , rectY :: !Int
  , rectW :: !Int
  , rectH :: !Int
  } deriving (Eq, Show)

inside :: Int -> Int -> Rect -> Bool
inside x y (Rect rx ry rw rh) = x >= rx && x < rx + rw && y >= ry && y < ry + rh

overlap :: Rect -> Rect -> Rect
overlap (Rect ax ay aw ah) (Rect bx by bw bh) =
  let x = max ax bx
      y = max ay by
  in Rect x y (max 0 (min (ax + aw) (bx + bw) - x)) (max 0 (min (ay + ah) (by + bh) - y))

within :: Rect -> Rect -> Bool
within (Rect ax ay aw ah) (Rect bx by bw bh) =
  ax >= bx && ay >= by && ax + aw <= bx + bw && ay + ah <= by + bh

isEmpty :: Rect -> Bool
isEmpty r = rectW r <= 0 || rectH r <= 0

-- | How far a scrolling column is scrolled. Columns keeping to their end
-- count from it, so what comes before doesn't move what shows.
data Scroll = FromStart !Int | FromEnd !Int
  deriving (Eq, Show)

-- | What the layout needs from the terminal besides the widgets.
data Inputs = Inputs
  { inScale  :: Scale
  , inWidth  :: Int
  , inHeight :: Int
  , inScroll :: Path -> Maybe Scroll
  , inFocus  :: Maybe Path
  , inCursor :: Int
    -- ^ Where the cursor is in the focused input.
  , inGlyph  :: ResourceName -> Maybe Text
    -- ^ What to show for an image resource, like an icon.
  }

data Look = Look
  { lookColor     :: Maybe Color
  , lookBold      :: Bool
  , lookDim       :: Bool
  , lookUnderline :: Bool
  , lookItalic    :: Bool
  } deriving (Eq, Show)

plain :: Look
plain = Look Nothing False False False False

-- | Drawing, in order, each cut to what can be seen.
data Op
  = Fill Rect Color
  | Write Int Int Text Look
    -- ^ One line of text at a column and row.
  | Picture Rect Rect ImageSource ScaleType (Double, Double)
    -- ^ Where the picture is, the part of it that can be seen, and how
    -- round its corners are in its own pixels, two to a cell's height.
  | Highlight Rect
  deriving (Eq, Show)

data Target
  = Tap (Maybe Action) (Maybe Action)
    -- ^ Tapping, holding.
  | Input OnChange TextInputConfig
  deriving (Eq, Show)

data Focusable = Focusable
  { focusPath     :: Path
  , focusVisible  :: Rect
    -- ^ The part that can be clicked.
  , focusTarget   :: Target
  , focusScroller :: Maybe (Path, Int, Int)
    -- ^ The innermost scrolling column it is in, and where it is in that
    -- column's content: the first row, and how many.
  } deriving (Eq, Show)

data Viewport = Viewport
  { viewPath     :: Path
  , viewRect     :: Rect
  , viewContent  :: Int
    -- ^ Rows of content.
  , viewOffset   :: Int
  , viewScrolled :: Maybe (OnScroll, Int)
  , viewKeep     :: Bool
    -- ^ Keeps to its end, as chats do.
  , viewItems    :: [Int]
    -- ^ Its items' keys.
  } deriving (Eq, Show)

data Frame = Frame
  { frameOps       :: [Op]
  , frameFocus     :: [Focusable]
    -- ^ In order, without those something else covers.
  , frameViewports :: [Viewport]
  , frameCursor    :: Maybe (Int, Int)
  } deriving (Eq, Show)

layout :: Inputs -> Widget -> Frame
layout inputs widget =
  let screen = Rect 0 0 (inWidth inputs) (inHeight inputs)
      box = lay inputs [] (Spec (Exactly (inWidth inputs)) (Exactly (inHeight inputs))) widget
      out = boxPaint box (Ctx screen Nothing) screen
  in Frame
    { frameOps = run (outOps out)
    , frameFocus = run (outFocus out)
    , frameViewports = run (outViews out)
    , frameCursor = outCursor out
    }

-- Measuring, like Android's measure specs.

data Size = Exactly !Int | AtMost !Int | Unbounded
  deriving (Eq, Show)

data Spec = Spec
  { specW :: Size
  , specH :: Size
  } deriving (Eq, Show)

resolve :: Size -> Int -> Int
resolve (Exactly s) _ = s
resolve (AtMost s) c  = min s c
resolve Unbounded c   = c

shrink :: Int -> Size -> Size
shrink n = \case
  Exactly s -> Exactly (max 0 (s - n))
  AtMost s  -> AtMost (max 0 (s - n))
  Unbounded -> Unbounded

bound :: Size -> Maybe Int
bound = \case
  Exactly s -> Just s
  AtMost s  -> Just s
  Unbounded -> Nothing

-- | How a child wants to be sized along one axis.
data Want = Match | Wrap | Fixed !Int
  deriving (Eq, Show)

childSize :: Size -> Int -> Want -> Size
childSize parent used = \case
  Fixed n -> Exactly n
  Match   -> shrink used parent
  Wrap    -> case shrink used parent of
    Exactly s -> AtMost s
    other     -> other

data Parent = InColumn | InRow | InStack
  deriving (Eq, Show)

data Params = Params
  { paramW       :: Want
  , paramH       :: Want
  , paramWeight  :: Maybe Double
  , paramGravity :: Maybe SelfAlignment
  , paramMarginX :: Int
  , paramMarginY :: Int
  }

-- | As Android's defaults for a child of each kind of parent.
params :: Scale -> Parent -> WidgetStyle -> Params
params scale parent style = Params
  { paramW = maybe width (Fixed . wide) (wsWidth style)
  , paramH = maybe height (Fixed . rows scale) (wsHeight style)
  , paramWeight = case parent of
      InStack -> Nothing
      _       -> wsWeight style
  , paramGravity = wsAlignSelf style
  , paramMarginX = maybe 0 (columns scale) (wsMargin style)
  , paramMarginY = maybe 0 (spacing scale) (wsMargin style)
  }
  where
    -- Small gaps still part what's beside them.
    wide dp = if dp > 0 then max 1 (columns scale dp) else 0
    aligned = wsAlignSelf style
    (width, height) = case (parent, aligned) of
      (InColumn, Just SelfStretch) -> (Match, Wrap)
      (InColumn, Just _)           -> (Wrap, Wrap)
      (InColumn, Nothing)          -> (Match, Wrap)
      (InRow, Just SelfStretch)    -> (Wrap, Match)
      (InRow, _)                   -> (Wrap, Wrap)
      (InStack, Just SelfStretch)  -> (Match, Match)
      (InStack, Just _)            -> (Wrap, Wrap)
      (InStack, Nothing)           -> (Match, Match)

columns :: Scale -> Double -> Int
columns scale dp = round (dp / scaleColumn scale)

rows :: Scale -> Double -> Int
rows scale dp = round (dp / scaleRow scale)

-- | Margins, and padding on a background, only take a row once they are as tall as one.
spacing :: Scale -> Double -> Int
spacing scale dp = floor (dp / scaleRow scale)

-- Drawing.

-- | Lists to append to cheaply.
newtype Bag a = Bag ([a] -> [a])

instance Semigroup (Bag a) where
  Bag a <> Bag b = Bag (a . b)

instance Monoid (Bag a) where
  mempty = Bag id

one :: a -> Bag a
one x = Bag (x :)

run :: Bag a -> [a]
run (Bag f) = f []

data Out = Out
  { outOps    :: Bag Op
  , outFocus  :: Bag Focusable
  , outViews  :: Bag Viewport
  , outCursor :: Maybe (Int, Int)
  , outCovers :: Bag Rect
    -- ^ What it hides of what's under it.
  }

instance Semigroup Out where
  Out a b c d e <> Out a' b' c' d' e' = Out (a <> a') (b <> b') (c <> c') (maybe d' Just d) (e <> e')

instance Monoid Out where
  mempty = Out mempty mempty mempty Nothing mempty

op :: Op -> Out
op o = mempty { outOps = one o }

data Ctx = Ctx
  { ctxClip     :: Rect
  , ctxScroller :: Maybe (Path, Int)
    -- ^ The innermost scrolling column, and the row its content starts at.
  }

-- | A widget measured: its size, and how to draw it in a place of that size.
data Box = Box
  { boxW     :: !Int
  , boxH     :: !Int
  , boxPaint :: Ctx -> Rect -> Out
  }

-- | A widget without the wrappers that only style it or listen to it.
data Node = Node
  { nodeStyle    :: WidgetStyle
  , nodeTap      :: Maybe Action
  , nodeHold     :: Maybe Action
  , nodeScrolled :: Maybe (OnScroll, Int)
  , nodeWidget   :: Widget
  }

-- | Those wrapping others win, as Hatter applies them last.
unwrap :: Widget -> Node
unwrap = \case
  Styled style w      -> let n = unwrap w in n { nodeStyle = over style (nodeStyle n) }
  Tappable a w        -> (unwrap w) { nodeTap = Just a }
  LongPressable a w   -> (unwrap w) { nodeHold = Just a }
  Scrolled change n w -> (unwrap w) { nodeScrolled = Just (change, n) }
  Animated _ w        -> unwrap w
  w                   -> Node defaultStyle Nothing Nothing Nothing w

over :: WidgetStyle -> WidgetStyle -> WidgetStyle
over outer inner = defaultStyle
  { wsPadding = pick wsPadding
  , wsPaddingY = pick wsPaddingY
  , wsTextAlign = pick wsTextAlign
  , wsBackgroundColor = pick wsBackgroundColor
  , wsTranslateX = pick wsTranslateX
  , wsTranslateY = pick wsTranslateY
  , wsWidth = pick wsWidth
  , wsTouchPassthrough = pick wsTouchPassthrough
  , wsHeight = pick wsHeight
  , wsWeight = pick wsWeight
  , wsAlignSelf = pick wsAlignSelf
  , wsMargin = pick wsMargin
  , wsMaxWidth = pick wsMaxWidth
  , wsMaxLines = pick wsMaxLines
  , wsCorners = pick wsCorners
  , wsKeepAtEnd = pick wsKeepAtEnd
  }
  where
    pick :: (WidgetStyle -> Maybe a) -> Maybe a
    pick field = maybe (field inner) Just (field outer)

-- | Measures a widget in its own place, with its padding, background and
-- taps. The parent sees to its margins.
lay :: Inputs -> Path -> Spec -> Widget -> Box
lay inputs path spec widget =
  Box width height paint
  where
    node = unwrap widget
    style = nodeStyle node
    scale = inScale inputs
    padX = maybe 0 (columns scale) (wsPadding style)
    -- A background shows where a box ends, so it needs less padding.
    padY = case wsBackgroundColor style of
      Just _  -> maybe 0 (spacing scale) vertical
      Nothing -> maybe 0 (rows scale) vertical
    vertical = maybe (wsPadding style) Just (wsPaddingY style)
    capped = case (wsMaxWidth style, specW spec) of
      (Just most, Exactly s) -> Exactly (min s (columns scale most))
      (Just most, AtMost s)  -> AtMost (min s (columns scale most))
      (Just most, Unbounded) -> AtMost (columns scale most)
      (Nothing, s)           -> s
    content = core inputs path node (Spec (shrink (2 * padX) capped) (shrink (2 * padY) (specH spec)))
    width = resolve capped (boxW content + 2 * padX)
    height = resolve (specH spec) (boxH content + 2 * padY)
    focused = inFocus inputs == Just path
    tap' = case (nodeTap node, nodeWidget node) of
      (Just a, _)         -> Just a
      (Nothing, Button c) -> Just (bcAction c)
      (Nothing, Switch c) -> Just (swAction c)
      _                   -> Nothing
    tappable = isJust tap' || isJust (nodeHold node)
    paint ctx rect =
      let clip = overlap (ctxClip ctx) rect
          background = case wsBackgroundColor style of
            Just colour | colorAlpha colour > 0 ->
              op (Fill clip colour) <> mempty { outCovers = one clip }
            _ -> mempty
          inner = Rect (rectX rect + padX) (rectY rect + padY)
            (max 0 (rectW rect - 2 * padX)) (max 0 (rectH rect - 2 * padY))
          tap
            | tappable = mempty
                { outFocus = one (focusable ctx rect clip (Tap tap' (nodeHold node)))
                , outCovers = one clip }
            | otherwise = mempty
          highlight
            | focused && tappable && not (isEmpty clip) = op (Highlight clip)
            | otherwise = mempty
      in background <> tap <> boxPaint content ctx { ctxClip = clip } inner <> highlight
    focusable ctx rect clip target = Focusable
      { focusPath = path
      , focusVisible = clip
      , focusTarget = target
      , focusScroller = fmap (\(p, top) -> (p, rectY rect - top, rectH rect)) (ctxScroller ctx)
      }

-- | Measures what a node is, inside its padding.
core :: Inputs -> Path -> Node -> Spec -> Box
core inputs path node spec = case nodeWidget node of
  Text config ->
    let look = (fontLook (tcFontConfig config)) { lookColor = tcTextColor config }
    in label (tcLabel config) look
  Button config ->
    let look = (fontLook (bcFontConfig config)) { lookColor = bcTextColor config }
        caption = case wsBackgroundColor style of
          Just _  -> " " <> bcLabel config <> " "
          Nothing -> "[ " <> bcLabel config <> " ]"
    in label caption look
  TextInput config -> input inputs path style spec config
  Switch config -> label (if swOn config then "[\x25cf ]" else "[ \x25cb]") plain
  Image config -> case icSource config of
    ImageResource name ->
      centred (fromMaybe "\x25aa" (inGlyph inputs name)) plain
    ImageStream _ -> centred "\x25b6" plain
    source -> picture source (icScaleType config)
  WebView config -> label ("[" <> wvUrl config <> "]") plain
  MapView config ->
    label ("[map " <> Text.pack (show (mvLatitude config)) <> ", " <> Text.pack (show (mvLongitude config)) <> "]") plain
  Column settings
    | lsScrollable settings -> scroller inputs path Vertical style (nodeScrolled node) spec (lsWidgets settings)
    | otherwise -> linear inputs path Vertical spec (lsWidgets settings)
  Row settings
    | lsScrollable settings -> scroller inputs path Horizontal style (nodeScrolled node) spec (lsWidgets settings)
    | otherwise -> linear inputs path Horizontal spec (lsWidgets settings)
  LazyColumn items -> scroller inputs path Vertical style (nodeScrolled node) spec items
  Stack items -> stacked inputs path spec items
  -- The wrappers are gone already.
  _ -> Box 0 0 (\_ _ -> mempty)
  where
    style = nodeStyle node
    label caption look = textBox spec style caption look
    centred glyph look =
      let w = max 1 (textWidth glyph)
      in Box (resolve (specW spec) w) (resolve (specH spec) 1) $ \ctx rect ->
        let x = rectX rect + (rectW rect - w) `div` 2
            y = rectY rect + (rectH rect - 1) `div` 2
        in write (ctxClip ctx) x y glyph look
    picture source scaleType =
      Box (resolve (specW spec) 2) (resolve (specH spec) 1) $ \ctx rect ->
        let clip = overlap (ctxClip ctx) rect
            Scale perColumn perRow = inScale inputs
            radius = fromMaybe 0 (sameRadius =<< wsCorners style)
        in if isEmpty clip then mempty else op (Picture rect clip source scaleType (radius / perColumn, radius * 2 / perRow))

-- | Big text has no other way to stand out.
fontLook :: Maybe FontConfig -> Look
fontLook = \case
  Just font -> plain { lookBold = fontWeight font == FontBold || fontSize font >= 20
                     , lookItalic = fontSlant font == FontItalic }
  Nothing   -> plain

-- | Text wrapped to the width it has.
textBox :: Spec -> WidgetStyle -> Text -> Look -> Box
textBox spec style caption look =
  Box width (resolve (specH spec) (length shown)) $ \ctx rect ->
    mconcat
      [ write (ctxClip ctx) (rectX rect + indent (rectW rect) line) y line look
      | (y, line) <- zip [rectY rect ..] (take (rectH rect) (wrapped (rectW rect)))
      ]
  where
    most = fromMaybe maxBound (bound (specW spec))
    shown = wrapped most
    width = resolve (specW spec) (maximum (0 : map textWidth shown))
    -- The last line shown runs on into what's cut.
    wrapped w = case (wsMaxLines style, breakLines w caption) of
      (Just n, lines') | length lines' > n, n > 0 ->
        let kept = take n lines'
            rest = Text.replace "\n" " " (Text.drop (fst (last kept)) caption)
        in map snd (init kept) ++ [fitWidth (w - 1) rest <> "\x2026"]
      (_, lines') -> map snd lines'
    indent w line = case wsTextAlign style of
      Just AlignCenter -> (w - textWidth line) `div` 2
      Just AlignEnd    -> w - textWidth line
      _                -> 0

input :: Inputs -> Path -> WidgetStyle -> Spec -> TextInputConfig -> Box
input inputs path style spec config =
  Box width height $ \ctx rect ->
    let clip = ctxClip ctx
        lines' = breakLines (rectW rect) shown
        (cline, ccol) = cursorAt lines' cursor
        -- A single line follows the cursor once it's too long.
        skip = if multiline then 0 else max 0 (ccol - rectW rect + 1)
        start = if multiline then max 0 (cline - rectH rect + 1) else 0
        visible = take (rectH rect) (drop start lines')
        here = mempty
          { outFocus = one Focusable
              { focusPath = path
              , focusVisible = overlap clip rect
              , focusTarget = Input (tiOnChange config) config
              , focusScroller = fmap (\(p, top) -> (p, rectY rect - top, rectH rect)) (ctxScroller ctx)
              }
          , outCovers = one (overlap clip rect) }
        cursorOut
          | focused, inside x y clip = mempty { outCursor = Just (x, y) }
          | otherwise = mempty
          where
            x = rectX rect + ccol - skip
            y = rectY rect + cline - start
        -- Without a background, an underline the whole width shows where it is.
        underlined = isNothing (wsBackgroundColor style)
        padded t
          | underlined = t <> Text.replicate (rectW rect - textWidth t) " "
          | otherwise = t
    in here
      <> mconcat
        [ write clip (rectX rect) y (padded (if empty then text' else dropWidth skip text')) look { lookUnderline = underlined }
        | (y, (_, text')) <- zip [rectY rect ..] visible ]
      <> cursorOut
  where
    focused = inFocus inputs == Just path
    multiline = tiInputType config == InputMultiline
    value = tiValue config
    empty = Text.null value
    shown
      | empty = tiHint config
      | tiInputType config == InputPassword = Text.replicate (Text.length value) "\x2022"
      | otherwise = value
    cursor = if empty || not focused then 0 else min (Text.length value) (inCursor inputs)
    look = (fontLook (tiFontConfig config)) { lookColor = tiTextColor config, lookDim = empty }
    most = fromMaybe maxBound (bound (specW spec))
    natural = maximum (1 : map (textWidth . snd) (breakLines most shown)) + 1
    width = resolve (specW spec) natural
    count
      | multiline = length (breakLines width shown)
      | otherwise = 1
    height = resolve (specH spec) (maybe count (min count) (wsMaxLines style))

data Axis = Vertical | Horizontal
  deriving (Eq, Show)

-- | Sizes as (along, across) the axis, and back.
mainOf, crossOf :: Axis -> Spec -> Size
mainOf Vertical = specH
mainOf Horizontal = specW
crossOf Vertical = specW
crossOf Horizontal = specH

specOf :: Axis -> Size -> Size -> Spec
specOf Vertical along across = Spec across along
specOf Horizontal along across = Spec along across

alongBox, acrossBox :: Axis -> Box -> Int
alongBox Vertical = boxH
alongBox Horizontal = boxW
acrossBox Vertical = boxW
acrossBox Horizontal = boxH

rectOf :: Axis -> Int -> Int -> Int -> Int -> Rect
rectOf Vertical along across alongSize acrossSize = Rect across along acrossSize alongSize
rectOf Horizontal along across alongSize acrossSize = Rect along across alongSize acrossSize

data Child = Child
  { childPath   :: Path
  , childWidget :: Widget
  , childParams :: Params
  }

children :: Inputs -> Path -> Parent -> [LayoutItem] -> [Child]
children inputs path parent items =
  [ Child (resolveKeyAtIndex i li : path) (liWidget li)
      (params (inScale inputs) parent (nodeStyle (unwrap (liWidget li))))
  | (i, li) <- zip [0 ..] items ]

wantAlong, wantAcross :: Axis -> Params -> Want
wantAlong Vertical = paramH
wantAlong Horizontal = paramW
wantAcross Vertical = paramW
wantAcross Horizontal = paramH

marginAlong, marginAcross :: Axis -> Params -> Int
marginAlong Vertical = paramMarginY
marginAlong Horizontal = paramMarginX
marginAcross Vertical = paramMarginX
marginAcross Horizontal = paramMarginY

-- | A column or row, like Android's LinearLayout.
linear :: Inputs -> Path -> Axis -> Spec -> [LayoutItem] -> Box
linear inputs path axis spec items =
  Box (if axis == Vertical then across else along) (if axis == Vertical then along else across) paint
  where
    kids = children inputs path (if axis == Vertical then InColumn else InRow) items
    alongSpec = mainOf axis spec
    acrossSpec = crossOf axis spec
    weighted c = isJust (paramWeight (childParams c)) && isJust (bound alongSpec)
    measure c alongSize =
      let p = childParams c
          acrossSize = childSize acrossSpec (2 * marginAcross axis p) (wantAcross axis p)
      in lay inputs (childPath c) (specOf axis alongSize acrossSize) (childWidget c)
    -- First those without a weight, each with what the others left.
    (used, firsts) = mapAccumL first 0 kids
    first total c
      | weighted c = (total, Nothing)
      | otherwise =
          let p = childParams c
              m = 2 * marginAlong axis p
              box = measure c (childSize alongSpec (total + m) (wantAlong axis p))
          in (total + alongBox axis box + m, Just box)
    -- Then those with one share what is left.
    spare = maybe 0 (\b -> max 0 (b - used)) (bound alongSpec)
    weights = sum [ w | c <- kids, weighted c, Just w <- [paramWeight (childParams c)] ]
    shares = snd (mapAccumL share (0, 0) kids)
    share (sofar, given) c = case paramWeight (childParams c) of
      Just w | weighted c, weights > 0 ->
        let upto = sofar + w
            next = floor (fromIntegral spare * upto / weights)
        in ((upto, next), Just (next - given))
      _ -> ((sofar, given), Nothing)
    measured =
      [ fromMaybe (measure c (Exactly (maybe 0 (\s -> max 0 (s - 2 * marginAlong axis (childParams c))) slot))) box
      | (c, box, slot) <- zip3 kids firsts shares ]
    along = resolve alongSpec (sum [ alongBox axis b + 2 * marginAlong axis (childParams c) | (c, b) <- zip kids measured ])
    across = resolve acrossSpec (maximum (0 : [ acrossBox axis b + 2 * marginAcross axis (childParams c) | (c, b) <- zip kids measured ]))
    -- Those matching across get all of it, now that it is known.
    final =
      [ if wantAcross axis (childParams c) == Match && acrossBox axis b /= inner
          then lay inputs (childPath c) (specOf axis (Exactly (alongBox axis b)) (Exactly inner)) (childWidget c)
          else b
      | (c, b) <- zip kids measured
      , let inner = max 0 (across - 2 * marginAcross axis (childParams c)) ]
    paint ctx rect =
      let start = if axis == Vertical then rectY rect else rectX rect
          side = if axis == Vertical then rectX rect else rectY rect
          room = if axis == Vertical then rectW rect else rectH rect
          place pos (c, b) =
            let p = childParams c
                ma = marginAlong axis p
                mc = marginAcross axis p
                size = acrossBox axis b
                offset = case paramGravity p of
                  Just SelfCenter -> (room - size) `div` 2
                  Just SelfEnd    -> room - size - mc
                  _               -> mc
                r = rectOf axis (pos + ma) (side + offset) (alongBox axis b) size
            in (pos + alongBox axis b + 2 * ma, boxPaint b ctx r)
      in mconcat (snd (mapAccumL place start (zip kids final)))

-- | A scrolling column or row, scrolled as the terminal says. Only columns
-- keep at their end.
scroller :: Inputs -> Path -> Axis -> WidgetStyle -> Maybe (OnScroll, Int) -> Spec -> [LayoutItem] -> Box
scroller inputs path axis style scrolled spec items =
  Box (if axis == Vertical then across else along) (if axis == Vertical then along else across) paint
  where
    content = linear inputs path axis (specOf axis Unbounded (crossOf axis spec)) items
    full = alongBox axis content
    along = resolve (mainOf axis spec) full
    across = resolve (crossOf axis spec) (acrossBox axis content)
    keep = axis == Vertical && wsKeepAtEnd style == Just True
    most = max 0 (full - along)
    offset = case fromMaybe (if keep then FromEnd 0 else FromStart 0) (inScroll inputs path) of
      FromEnd n   -> max 0 (most - n)
      FromStart n -> max 0 (min most n)
    -- Short content sits at the end of a column keeping to it.
    pushed = if keep then max 0 (along - full) else 0
    paint ctx rect =
      let clip = overlap (ctxClip ctx) rect
          start = (if axis == Vertical then rectY rect else rectX rect) - offset + pushed
          inner = if axis == Vertical
            then Rect (rectX rect) start (rectW rect) full
            else Rect start (rectY rect) full (rectH rect)
          ctx' = ctx { ctxClip = clip
                     , ctxScroller = if axis == Vertical then Just (path, start) else ctxScroller ctx }
          view' = Viewport path rect full offset scrolled keep (zipWith resolveKeyAtIndex [0 ..] items)
      in mempty { outViews = one view' } <> boxPaint content ctx' inner

-- | Children over each other, like Android's FrameLayout. Those covered by
-- a later one can't be reached.
stacked :: Inputs -> Path -> Spec -> [LayoutItem] -> Box
stacked inputs path spec items = Box width height paint
  where
    kids = children inputs path InStack items
    measure c w h = lay inputs (childPath c) (Spec w h) (childWidget c)
    first = [ measure c (childSize (specW spec) (2 * paramMarginX p) (paramW p))
                        (childSize (specH spec) (2 * paramMarginY p) (paramH p))
            | c <- kids, let p = childParams c ]
    width = resolve (specW spec) (maximum (0 : [ boxW b + 2 * paramMarginX (childParams c) | (c, b) <- zip kids first ]))
    height = resolve (specH spec) (maximum (0 : [ boxH b + 2 * paramMarginY (childParams c) | (c, b) <- zip kids first ]))
    final =
      [ if (paramW p == Match && boxW b /= w) || (paramH p == Match && boxH b /= h)
          then measure c (if paramW p == Match then Exactly w else Exactly (boxW b))
                         (if paramH p == Match then Exactly h else Exactly (boxH b))
          else b
      | (c, b) <- zip kids first
      , let p = childParams c
            w = max 0 (width - 2 * paramMarginX p)
            h = max 0 (height - 2 * paramMarginY p) ]
    paint ctx rect = foldl' (layer ctx rect) mempty (zip kids final)
    layer ctx rect below (c, b) =
      let p = childParams c
          mx = paramMarginX p
          my = paramMarginY p
          (x, y) = case paramGravity p of
            Just SelfCenter -> ((rectW rect - boxW b) `div` 2, (rectH rect - boxH b) `div` 2)
            Just SelfEnd    -> (rectW rect - boxW b - mx, rectH rect - boxH b - my)
            _               -> (mx, my)
          above = boxPaint b ctx (Rect (rectX rect + x) (rectY rect + y) (boxW b) (boxH b))
          covers = run (outCovers above)
          seen f = not (any (within (focusVisible f)) covers) || isEmpty (focusVisible f)
      in below { outFocus = Bag (filter seen (run (outFocus below)) ++) } <> above

-- Text.

textWidth :: Text -> Int
textWidth = Text.foldl' (\n c -> n + charWidth c) 0

charWidth :: Char -> Int
charWidth c = max 0 (safeWcwidth c)

-- | The longest start of a text that fits a width.
fitWidth :: Int -> Text -> Text
fitWidth most t = Text.take (go 0 0 (Text.unpack t)) t
  where
    go n _ [] = n
    go n w (c : cs)
      | w + charWidth c > most = n
      | otherwise = go (n + 1) (w + charWidth c) cs

dropWidth :: Int -> Text -> Text
dropWidth n t = Text.drop (Text.length (fitWidth n t)) t

-- | Lines of a text wrapped at spaces to a width, each with where it
-- starts in the text.
breakLines :: Int -> Text -> [(Int, Text)]
breakLines most whole = concat (snd (mapAccumL paragraph 0 (Text.splitOn "\n" whole)))
  where
    width = max 1 most
    paragraph at para = (at + Text.length para + 1, wrap at para)
    wrap at t
      | textWidth t <= width = [(at, t)]
      | otherwise =
          let fits = fitWidth width t
              -- One more, to see if a space comes right after a word that fits.
              cut = case Text.breakOnEnd " " (fitWidth (width + 1) t) of
                (before, _) | not (Text.null before), Text.length before > 1 -> Text.length before
                _ -> max 1 (Text.length fits)
              (line, rest) = Text.splitAt cut t
          in (at, Text.stripEnd line) : wrap (at + cut) rest

-- | The line and column of a position in a text broken into lines.
cursorAt :: [(Int, Text)] -> Int -> (Int, Int)
cursorAt lines' pos = case reverse (zip [0 ..] (takeWhile ((<= pos) . fst) lines')) of
  (n, (start, line)) : _ -> (n, textWidth (Text.take (pos - start) line) + if pos - start > Text.length line then 1 else 0)
  [] -> (0, 0)

-- | One line, cut to what the clip shows.
write :: Rect -> Int -> Int -> Text -> Look -> Out
write clip x y t look
  | y < rectY clip || y >= rectY clip + rectH clip || Text.null t = mempty
  | otherwise =
      let skip = max 0 (rectX clip - x)
          shown = dropWidth skip t
          -- A wide character cut in half at the start leaves a gap.
          x' = x + textWidth (Text.take (Text.length t - Text.length shown) t)
          room = rectX clip + rectW clip - x'
          kept = fitWidth room shown
      in if room <= 0 || Text.null kept then mempty else op (Write x' y kept look)
