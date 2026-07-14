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
--
-- The GATT buttons target the fixed UUIDs served by the virtual test
-- peripheral (test/android/ble_peripheral.py); byte payloads are
-- logged as decimal byte lists so the test scripts can assert them
-- unambiguously.
module Main where

import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text, pack)
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
import Data.UUID.Types qualified as UUID
import Hatter.Ble
  ( BleState(..)
  , BleScanResult(..)
  , BleAdvertisement(..)
  , BleAdvertisementWithErrors(..)
  , BleDeviceAddress(..)
  , BleServiceUuid(..)
  , BleCharacteristicUuid(..)
  , BleCharacteristicValue(..)
  , BleMtu(..)
  , BleDiscoveredCharacteristic(..)
  , BleGattError
  , BleWriteMode(..)
  , checkBleAdapter
  , startBleScan
  , startFilteredBleScan
  , stopBleScan
  , connectBleDevice
  , disconnectBleDevice
  , discoverBleServices
  , readBleCharacteristic
  , writeBleCharacteristic
  , subscribeBleCharacteristic
  , requestBleMtu
  )
import Hatter.Widget (ButtonConfig(..), TextConfig(..), Widget(..), column)

-- | Service served by the virtual test peripheral.
demoServiceUuid :: BleServiceUuid
demoServiceUuid = "50DB505C-8AC4-4738-8448-3B1D9CC09CC5"

-- | Readable characteristic on the test peripheral (value "hatter").
demoReadCharacteristicUuid :: BleCharacteristicUuid
demoReadCharacteristicUuid = "486F64C6-4B5F-4B3B-8AFF-EDE56A8B54F5"

-- | Write+notify characteristic on the test peripheral: written bytes
-- are echoed back as a notification.
demoEchoCharacteristicUuid :: BleCharacteristicUuid
demoEchoCharacteristicUuid = "8CB7C0F4-3B97-4653-9E4F-6F02BF97C7FB"

-- | Payload the Write button sends (echoed back by the peripheral).
demoWritePayload :: BleCharacteristicValue
demoWritePayload = "hatter!"

main :: IO (Ptr AppContext)
main = do
  platformLog "BLE demo app registered"
  actionState <- newActionState
  bleStateRef <- newIORef (Nothing :: Maybe BleState)
  lastAddressRef <- newIORef (Nothing :: Maybe BleDeviceAddress)
  actions <- runActionM actionState $ do
    -- Action creation order defines the iOS autotest event ids
    -- (see ios/Hatter/ContentView.swift): 0 = Check Adapter,
    -- 1 = Start Scan, 2 = Stop Scan, 3 = Connect, 4 = Disconnect,
    -- 5 = Discover, 6 = Read, 7 = Write, 8 = Subscribe,
    -- 9 = Request Mtu, 10 = Filtered Scan.
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
    discover <- createAction $ do
      Just bleState <- readIORef bleStateRef
      discoverBleServices bleState logDiscoveryResult
    readCharacteristic <- createAction $ do
      Just bleState <- readIORef bleStateRef
      readBleCharacteristic bleState demoServiceUuid demoReadCharacteristicUuid $ \result ->
        case result of
          Left gattError -> platformLog ("BLE read failed: " <> pack (show gattError))
          Right payload  -> platformLog
            ("BLE read result: "
             <> pack (show (BS.unpack (unBleCharacteristicValue payload))))
    writeCharacteristic <- createAction $ do
      Just bleState <- readIORef bleStateRef
      writeBleCharacteristic bleState demoServiceUuid demoEchoCharacteristicUuid
        BleWriteWithResponse demoWritePayload $ \result ->
          case result of
            Left gattError -> platformLog ("BLE write failed: " <> pack (show gattError))
            Right ()       -> platformLog "BLE write completed"
    subscribe <- createAction $ do
      Just bleState <- readIORef bleStateRef
      subscribeBleCharacteristic bleState demoServiceUuid demoEchoCharacteristicUuid
        (\payload -> platformLog
          ("BLE notification: "
           <> pack (show (BS.unpack (unBleCharacteristicValue payload)))))
        (\result -> case result of
            Left gattError -> platformLog ("BLE subscribe failed: " <> pack (show gattError))
            Right ()       -> platformLog "BLE subscribed")
    mtu <- createAction $ do
      Just bleState <- readIORef bleStateRef
      requestBleMtu bleState (BleMtu 247) $ \result ->
        case result of
          Left gattError -> platformLog ("BLE mtu failed: " <> pack (show gattError))
          Right granted  -> platformLog ("BLE mtu granted: " <> pack (show (unBleMtu granted)))
    filteredScan <- createAction $ do
      Just bleState <- readIORef bleStateRef
      startFilteredBleScan bleState demoServiceUuid $ \scanResult ->
        platformLog ("BLE filtered scan result: " <> pack (show scanResult))
      platformLog "BLE filtered scan started"
    pure
      [ ("Check Adapter", check)
      , ("Start Scan", start)
      , ("Stop Scan", stop)
      , ("Connect", connect)
      , ("Disconnect", disconnect)
      , ("Discover", discover)
      , ("Read", readCharacteristic)
      , ("Write", writeCharacteristic)
      , ("Subscribe", subscribe)
      , ("Request Mtu", mtu)
      , ("Filtered Scan", filteredScan)
      ]
  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> bleDemoView actions
    , maActionState = actionState
    }
  appCtx <- derefAppContext ctxPtr
  writeIORef bleStateRef (Just (acBleState appCtx))
  pure ctxPtr

