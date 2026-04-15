{-# LANGUAGE OverloadedStrings #-}
-- | Reproducer: removing children from a Column container.
--
-- Tests the childrenStable optimization path in diffContainer.
-- When children are removed from the end, the stable path fires
-- (remove excess, keep rest). When children are removed from the
-- middle, positions shift and the unstable path fires (remove-all,
-- re-add-all).
--
-- This test cycles through 3 states:
--   State0: Column [A, B, C]        — 3 children
--   State1: Column [A, C]           — B removed (middle removal)
--   State2: Column [A]              — C removed (tail removal)
--
-- Verifies that only the correct children remain visible after each switch.
module Main where

import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState, runActionM, createAction, Action)
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Widget(..), text)

data TestState = State0 | State1 | State2
  deriving (Show, Eq)

main :: IO (Ptr AppContext)
main = do
  platformLog "ColumnChildRemoval demo registered"
  actionState <- newActionState
  testState <- newIORef State0
  advanceAction <- runActionM actionState $
    createAction (modifyIORef' testState advance)
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> childRemovalView testState advanceAction
    , maActionState = actionState
    }

advance :: TestState -> TestState
advance State0 = State1
advance State1 = State2
advance State2 = State0

childRemovalView :: IORef TestState -> Action -> IO Widget
childRemovalView testState advanceAction = do
  state <- readIORef testState
  platformLog ("Column state: " <> Text.pack (show state))
  let children = case state of
        State0 -> [ text "CHILD_A", text "CHILD_B", text "CHILD_C" ]
        State1 -> [ text "CHILD_A", text "CHILD_C" ]
        State2 -> [ text "CHILD_A" ]
  pure $ Column
    ( Button ButtonConfig
        { bcLabel = "Advance"
        , bcAction = advanceAction
        , bcFontConfig = Nothing
        }
    : children
    )
