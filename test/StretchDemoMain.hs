{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the stretch-demo test app.
--
-- Used by the emulator integration tests. A column and a row that wrap
-- their content each hold a large text stretched across them beside a
-- small one that isn't. The large text shown on its own first gives its
-- natural size, which the stretched ones must keep.
module Main where

import Data.Text (Text)
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState)
import Hatter.AppContext (AppContext)
import Hatter.Widget (SelfAlignment(..), TextConfig(..), Widget(..), WidgetStyle(..), column, defaultStyle, fontOfSize, row)

main :: IO (Ptr AppContext)
main = do
  platformLog "Stretch demo app registered"
  actionState <- newActionState
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> pure stretchView
    , maActionState = actionState
    }

stretchView :: Widget
stretchView = column
  [ aligned SelfStart (text 48 "Wide")
  , aligned SelfStart $ column [text 48 "Wide", aligned SelfEnd (text 12 "column")]
  , aligned SelfStart $ row [aligned SelfStretch (text 48 "Wide"), aligned SelfStart (text 12 "row")]
  ]

aligned :: SelfAlignment -> Widget -> Widget
aligned a = Styled defaultStyle { wsAlignSelf = Just a }

text :: Double -> Text -> Widget
text size label = Text TextConfig
  { tcLabel      = label
  , tcFontConfig = Just (fontOfSize size)
  , tcTextColor  = Nothing
  }
