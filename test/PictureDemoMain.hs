{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the picture-picker test app.
--
-- Used by the emulator picture integration test. A button lets the user
-- pick a picture; loggingMobileContext logs the PNG that comes back.
module Main where

import Foreign.Ptr (Ptr)
import Hatter
  ( MobileApp(..)
  , startMobileApp
  , platformLog
  , loggingMobileContext
  , newActionState
  , runActionM
  , createAction
  , pickPicture
  )
import Hatter.AppContext (AppContext)
import Hatter.Widget (ButtonConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  actionState <- newActionState
  pick <- runActionM actionState (createAction (pickPicture [64] 65536))
  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> pure $ column
        [ Button ButtonConfig
            { bcLabel      = "Pick Picture"
            , bcAction     = pick
            , bcFontConfig = Nothing
            , bcTextColor = Nothing
            }
        ]
    , maActionState = actionState
    }
  platformLog "Picture demo app registered"
  pure ctxPtr
