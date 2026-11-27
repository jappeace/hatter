{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the permission-demo test app.
--
-- Used by the emulator and simulator permission integration tests.
-- Starts directly in permission-demo mode so no runtime switching is needed.
module Main where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (pack)
import Foreign.Ptr (Ptr)
import Hatter
  ( MobileApp(..)
  , Action
  , startMobileApp
  , platformLog
  , loggingMobileContext
  , newActionState
  , runActionM
  , createAction
  )
import Hatter.AppContext (AppContext(..), derefAppContext)
import Hatter.Permission (Permission(..), PermissionState(..), requestPermission)
import Hatter.Widget (ButtonConfig(..), TextConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  platformLog "Permission demo app registered"
  actionState <- newActionState
  permStateRef <- newIORef (Nothing :: Maybe PermissionState)
  (onRequestCamera, onRequestLocation) <- runActionM actionState $ (,)
    <$> createAction (do
      Just permState <- readIORef permStateRef
      requestPermission permState PermissionCamera $ \status ->
        platformLog ("Permission result: " <> pack (show status)))
    <*> createAction (do
      Just permState <- readIORef permStateRef
      requestPermission permState PermissionLocation $ \status ->
        platformLog ("Location permission result: " <> pack (show status)))
  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> permissionDemoView onRequestCamera onRequestLocation
    , maActionState = actionState
    }
  appCtx <- derefAppContext ctxPtr
  writeIORef permStateRef (Just (acPermissionState appCtx))
  pure ctxPtr

-- | Builds a Column with a label and "Request Camera" and "Request Location" buttons.
permissionDemoView :: Action -> Action -> IO Widget
permissionDemoView onRequestCamera onRequestLocation = pure $ column
  [ Text TextConfig { tcLabel = "Permission Demo", tcFontConfig = Nothing, tcTextColor = Nothing }
  , Button ButtonConfig
      { bcLabel      = "Request Camera"
      , bcAction     = onRequestCamera
      , bcFontConfig = Nothing
      , bcTextColor = Nothing
      }
  , Button ButtonConfig
      { bcLabel      = "Request Location"
      , bcAction     = onRequestLocation
      , bcFontConfig = Nothing
      , bcTextColor = Nothing
      }
  ]
