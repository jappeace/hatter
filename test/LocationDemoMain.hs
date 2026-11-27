{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the location-demo test app.
--
-- Used by the emulator and simulator location integration tests.
-- Starts directly in location-demo mode so no runtime switching is needed.
--
-- The view function is kept pure (no IO / FFI calls) to avoid
-- JNI reentrancy issues on armv7a.  Location FFI calls run on
-- button press instead.
module Main where

import Control.Concurrent (forkOS)
import Control.Monad (void)
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
import Hatter.Location (LocationState(..), startLocationUpdates, stopLocationUpdates)
import Hatter.Location (LocationData(..))
import Hatter.Widget (ButtonConfig(..), TextConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  platformLog "Location demo app registered"
  actionState <- newActionState
  locStateRef <- newIORef (Nothing :: Maybe LocationState)
  (onStartLocation, onStopLocation, onStopFromThread) <- runActionM actionState $ do
    start <- createAction $ do
      Just locationState <- readIORef locStateRef
      startLocationUpdates locationState $ \locationData ->
        platformLog ("Location: " <> pack (show (ldLatitude locationData))
                    <> "," <> pack (show (ldLongitude locationData))
                    <> " alt=" <> pack (show (ldAltitude locationData))
                    <> " acc=" <> pack (show (ldAccuracy locationData)))
      platformLog "Location updates started"
    stop <- createAction $ do
      Just locationState <- readIORef locStateRef
      stopLocationUpdates locationState
      platformLog "Location updates stopped"
    -- As an app's timeout does, from an OS thread other than the UI's.
    stopElsewhere <- createAction $ do
      Just locationState <- readIORef locStateRef
      void . forkOS $ do
        stopLocationUpdates locationState
        platformLog "Location updates stopped from a thread"
    pure (start, stop, stopElsewhere)
  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> locationDemoView onStartLocation onStopLocation onStopFromThread
    , maActionState = actionState
    }
  appCtx <- derefAppContext ctxPtr
  writeIORef locStateRef (Just (acLocationState appCtx))
  pure ctxPtr

-- | Builds a Column with a label and start/stop location buttons.
locationDemoView :: Action -> Action -> Action -> IO Widget
locationDemoView onStartLocation onStopLocation onStopFromThread = pure $ column
  [ Text TextConfig { tcLabel = "Location Demo", tcFontConfig = Nothing, tcTextColor = Nothing }
  , Button ButtonConfig
      { bcLabel = "Start Location", bcAction = onStartLocation, bcFontConfig = Nothing, bcTextColor = Nothing }
  , Button ButtonConfig
      { bcLabel = "Stop Location", bcAction = onStopLocation, bcFontConfig = Nothing, bcTextColor = Nothing }
  , Button ButtonConfig
      { bcLabel = "Stop Location From Thread", bcAction = onStopFromThread, bcFontConfig = Nothing, bcTextColor = Nothing }
  ]
