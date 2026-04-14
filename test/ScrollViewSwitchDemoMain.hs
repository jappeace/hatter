{-# LANGUAGE OverloadedStrings #-}
-- | Reproducer for issue #168: switching between two ScrollViews
-- via state causes the diff algorithm to "mix" their content.
--
-- The app alternates between two screens, each a ScrollView with
-- distinct children. After switching, only the new screen's
-- content should be visible — any leftover from the old screen
-- is the bug.
module Main where

import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState, runActionM, createAction, Action)
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Widget(..), text)

data Screen = ScreenA | ScreenB
  deriving (Show, Eq)

main :: IO (Ptr AppContext)
main = do
  platformLog "ScrollView switch demo registered"
  actionState <- newActionState
  screenState <- newIORef ScreenA
  switchAction <- runActionM actionState $
    createAction (modifyIORef' screenState toggle)
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> switchDemoView screenState switchAction
    , maActionState = actionState
    }

toggle :: Screen -> Screen
toggle ScreenA = ScreenB
toggle ScreenB = ScreenA

-- | The view function: a Column with a switch button and a ScrollView
-- whose content depends on the current screen.
--
-- When switching from ScreenA to ScreenB, the diff sees two ScrollViews
-- of the same type and tries to reuse the container. If the diff or
-- native bridge has a bug, children from ScreenA may linger alongside
-- ScreenB's children ("mixing").
switchDemoView :: IORef Screen -> Action -> IO Widget
switchDemoView screenState switchAction = do
  screen <- readIORef screenState
  platformLog ("Current screen: " <> Text.pack (show screen))
  let inner = case screen of
        ScreenA -> ScrollView
          [ text "SCREENA_ITEM1"
          , text "SCREENA_ITEM2"
          , text "SCREENA_ITEM3"
          ]
        ScreenB -> ScrollView
          [ text "SCREENB_ITEM1"
          , text "SCREENB_ITEM2"
          ]
  pure $ Column
    [ Button ButtonConfig
        { bcLabel = "Switch screen"
        , bcAction = switchAction
        , bcFontConfig = Nothing
        }
    , inner
    ]
