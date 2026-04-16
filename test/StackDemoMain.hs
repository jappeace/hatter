{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the stack-demo test app.
--
-- Used by the emulator and simulator integration tests.
-- Displays a Stack with a colored background text and an overlay button.
-- Tapping the button increments a counter, verifying touch passthrough works.
module Main where

import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState, runActionM, createAction, Action)
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Color(..), TextConfig(..), Widget(..), WidgetStyle(..), defaultStyle, item)

main :: IO (Ptr AppContext)
main = do
  platformLog "Stack demo app registered"
  actionState <- newActionState
  counterState <- newIORef (0 :: Int)
  onTap <- runActionM actionState $
    createAction (modifyIORef' counterState (+ 1))
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> stackDemoView counterState onTap
    , maActionState = actionState
    }

-- | Stack view: background text, middle button, and a passthrough overlay on top.
-- The overlay has @wsTouchPassthrough = True@ so taps pass through it to the
-- button below, verifying that touch passthrough actually works.
stackDemoView :: IORef Int -> Action -> IO Widget
stackDemoView counterState onTap = do
  n <- readIORef counterState
  platformLog ("Stack counter: " <> Text.pack (show n))
  pure $ Stack
    [ -- Layer 0 (bottom): colored background label
      item (Styled (defaultStyle { wsBackgroundColor = Just (Color 200 200 255 255) })
        (Text TextConfig
          { tcLabel      = "Background: " <> Text.pack (show n)
          , tcFontConfig = Nothing
          }))
    , -- Layer 1 (middle): tappable button
      item (Button ButtonConfig
        { bcLabel = "Tap overlay"
        , bcAction = onTap
        , bcFontConfig = Nothing
        })
    , -- Layer 2 (top): passthrough overlay — touches must pass through to button
      item (Styled (defaultStyle { wsTouchPassthrough = Just True
                           , wsBackgroundColor = Just (Color 0 0 0 0)
                           })
        (Text TextConfig
          { tcLabel      = "Passthrough overlay"
          , tcFontConfig = Nothing
          }))
    ]
