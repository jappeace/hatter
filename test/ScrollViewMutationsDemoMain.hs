{-# LANGUAGE OverloadedStrings #-}
-- | Reproducer: add/remove/reorder children inside a ScrollView.
--
-- Tests the inner LinearLayout/StackView wrapper handling:
-- - addChild redirects to inner layout (getChildAt(0))
-- - removeChild redirects to inner layout
-- - If getChildAt(0) fails, addChild falls through to the raw ScrollView
--
-- State0: ScrollView [A, B, C]       — 3 children
-- State1: ScrollView [A, B, C, D]    — add child
-- State2: ScrollView [A, C, D]       — remove middle child
-- State3: ScrollView [D, C, A]       — reorder
module Main where

import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (startMobileApp, platformLog, loggingMobileContext, MobileApp(..), newActionState, runActionM, createAction, Action)
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Widget(..), text)

data TestState = SV0 | SV1 | SV2 | SV3
  deriving (Show, Eq)

main :: IO (Ptr AppContext)
main = do
  platformLog "ScrollViewMutations demo registered"
  actionState <- newActionState
  testState <- newIORef SV0
  advanceAction <- runActionM actionState $
    createAction (modifyIORef' testState advance)
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> scrollMutationsView testState advanceAction
    , maActionState = actionState
    }

advance :: TestState -> TestState
advance SV0 = SV1
advance SV1 = SV2
advance SV2 = SV3
advance SV3 = SV0

scrollMutationsView :: IORef TestState -> Action -> IO Widget
scrollMutationsView testState advanceAction = do
  state <- readIORef testState
  platformLog ("ScrollView state: " <> Text.pack (show state))
  let scrollChildren = case state of
        SV0 -> [ text "SV_ITEM_A", text "SV_ITEM_B", text "SV_ITEM_C" ]
        SV1 -> [ text "SV_ITEM_A", text "SV_ITEM_B", text "SV_ITEM_C", text "SV_ITEM_D" ]
        SV2 -> [ text "SV_ITEM_A", text "SV_ITEM_C", text "SV_ITEM_D" ]
        SV3 -> [ text "SV_ITEM_D", text "SV_ITEM_C", text "SV_ITEM_A" ]
  pure $ Column
    [ Button ButtonConfig
        { bcLabel = "Advance"
        , bcAction = advanceAction
        , bcFontConfig = Nothing
        }
    , ScrollView scrollChildren
    ]