-- | Scan callback: log the result (advertisement payloads on their
-- own line, as decimal byte lists like the GATT logs) and remember
-- its address as the Connect target.
logAndRememberScanResult :: IORef (Maybe BleDeviceAddress) -> BleScanResult -> IO ()
logAndRememberScanResult lastAddressRef scanResult = do
  platformLog ("BLE scan result: " <> pack (show scanResult))
  case bsrAdvertisement scanResult of
    Left withErrors -> do
      platformLog ("BLE adv parse errors: "
        <> pack (show (advertisementParseErrors withErrors)))
      logServiceData (partialAdvertisement withErrors)
    Right advertisement -> logServiceData advertisement
  writeIORef lastAddressRef (Just (bsrDeviceAddress scanResult))

-- | Log every service data entry as a decimal byte list.
logServiceData :: BleAdvertisement -> IO ()
logServiceData advertisement =
  mapM_ (\(uuid, payload) ->
      platformLog ("BLE adv service data: " <> UUID.toText uuid
        <> "=" <> pack (show (BS.unpack payload))))
    (advServiceData advertisement)

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

-- | Log every discovered characteristic plus a completion line the
-- integration test asserts on.
logDiscoveryResult
  :: Either BleGattError [BleDiscoveredCharacteristic] -> IO ()
logDiscoveryResult result =
  case result of
    Left gattError -> platformLog ("BLE discovery failed: " <> pack (show gattError))
    Right discovered -> do
      mapM_ logDiscoveredCharacteristic discovered
      platformLog
        ("BLE discovery complete: "
         <> pack (show (length discovered)) <> " characteristics")

-- | One "BLE discovered:" line per characteristic.
logDiscoveredCharacteristic :: BleDiscoveredCharacteristic -> IO ()
logDiscoveredCharacteristic discovered = platformLog
  ("BLE discovered: "
   <> unBleServiceUuid (bdcService discovered)
   <> " " <> unBleCharacteristicUuid (bdcCharacteristic discovered)
   <> " " <> pack (show (bdcProperties discovered)))

-- | Builds a Column with a label and one button per BLE action.
bleDemoView :: [(Text, Action)] -> IO Widget
bleDemoView actions = pure $ column
  ( Text TextConfig { tcLabel = "BLE Demo", tcFontConfig = Nothing }
  : map actionButton actions
  )

-- | A button for one labelled action.
actionButton :: (Text, Action) -> Widget
actionButton (label, action) = Button ButtonConfig
  { bcLabel = label, bcAction = action, bcFontConfig = Nothing }
