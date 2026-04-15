{-# LANGUAGE OverloadedStrings #-}
-- | Reproducer: Stack (FrameLayout) z-order after child mutations.
--
-- In a Stack, children overlap with z-order = insertion order
-- (first child at bottom, last on top). When children are removed
-- and re-added, the native z-order depends on the order of
-- addView calls. This test verifies that after mutations the
-- top-most (last) child receives taps.
--
-- State0: Stack [BG_TEXT, TOP_BUTTON] — button on top, tappable
-- State1: Stack [TOP_BUTTON, BG_TEXT] — text on top, button hidden
--
-- After switch, tapping where the button was should NOT fire the
-- button's callback (text is on top blocking taps).
module Main where

import Data.IORef (IORef, newIORef, readIORef, modifyIORef', writeIORef)
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState, runActionM, createAction, Action)
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Widget(..), text)

data TestState = ButtonOnTop | TextOnTop
  deriving (Show, Eq)

main :: IO (Ptr AppContext)
main = do
  platformLog "StackZOrder demo registered"
  actionState <- newActionState
  testState <- newIORef ButtonOnTop
  tapCount <- newIORef (0 :: Int)
  tapAction <- runActionM actionState $
    createAction $ do
      modifyIORef' tapCount (+ 1)
      count <- readIORef tapCount
      platformLog ("Stack button tapped: " <> Text.pack (show count))
  -- Reset tap count on switch so we can detect new taps cleanly
  switchAndResetAction <- runActionM actionState $
    createAction $ do
      modifyIORef' testState toggle
      writeIORef tapCount 0
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> stackZOrderView testState tapCount tapAction switchAndResetAction
    , maActionState = actionState
    }

toggle :: TestState -> TestState
toggle ButtonOnTop = TextOnTop
toggle TextOnTop = ButtonOnTop

stackZOrderView :: IORef TestState -> IORef Int -> Action -> Action -> IO Widget
stackZOrderView testState tapCount tapAction switchAction = do
  state <- readIORef testState
  count <- readIORef tapCount
  platformLog ("Stack state: " <> Text.pack (show state) <> " taps=" <> Text.pack (show count))
  let stackChildren = case state of
        ButtonOnTop ->
          [ text "BG_LAYER"
          , Button ButtonConfig
              { bcLabel = "TAP_TARGET"
              , bcAction = tapAction
              , bcFontConfig = Nothing
              }
          ]
        TextOnTop ->
          [ Button ButtonConfig
              { bcLabel = "TAP_TARGET"
              , bcAction = tapAction
              , bcFontConfig = Nothing
              }
          , text "OVERLAY_TEXT"
          ]
  pure $ Column
    [ Button ButtonConfig
        { bcLabel = "Switch order"
        , bcAction = switchAction
        , bcFontConfig = Nothing
        }
    , Stack stackChildren
    ]
