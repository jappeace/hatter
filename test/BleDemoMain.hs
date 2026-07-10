{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the BLE-demo test app.
--
-- Used by the emulator and simulator BLE integration tests.
-- Starts directly in BLE-demo mode so no runtime switching is needed.
--
-- The view function is kept pure (no IO / FFI calls) to avoid
-- JNI reentrancy issues on armv7a.  The adapter check runs on
-- button press instead.
--
-- The scan callback remembers the address of the last discovered
-- device; Connect targets that device.  When Connect is pressed
-- before any device was discovered a placeholder address is used, so
-- the connect bridge path is exercised (and fails with
-- 'BleConnectionFailed') even on platforms where scanning finds
-- nothing, such as the iOS simulator.
module Main where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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
import Hatter.Ble
  ( BleState(..)
  , BleScanResult(..)
  , BleDeviceAddress(..)
  , checkBleAdapter
  , startBleScan
  , stopBleScan
  , connectBleDevice
  , disconnectBleDevice
  )
import Hatter.Widget (ButtonConfig(..), TextConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  platformLog "BLE demo app registered"
  actionState <- newActionState
  bleStateRef <- newIORef (Nothing :: Maybe BleState)
  lastAddressRef <- newIORef (Nothing :: Maybe BleDeviceAddress)
  (onCheckAdapter, onStartScan, onStopScan, onConnect, onDisconnect) <-
    runActionM actionState $ do
      check <- createAction $ do
        adapterStatus <- checkBleAdapter
        platformLog ("BLE adapter: " <> pack (show adapterStatus))
      start <- createAction $ do
        Just bleState <- readIORef bleStateRef
        startBleScan bleState (logAndRememberScanResult lastAddressRef)
        platformLog "BLE scan started"
      stop <- createAction $ do
        Just bleState <- readIORef bleStateRef
        stopBleScan bleState
        platformLog "BLE scan stopped"
      connect <- createAction $ do
        Just bleState <- readIORef bleStateRef
        address <- connectTargetAddress lastAddressRef
        platformLog ("BLE connecting to " <> unBleDeviceAddress address)
        connectBleDevice bleState address $ \event ->
          platformLog ("BLE connection event: " <> pack (show event))
      disconnect <- createAction $ do
        Just bleState <- readIORef bleStateRef
        disconnectBleDevice bleState
        platformLog "BLE disconnect requested"
      pure (check, start, stop, connect, disconnect)
  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState ->
        bleDemoView onCheckAdapter onStartScan onStopScan onConnect onDisconnect
    , maActionState = actionState
    }
  appCtx <- derefAppContext ctxPtr
  writeIORef bleStateRef (Just (acBleState appCtx))
  pure ctxPtr

-- | Scan callback: log the result and remember its address as the
-- Connect target.
logAndRememberScanResult :: IORef (Maybe BleDeviceAddress) -> BleScanResult -> IO ()
logAndRememberScanResult lastAddressRef scanResult = do
  platformLog ("BLE scan result: " <> pack (show scanResult))
  writeIORef lastAddressRef (Just (bsrDeviceAddress scanResult))

-- | Address the Connect button targets: the last discovered device,
-- or a placeholder when nothing was discovered yet (so the connect
-- path is still exercised and fails visibly).
connectTargetAddress :: IORef (Maybe BleDeviceAddress) -> IO BleDeviceAddress
connectTargetAddress lastAddressRef = do
  maybeAddress <- readIORef lastAddressRef
  case maybeAddress of
    Just address -> pure address
    Nothing -> do
      platformLog "BLE connect: no scan result yet, using placeholder address"
      pure (BleDeviceAddress "00:11:22:33:44:55")

-- | Builds a Column with a label, adapter check button, scan buttons,
-- and connection buttons.
bleDemoView :: Action -> Action -> Action -> Action -> Action -> IO Widget
bleDemoView onCheckAdapter onStartScan onStopScan onConnect onDisconnect = pure $ column
  [ Text TextConfig { tcLabel = "BLE Demo", tcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Check Adapter", bcAction = onCheckAdapter, bcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Start Scan", bcAction = onStartScan, bcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Stop Scan", bcAction = onStopScan, bcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Connect", bcAction = onConnect, bcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Disconnect", bcAction = onDisconnect, bcFontConfig = Nothing }
  ]
