-- | A 'WidgetStyle' on a native node, for rendering and for animation
-- frames.
module Hatter.Style
  ( applyStyle
  , clearStyle
  , setCorners
  , textAlignToDouble
  )
where

import Control.Monad (when)
import Data.Int (Int32)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Hatter.UIBridge qualified as Bridge
import Hatter.Widget
  ( Color(..)
  , Corners(..)
  , SelfAlignment(..)
  , TextAlignment(..)
  , WidgetStyle(..)
  , colorToHex
  , sameRadius
  )

-- | Map a 'TextAlignment' to the numeric code sent to the platform bridge.
textAlignToDouble :: TextAlignment -> Double
textAlignToDouble AlignStart  = 0
textAlignToDouble AlignCenter = 1
textAlignToDouble AlignEnd    = 2

-- | Map a 'SelfAlignment' to the numeric code sent to the platform bridge.
selfAlignToDouble :: SelfAlignment -> Double
selfAlignToDouble SelfStart   = 0
selfAlignToDouble SelfCenter  = 1
selfAlignToDouble SelfEnd     = 2
selfAlignToDouble SelfStretch = 3

boolToDouble :: Bool -> Double
boolToDouble enabled = if enabled then 1 else 0

-- | Set what the style sets on a node, leaving the rest as it is.
applyStyle :: Int32 -> WidgetStyle -> IO ()
applyStyle nodeId style = do
  number Bridge.PropPadding wsPadding id
  -- After the padding, which sets all four sides.
  number Bridge.PropPaddingY wsPaddingY id
  number Bridge.PropGravity wsTextAlign textAlignToDouble
  mapM_ (Bridge.setStrProp nodeId Bridge.PropBgColor . colorToHex) (wsBackgroundColor style)
  number Bridge.PropTranslateX wsTranslateX id
  number Bridge.PropTranslateY wsTranslateY id
  number Bridge.PropWidth wsWidth id
  number Bridge.PropTouchPassthrough wsTouchPassthrough boolToDouble
  number Bridge.PropHeight wsHeight id
  number Bridge.PropWeight wsWeight id
  number Bridge.PropAlignSelf wsAlignSelf selfAlignToDouble
  number Bridge.PropMargin wsMargin id
  number Bridge.PropMaxWidth wsMaxWidth id
  number Bridge.PropMaxLines wsMaxLines fromIntegral
  mapM_ (setCorners nodeId . Just) (wsCorners style)
  number Bridge.PropKeepAtEnd wsKeepAtEnd boolToDouble
  where
    number :: Bridge.NumProp -> (WidgetStyle -> Maybe a) -> (a -> Double) -> IO ()
    number prop field toDouble = mapM_ (Bridge.setNumProp nodeId prop . toDouble) (field style)

-- | Put back what the old style set and the new one leaves alone, as a
-- node may be reused for another widget, like a lazy list's rows. Keeping
-- at the end and passing touches through stay as they are.
clearStyle :: Int32 -> WidgetStyle -> WidgetStyle -> IO ()
clearStyle nodeId old new = do
  cleared wsPadding $ Bridge.setNumProp nodeId Bridge.PropPadding 0
  cleared wsTextAlign $ Bridge.setNumProp nodeId Bridge.PropGravity (textAlignToDouble AlignStart)
  cleared wsBackgroundColor $ Bridge.setStrProp nodeId Bridge.PropBgColor (colorToHex transparent)
  cleared wsTranslateX $ Bridge.setNumProp nodeId Bridge.PropTranslateX 0
  cleared wsTranslateY $ Bridge.setNumProp nodeId Bridge.PropTranslateY 0
  -- Layout parameters the parent gives a child are kept where one is NaN.
  cleared wsWidth $ Bridge.setNumProp nodeId Bridge.PropWidth unset
  cleared wsHeight $ Bridge.setNumProp nodeId Bridge.PropHeight unset
  cleared wsWeight $ Bridge.setNumProp nodeId Bridge.PropWeight unset
  cleared wsAlignSelf $ Bridge.setNumProp nodeId Bridge.PropAlignSelf unset
  cleared wsMargin $ Bridge.setNumProp nodeId Bridge.PropMargin unset
  cleared wsMaxWidth $ Bridge.setNumProp nodeId Bridge.PropMaxWidth unlimited
  cleared wsMaxLines $ Bridge.setNumProp nodeId Bridge.PropMaxLines unlimited
  -- Any padding of the new style is set again after this.
  cleared wsPaddingY $ Bridge.setNumProp nodeId Bridge.PropPaddingY 0
  cleared wsCorners $ setCorners nodeId Nothing
  where
    cleared :: (WidgetStyle -> Maybe a) -> IO () -> IO ()
    cleared field = when (isJust (field old) && isNothing (field new))
    unlimited = fromIntegral (maxBound :: Int32)
    transparent = Color 0 0 0 0

-- | A node's corners: with the same radius all round, its background and
-- what's on it, else each corner of its background; square without.
setCorners :: Int32 -> Maybe Corners -> IO ()
setCorners nodeId corners = do
  Bridge.setNumProp nodeId Bridge.PropCornerRadius (fromMaybe 0 uniform)
  -- NaN gives the background back to the radius.
  Bridge.setNumProp nodeId Bridge.PropCornerTopLeft (maybe unset cornerTopLeft each)
  Bridge.setNumProp nodeId Bridge.PropCornerTopRight (maybe unset cornerTopRight each)
  Bridge.setNumProp nodeId Bridge.PropCornerBottomRight (maybe unset cornerBottomRight each)
  Bridge.setNumProp nodeId Bridge.PropCornerBottomLeft (maybe unset cornerBottomLeft each)
  where
    uniform = sameRadius =<< corners
    each = if isNothing uniform then corners else Nothing

-- | NaN, which tells a platform to go back to what it had without a value.
unset :: Double
unset = 0 / 0
