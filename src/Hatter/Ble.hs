{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
-- | BLE (Bluetooth Low Energy) API for mobile platforms.
--
-- Provides adapter status check, start\/stop scan (optionally filtered
-- by service UUID), GATT connection management, and GATT operations:
-- service discovery, characteristic read\/write, notification
-- subscriptions and MTU negotiation.  Scan results, connection events
-- and notifications are delivered via streaming callbacks (multiple
-- invocations per registration); GATT operations complete exactly once
-- per request.
--
-- Exactly one GATT operation may be outstanding at a time (matching
-- the platform stacks); starting a second one fails it immediately
-- with 'BleGattBusy'.
--
-- On desktop (no platform bridge registered) the C stub reports
-- the adapter as on, start\/stop scan are no-ops, and connection
-- attempts and GATT operations immediately deliver visible failures,
-- so @cabal test@ works without native code.
module Hatter.Ble
  ( BleAdapterStatus(..)
  , BleScanResult(..)
  , BleDeviceAddress(..)
  , BleServiceUuid(..)
  , BleCharacteristicUuid(..)
  , NormalizedBleUuid(..)
  , BleCharacteristicKey(..)
  , BleCharacteristicValue(..)
  , BleMtu(..)
  , BleConnectionEvent(..)
  , BleCharacteristicProperty(..)
  , BleDiscoveredCharacteristic(..)
  , BleWriteMode(..)
  , BleGattOperation(..)
  , BleGattError(..)
  , BleGattCompletion(..)
  , PendingBleGattOperation(..)
  , BleState(..)
  , newBleState
  , normalizeBleServiceUuid
  , normalizeBleCharacteristicUuid
  , bleCharacteristicKey
  , bleAdapterStatusFromInt
  , bleAdapterStatusToInt
  , bleConnectionEventFromInt
  , bleConnectionEventToInt
  , bleGattOperationFromInt
  , bleGattOperationToInt
  , bleCharacteristicPropertiesFromBits
  , bleCharacteristicPropertiesToBits
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
  , unsubscribeBleCharacteristic
  , requestBleMtu
  , dispatchBleScanResult
  , dispatchBleConnectionEvent
  , dispatchBleCharacteristicDiscovered
  , dispatchBleGattCompletion
  , dispatchBleNotification
  )
where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.String (IsString)
import Data.Text (Text, pack, toLower, unpack)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Utils (maybeWith)
import Foreign.Ptr (Ptr, nullPtr)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt
import Unwitch.Convert.Int qualified as Int

-- | Status of the platform's BLE adapter.
data BleAdapterStatus
  = BleAdapterOff
  | BleAdapterOn
  | BleAdapterUnauthorized
  | BleAdapterUnsupported
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | A BLE device address as delivered by the platform: a MAC address
-- on Android, a peripheral identifier UUID on iOS.  Opaque to
-- applications; pass it back verbatim to 'connectBleDevice'.
newtype BleDeviceAddress = BleDeviceAddress { unBleDeviceAddress :: Text }
  deriving (Show, Eq, Ord)
  deriving newtype (IsString)

-- | A 128-bit GATT service UUID string, e.g.
-- @"50DB505C-8AC4-4738-8448-3B1D9CC09CC5"@.  Case-insensitive on both
-- platforms.
newtype BleServiceUuid = BleServiceUuid { unBleServiceUuid :: Text }
  deriving (Show, Eq, Ord)
  deriving newtype (IsString)

-- | A 128-bit GATT characteristic UUID string.
newtype BleCharacteristicUuid = BleCharacteristicUuid { unBleCharacteristicUuid :: Text }
  deriving (Show, Eq, Ord)
  deriving newtype (IsString)

-- | A UUID string normalized to lowercase for comparisons.  UUIDs are
-- case-insensitive per the Bluetooth spec, but the platforms disagree
-- on the case they report (Android lowercase, iOS uppercase), so raw
-- strings must never be compared directly.  Constructed via
-- 'normalizeBleServiceUuid' \/ 'normalizeBleCharacteristicUuid';
-- deliberately no 'IsString' instance, a literal would bypass the
-- normalization.
--
-- Decision: case-insensitivity is a dedicated normalized newtype
-- built only through smart constructors.  Alternatives considered:
-- lowercasing ad hoc at each comparison site (error-prone, exactly
-- how the original subscribe\/notify mismatch bug happened), and a
-- case-insensitive 'Ord' on the raw UUID newtypes (invisible at use
-- sites and surprising for anyone sorting or printing them).  A type
-- that cannot exist un-normalized makes the mistake unrepresentable.
newtype NormalizedBleUuid = NormalizedBleUuid { unNormalizedBleUuid :: Text }
  deriving (Show, Eq, Ord)

-- | Identifies one characteristic on the connected device: its
-- containing service and its own UUID, case-normalized so lookups
-- match across platforms.  Used as the notification-callback key.
data BleCharacteristicKey = BleCharacteristicKey
  { bckService        :: NormalizedBleUuid
  , bckCharacteristic :: NormalizedBleUuid
  } deriving (Show, Eq, Ord)

-- | The bytes of a characteristic's value: read results, write
-- payloads and notification payloads.
newtype BleCharacteristicValue = BleCharacteristicValue
  { unBleCharacteristicValue :: ByteString }
  deriving (Show, Eq, Ord)
  deriving newtype (IsString)

-- | An ATT MTU in bytes.  Write payloads should stay within
-- @'unBleMtu' granted - 3@ bytes (the 3 bytes are the ATT header).
newtype BleMtu = BleMtu { unBleMtu :: Int }
  deriving (Show, Eq, Ord)

-- | A single BLE scan result delivered by the platform.
data BleScanResult = BleScanResult
  { bsrDeviceName    :: Text
  , bsrDeviceAddress :: BleDeviceAddress
  , bsrRssi          :: Int
  } deriving (Show, Eq)

-- | A connection state change delivered by the platform for the
-- connection requested via 'connectBleDevice'.
data BleConnectionEvent
  = BleConnectionEstablished
    -- ^ The GATT connection is up.
  | BleConnectionClosed
    -- ^ An established connection ended normally (peer or
    -- 'disconnectBleDevice' initiated).
  | BleConnectionFailed
    -- ^ The connection attempt failed, or an established connection
    -- was lost with an error.
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | What a characteristic supports, as reported by discovery.
data BleCharacteristicProperty
  = BleCharacteristicRead
  | BleCharacteristicWrite
  | BleCharacteristicWriteNoResponse
  | BleCharacteristicNotify
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | One characteristic found by 'discoverBleServices'.
data BleDiscoveredCharacteristic = BleDiscoveredCharacteristic
  { bdcService        :: BleServiceUuid
  , bdcCharacteristic :: BleCharacteristicUuid
  , bdcProperties     :: [BleCharacteristicProperty]
  } deriving (Show, Eq)

-- | How to write a characteristic: acknowledged by the peripheral or
-- fire-and-forget.
data BleWriteMode
  = BleWriteWithResponse
  | BleWriteWithoutResponse
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | The GATT operations that complete asynchronously.  Mirrors the
-- @BLE_GATT_OP_*@ constants in @BleBridge.h@.
data BleGattOperation
  = BleGattDiscover
  | BleGattRead
  | BleGattWrite
  | BleGattSubscribe
  | BleGattUnsubscribe
  | BleGattRequestMtu
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Why a GATT operation failed.
data BleGattError
  = BleGattBusy
    -- ^ Another GATT operation is still outstanding; retry after its
    -- callback fires.
  | BleGattFailed Int
    -- ^ The platform reported a nonzero status code.  @-1@ means no
    -- platform implementation is registered (desktop, or an outdated
    -- consumer Activity); @-2@ means the platform completed a
    -- different operation than the one pending (a platform bug);
    -- other values are passed through from Android
    -- (@BluetoothGatt@ status) or iOS (@NSError@ code, with
    -- @0x101@ for failures before CoreBluetooth was reached).
  deriving (Show, Eq)

-- | A decoded GATT completion from the platform, built at the FFI
-- boundary ('Hatter.haskellOnBleGattResult').
data BleGattCompletion = BleGattCompletion
  { bgcOperation  :: BleGattOperation
  , bgcStatusCode :: Int
    -- ^ 0 = success.
  , bgcPayload    :: BleCharacteristicValue
    -- ^ Read data for 'BleGattRead'; empty otherwise.
  , bgcGrantedMtu :: BleMtu
    -- ^ Granted MTU for 'BleGattRequestMtu'; 'BleMtu' 0 otherwise.
  } deriving (Show, Eq)

-- | The one GATT operation currently in flight, with its
-- result callback.  'BleGattError' code @-2@ is delivered if the
-- platform completes a different operation (see
-- 'dispatchBleGattCompletion').
data PendingBleGattOperation
  = PendingBleDiscover (IORef [BleDiscoveredCharacteristic])
      (Either BleGattError [BleDiscoveredCharacteristic] -> IO ())
  | PendingBleRead (Either BleGattError BleCharacteristicValue -> IO ())
  | PendingBleWrite (Either BleGattError () -> IO ())
  | PendingBleSubscribe BleCharacteristicKey
      (Either BleGattError () -> IO ())
  | PendingBleUnsubscribe BleCharacteristicKey
      (Either BleGattError () -> IO ())
  | PendingBleMtu (Either BleGattError BleMtu -> IO ())

-- | Mutable state for the BLE subsystem.
-- Uses 'IORef (Maybe callback)' instead of 'IntMap' because only
-- one scan, one connection and one GATT operation can be active at
-- a time.
data BleState = BleState
  { blesScanCallback :: IORef (Maybe (BleScanResult -> IO ()))
    -- ^ Active scan result callback, or 'Nothing' if not scanning.
  , blesConnectionCallback :: IORef (Maybe (BleConnectionEvent -> IO ()))
    -- ^ Active connection event callback, registered by
    -- 'connectBleDevice'.  Stays registered after a disconnect so
    -- that late events (e.g. the 'BleConnectionClosed' following a
    -- 'disconnectBleDevice') still reach the app; a new
    -- 'connectBleDevice' call overwrites it.
  , blesGattPending :: IORef (Maybe PendingBleGattOperation)
    -- ^ The GATT operation currently in flight, if any.
  , blesNotificationCallbacks
      :: IORef (Map BleCharacteristicKey (BleCharacteristicValue -> IO ()))
    -- ^ Per-characteristic notification callbacks, registered by
    -- 'subscribeBleCharacteristic'.
  , blesContextPtr   :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'BleState' with no active scan, connection or
-- GATT operation.  The context pointer is initially null and must be
-- set via 'blesContextPtr' before calling anything that talks to the
-- platform.
newBleState :: IO BleState
newBleState = do
  scanCallback          <- newIORef Nothing
  connectionCallback    <- newIORef Nothing
  gattPending           <- newIORef Nothing
  notificationCallbacks <- newIORef Map.empty
  contextPtr            <- newIORef nullPtr
  pure BleState
    { blesScanCallback          = scanCallback
    , blesConnectionCallback    = connectionCallback
    , blesGattPending           = gattPending
    , blesNotificationCallbacks = notificationCallbacks
    , blesContextPtr            = contextPtr
    }

-- | Convert a C bridge adapter status code to 'BleAdapterStatus'.
-- Returns 'Nothing' for unknown codes.
bleAdapterStatusFromInt :: CInt -> Maybe BleAdapterStatus
bleAdapterStatusFromInt 0 = Just BleAdapterOff
bleAdapterStatusFromInt 1 = Just BleAdapterOn
bleAdapterStatusFromInt 2 = Just BleAdapterUnauthorized
bleAdapterStatusFromInt 3 = Just BleAdapterUnsupported
bleAdapterStatusFromInt _ = Nothing

-- | Convert a 'BleAdapterStatus' to its C bridge integer code.
-- Must match the @BLE_ADAPTER_*@ constants in @BleBridge.h@.
bleAdapterStatusToInt :: BleAdapterStatus -> CInt
bleAdapterStatusToInt BleAdapterOff          = 0
bleAdapterStatusToInt BleAdapterOn           = 1
bleAdapterStatusToInt BleAdapterUnauthorized = 2
bleAdapterStatusToInt BleAdapterUnsupported  = 3

-- | Convert a C bridge connection event code to 'BleConnectionEvent'.
-- Returns 'Nothing' for unknown codes.
bleConnectionEventFromInt :: CInt -> Maybe BleConnectionEvent
bleConnectionEventFromInt 0 = Just BleConnectionEstablished
bleConnectionEventFromInt 1 = Just BleConnectionClosed
bleConnectionEventFromInt 2 = Just BleConnectionFailed
bleConnectionEventFromInt _ = Nothing

-- | Convert a 'BleConnectionEvent' to its C bridge integer code.
-- Must match the @BLE_CONNECTION_*@ constants in @BleBridge.h@.
bleConnectionEventToInt :: BleConnectionEvent -> CInt
bleConnectionEventToInt BleConnectionEstablished = 0
bleConnectionEventToInt BleConnectionClosed      = 1
bleConnectionEventToInt BleConnectionFailed      = 2

-- | Convert a C bridge GATT operation code to 'BleGattOperation'.
-- Returns 'Nothing' for unknown codes.
bleGattOperationFromInt :: CInt -> Maybe BleGattOperation
bleGattOperationFromInt 0 = Just BleGattDiscover
bleGattOperationFromInt 1 = Just BleGattRead
bleGattOperationFromInt 2 = Just BleGattWrite
bleGattOperationFromInt 3 = Just BleGattSubscribe
bleGattOperationFromInt 4 = Just BleGattUnsubscribe
bleGattOperationFromInt 5 = Just BleGattRequestMtu
bleGattOperationFromInt _ = Nothing

-- | Convert a 'BleGattOperation' to its C bridge integer code.
-- Must match the @BLE_GATT_OP_*@ constants in @BleBridge.h@.
bleGattOperationToInt :: BleGattOperation -> CInt
bleGattOperationToInt BleGattDiscover    = 0
bleGattOperationToInt BleGattRead        = 1
bleGattOperationToInt BleGattWrite       = 2
bleGattOperationToInt BleGattSubscribe   = 3
bleGattOperationToInt BleGattUnsubscribe = 4
bleGattOperationToInt BleGattRequestMtu  = 5

-- | Normalize a service UUID for comparisons.
normalizeBleServiceUuid :: BleServiceUuid -> NormalizedBleUuid
normalizeBleServiceUuid = NormalizedBleUuid . toLower . unBleServiceUuid

-- | Normalize a characteristic UUID for comparisons.
normalizeBleCharacteristicUuid :: BleCharacteristicUuid -> NormalizedBleUuid
normalizeBleCharacteristicUuid = NormalizedBleUuid . toLower . unBleCharacteristicUuid

-- | Build the notification-callback key for a characteristic.
bleCharacteristicKey :: BleServiceUuid -> BleCharacteristicUuid -> BleCharacteristicKey
bleCharacteristicKey serviceUuid characteristicUuid = BleCharacteristicKey
  { bckService        = normalizeBleServiceUuid serviceUuid
  , bckCharacteristic = normalizeBleCharacteristicUuid characteristicUuid
  }

-- | The @BLE_CHAR_PROP_*@ bit for one property (see @BleBridge.h@).
bleCharacteristicPropertyBit :: BleCharacteristicProperty -> CInt
bleCharacteristicPropertyBit BleCharacteristicRead            = 1
bleCharacteristicPropertyBit BleCharacteristicWrite           = 2
bleCharacteristicPropertyBit BleCharacteristicWriteNoResponse = 4
bleCharacteristicPropertyBit BleCharacteristicNotify          = 8

-- | Whether a property's bit is set in a @BLE_CHAR_PROP_*@ mask.
bleCharacteristicPropertyPresent :: CInt -> BleCharacteristicProperty -> Bool
bleCharacteristicPropertyPresent bits property =
  bits .&. bleCharacteristicPropertyBit property /= 0

-- | Decode the @BLE_CHAR_PROP_*@ bit mask from @BleBridge.h@.
bleCharacteristicPropertiesFromBits :: CInt -> [BleCharacteristicProperty]
bleCharacteristicPropertiesFromBits bits =
  filter (bleCharacteristicPropertyPresent bits) [minBound .. maxBound]

-- | Encode 'BleCharacteristicProperty's back into the
-- @BLE_CHAR_PROP_*@ bit mask (used by tests to check the roundtrip).
bleCharacteristicPropertiesToBits :: [BleCharacteristicProperty] -> CInt
bleCharacteristicPropertiesToBits = sum . map bleCharacteristicPropertyBit

-- | Check the BLE adapter status (synchronous).
checkBleAdapter :: IO BleAdapterStatus
checkBleAdapter = do
  result <- c_bleCheckAdapter
  case bleAdapterStatusFromInt result of
    Just status -> pure status
    Nothing     -> do
      hPutStrLn stderr $ "checkBleAdapter: unknown status code " ++ show result
      pure BleAdapterUnsupported

-- | Start an unfiltered BLE scan. Stops any existing scan first, then
-- registers the callback and calls the C bridge. The callback will be
-- invoked for each discovered device until 'stopBleScan' is called.
startBleScan :: BleState -> (BleScanResult -> IO ()) -> IO ()
startBleScan bleState callback =
  startBleScanInternal bleState Nothing callback

-- | Start a BLE scan that only reports devices advertising the given
-- service UUID.  Otherwise identical to 'startBleScan'.
startFilteredBleScan :: BleState -> BleServiceUuid -> (BleScanResult -> IO ()) -> IO ()
startFilteredBleScan bleState serviceUuid callback =
  startBleScanInternal bleState (Just serviceUuid) callback

-- | Shared implementation of the scan starters.
startBleScanInternal :: BleState -> Maybe BleServiceUuid -> (BleScanResult -> IO ()) -> IO ()
startBleScanInternal bleState maybeServiceUuid callback = do
  -- Stop any existing scan first
  c_bleStopScan
  -- Register the new callback
  writeIORef (blesScanCallback bleState) (Just callback)
  -- Start scanning via C bridge
  ctx <- readIORef (blesContextPtr bleState)
  maybeWith (withCString . unpack . unBleServiceUuid) maybeServiceUuid
    (c_bleStartScan ctx)

-- | Stop a running BLE scan. Clears the callback so that any
-- late-arriving results are silently dropped.
stopBleScan :: BleState -> IO ()
stopBleScan bleState = do
  writeIORef (blesScanCallback bleState) Nothing
  c_bleStopScan

-- | Connect to a BLE device by the address a scan delivered in
-- 'bsrDeviceAddress'.  Registers the callback and calls the C
-- bridge; the callback is invoked for every connection state change
-- ('BleConnectionEstablished', then eventually 'BleConnectionClosed'
-- or 'BleConnectionFailed') until a new 'connectBleDevice' call
-- replaces it.  Only one connection is held at a time: connecting
-- again closes the previous connection first (handled by the
-- platform side).
connectBleDevice :: BleState -> BleDeviceAddress -> (BleConnectionEvent -> IO ()) -> IO ()
connectBleDevice bleState address callback = do
  writeIORef (blesConnectionCallback bleState) (Just callback)
  ctx <- readIORef (blesContextPtr bleState)
  withCString (unpack (unBleDeviceAddress address)) (c_bleConnect ctx)

-- | Disconnect the active BLE connection. The registered connection
-- callback stays in place so the resulting 'BleConnectionClosed'
-- event is still delivered.  A no-op when nothing is connected.
disconnectBleDevice :: BleState -> IO ()
disconnectBleDevice _bleState = c_bleDisconnect

-- | Register a GATT operation as pending, or fail it immediately with
-- 'BleGattBusy' when one is already in flight.  Runs the given action
-- (the C bridge call) only after successful registration.
startBleGattOperation
  :: BleState
  -> PendingBleGattOperation
  -> (BleGattError -> IO ())  -- ^ How to fail this operation's callback.
  -> IO ()                    -- ^ The C bridge call.
  -> IO ()
startBleGattOperation bleState pending failWith bridgeCall = do
  alreadyPending <- readIORef (blesGattPending bleState)
  case alreadyPending of
    Just _  -> failWith BleGattBusy
    Nothing -> do
      writeIORef (blesGattPending bleState) (Just pending)
      bridgeCall

-- | Discover all services and characteristics on the connected
-- device.  The callback receives every characteristic (with its
-- containing service and properties) or the failure.
discoverBleServices
  :: BleState
  -> (Either BleGattError [BleDiscoveredCharacteristic] -> IO ())
  -> IO ()
discoverBleServices bleState callback = do
  accumulator <- newIORef []
  startBleGattOperation bleState
    (PendingBleDiscover accumulator callback)
    (callback . Left)
    (do ctx <- readIORef (blesContextPtr bleState)
        c_bleDiscoverServices ctx)

-- | Read a characteristic's value.
readBleCharacteristic
  :: BleState
  -> BleServiceUuid
  -> BleCharacteristicUuid
  -> (Either BleGattError BleCharacteristicValue -> IO ())
  -> IO ()
readBleCharacteristic bleState serviceUuid characteristicUuid callback =
  startBleGattOperation bleState
    (PendingBleRead callback)
    (callback . Left)
    (do ctx <- readIORef (blesContextPtr bleState)
        withCString (unpack (unBleServiceUuid serviceUuid)) $ \cService ->
          withCString (unpack (unBleCharacteristicUuid characteristicUuid)) $ \cCharacteristic ->
            c_bleReadCharacteristic ctx cService cCharacteristic)

-- | Write a characteristic's value.  'BleWriteWithoutResponse'
-- completes as soon as the platform queued the write;
-- 'BleWriteWithResponse' completes when the peripheral acknowledged
-- it.
writeBleCharacteristic
  :: BleState
  -> BleServiceUuid
  -> BleCharacteristicUuid
  -> BleWriteMode
  -> BleCharacteristicValue
  -> (Either BleGattError () -> IO ())
  -> IO ()
writeBleCharacteristic bleState serviceUuid characteristicUuid writeMode payload callback =
  startBleGattOperation bleState
    (PendingBleWrite callback)
    (callback . Left)
    (do ctx <- readIORef (blesContextPtr bleState)
        withCString (unpack (unBleServiceUuid serviceUuid)) $ \cService ->
          withCString (unpack (unBleCharacteristicUuid characteristicUuid)) $ \cCharacteristic ->
            BS.useAsCStringLen (unBleCharacteristicValue payload) $ \(cPayload, payloadLength) -> do
              cLength <- case Int.toCInt payloadLength of
                Just converted -> pure converted
                Nothing -> error $
                  "writeBleCharacteristic: payload of "
                  ++ show payloadLength ++ " bytes exceeds CInt"
              c_bleWriteCharacteristic ctx cService cCharacteristic
                cPayload
                cLength
                (case writeMode of
                   BleWriteWithResponse    -> 1
                   BleWriteWithoutResponse -> 0))

-- | Subscribe to a characteristic's notifications.  @onNotification@
-- is invoked for every notification until
-- 'unsubscribeBleCharacteristic'; @onSubscribed@ fires once with the
-- subscription outcome.
subscribeBleCharacteristic
  :: BleState
  -> BleServiceUuid
  -> BleCharacteristicUuid
  -> (BleCharacteristicValue -> IO ())  -- ^ onNotification
  -> (Either BleGattError () -> IO ())  -- ^ onSubscribed
  -> IO ()
subscribeBleCharacteristic bleState serviceUuid characteristicUuid onNotification onSubscribed = do
  let key = bleCharacteristicKey serviceUuid characteristicUuid
  -- Register the notification callback before asking the platform to
  -- enable notifications, so no early notification can be missed.  A
  -- failed subscription removes it again in 'dispatchBleGattCompletion'.
  modifyIORef' (blesNotificationCallbacks bleState) (Map.insert key onNotification)
  startBleGattOperation bleState
    (PendingBleSubscribe key onSubscribed)
    (\gattError -> do
        modifyIORef' (blesNotificationCallbacks bleState) (Map.delete key)
        onSubscribed (Left gattError))
    (do ctx <- readIORef (blesContextPtr bleState)
        withCString (unpack (unBleServiceUuid serviceUuid)) $ \cService ->
          withCString (unpack (unBleCharacteristicUuid characteristicUuid)) $ \cCharacteristic ->
            c_bleSetCharacteristicNotification ctx cService cCharacteristic 1)

-- | Stop receiving notifications for a characteristic.  The
-- notification callback is removed once the platform confirms.
unsubscribeBleCharacteristic
  :: BleState
  -> BleServiceUuid
  -> BleCharacteristicUuid
  -> (Either BleGattError () -> IO ())
  -> IO ()
unsubscribeBleCharacteristic bleState serviceUuid characteristicUuid callback =
  startBleGattOperation bleState
    (PendingBleUnsubscribe (bleCharacteristicKey serviceUuid characteristicUuid) callback)
    (callback . Left)
    (do ctx <- readIORef (blesContextPtr bleState)
        withCString (unpack (unBleServiceUuid serviceUuid)) $ \cService ->
          withCString (unpack (unBleCharacteristicUuid characteristicUuid)) $ \cCharacteristic ->
            c_bleSetCharacteristicNotification ctx cService cCharacteristic 0)

-- | Negotiate a larger ATT MTU.  Android asks the peripheral for the
-- given value; iOS ignores it and reports the system-negotiated
-- maximum.  The callback receives the granted MTU (see 'BleMtu' for
-- the usable write size).
requestBleMtu
  :: BleState
  -> BleMtu
  -> (Either BleGattError BleMtu -> IO ())
  -> IO ()
requestBleMtu bleState mtu callback =
  startBleGattOperation bleState
    (PendingBleMtu callback)
    (callback . Left)
    (do ctx <- readIORef (blesContextPtr bleState)
        cMtu <- case Int.toCInt (unBleMtu mtu) of
          Just converted -> pure converted
          Nothing -> error $ "requestBleMtu: MTU " ++ show mtu ++ " exceeds CInt"
        c_bleRequestMtu ctx cMtu)

-- | Dispatch a BLE scan result from the platform back to the
-- registered Haskell callback. Called from the FFI entry point.
-- If no scan is active (callback is 'Nothing'), the result is
-- silently dropped.
dispatchBleScanResult :: BleState -> CString -> CString -> CInt -> IO ()
dispatchBleScanResult bleState cName cAddr cRssi = do
  maybeCallback <- readIORef (blesScanCallback bleState)
  case maybeCallback of
    Nothing -> pure ()  -- No active scan, drop result
    Just callback -> do
      nameStr <- if cName == nullPtr
        then pure ""
        else pack <$> peekCString cName
      addrStr <- if cAddr == nullPtr
        then pure ""
        else pack <$> peekCString cAddr
      let scanResult = BleScanResult
            { bsrDeviceName    = nameStr
            , bsrDeviceAddress = BleDeviceAddress addrStr
            , bsrRssi          = CInt.toInt cRssi
            }
      callback scanResult

-- | Dispatch a BLE connection event from the platform back to the
-- registered Haskell callback.  The FFI entry point
-- ('Hatter.haskellOnBleConnectionEvent') decodes the C event code
-- before calling this, so the public API only sees the sum type.
-- Unlike scan results, connection events without a registered
-- callback indicate a platform bug (events can only follow a
-- 'connectBleDevice' call), so they are logged loudly instead of
-- silently dropped.
dispatchBleConnectionEvent :: BleState -> BleConnectionEvent -> IO ()
dispatchBleConnectionEvent bleState event = do
  maybeCallback <- readIORef (blesConnectionCallback bleState)
  case maybeCallback of
    Nothing -> hPutStrLn stderr $
      "dispatchBleConnectionEvent: received " ++ show event
      ++ " without an active connection callback"
    Just callback -> callback event

-- | Record one characteristic streamed by the platform during a
-- pending 'discoverBleServices' run.  Without a pending discovery the
-- report indicates a platform bug and is logged loudly.
dispatchBleCharacteristicDiscovered :: BleState -> BleDiscoveredCharacteristic -> IO ()
dispatchBleCharacteristicDiscovered bleState discovered = do
  pending <- readIORef (blesGattPending bleState)
  case pending of
    Just (PendingBleDiscover accumulator _) ->
      modifyIORef' accumulator (discovered :)
    Just _ -> hPutStrLn stderr $
      "dispatchBleCharacteristicDiscovered: received " ++ show discovered
      ++ " while a non-discovery operation is pending"
    Nothing -> hPutStrLn stderr $
      "dispatchBleCharacteristicDiscovered: received " ++ show discovered
      ++ " without a pending discovery"

-- | Fail whichever operation is pending with the given error.
failPendingBleGattOperation :: PendingBleGattOperation -> BleGattError -> IO ()
failPendingBleGattOperation pending gattError =
  case pending of
    PendingBleDiscover _ callback    -> callback (Left gattError)
    PendingBleRead callback          -> callback (Left gattError)
    PendingBleWrite callback         -> callback (Left gattError)
    PendingBleSubscribe _ callback   -> callback (Left gattError)
    PendingBleUnsubscribe _ callback -> callback (Left gattError)
    PendingBleMtu callback           -> callback (Left gattError)

-- | Complete the pending GATT operation with a platform result.
-- Called from the FFI entry point.  The pending operation is cleared
-- before its callback runs, so the callback may start the next
-- operation immediately.  A completion without a pending operation,
-- or for a different operation than the pending one, indicates a
-- platform bug: it is logged loudly and the pending operation (if
-- any) fails with code @-2@ so its caller is not left waiting.
dispatchBleGattCompletion :: BleState -> BleGattCompletion -> IO ()
dispatchBleGattCompletion bleState completion = do
  pending <- readIORef (blesGattPending bleState)
  writeIORef (blesGattPending bleState) Nothing
  case pending of
    Nothing -> hPutStrLn stderr $
      "dispatchBleGattCompletion: received " ++ show completion
      ++ " without a pending operation"
    Just pendingOperation ->
      if pendingBleGattOperationKind pendingOperation /= bgcOperation completion
        then do
          hPutStrLn stderr $
            "dispatchBleGattCompletion: received " ++ show (bgcOperation completion)
            ++ " while " ++ show (pendingBleGattOperationKind pendingOperation)
            ++ " was pending"
          failPendingBleGattOperation pendingOperation (BleGattFailed (-2))
        else completePendingBleGattOperation bleState pendingOperation completion

-- | Which 'BleGattOperation' a pending operation belongs to.
pendingBleGattOperationKind :: PendingBleGattOperation -> BleGattOperation
pendingBleGattOperationKind (PendingBleDiscover _ _)    = BleGattDiscover
pendingBleGattOperationKind (PendingBleRead _)          = BleGattRead
pendingBleGattOperationKind (PendingBleWrite _)         = BleGattWrite
pendingBleGattOperationKind (PendingBleSubscribe _ _)   = BleGattSubscribe
pendingBleGattOperationKind (PendingBleUnsubscribe _ _) = BleGattUnsubscribe
pendingBleGattOperationKind (PendingBleMtu _)           = BleGattRequestMtu

-- | Deliver a matching completion to the pending operation's callback.
completePendingBleGattOperation
  :: BleState -> PendingBleGattOperation -> BleGattCompletion -> IO ()
completePendingBleGattOperation bleState pendingOperation completion =
  case pendingOperation of
    PendingBleDiscover accumulator callback ->
      if bgcStatusCode completion == 0
        then do
          discovered <- readIORef accumulator
          callback (Right (reverse discovered))
        else callback (Left (BleGattFailed (bgcStatusCode completion)))
    PendingBleRead callback ->
      if bgcStatusCode completion == 0
        then callback (Right (bgcPayload completion))
        else callback (Left (BleGattFailed (bgcStatusCode completion)))
    PendingBleWrite callback ->
      if bgcStatusCode completion == 0
        then callback (Right ())
        else callback (Left (BleGattFailed (bgcStatusCode completion)))
    PendingBleSubscribe key callback ->
      if bgcStatusCode completion == 0
        then callback (Right ())
        else do
          -- The platform never enabled notifications; drop the
          -- callback registered optimistically by
          -- 'subscribeBleCharacteristic'.
          modifyIORef' (blesNotificationCallbacks bleState) (Map.delete key)
          callback (Left (BleGattFailed (bgcStatusCode completion)))
    PendingBleUnsubscribe key callback ->
      if bgcStatusCode completion == 0
        then do
          modifyIORef' (blesNotificationCallbacks bleState) (Map.delete key)
          callback (Right ())
        else callback (Left (BleGattFailed (bgcStatusCode completion)))
    PendingBleMtu callback ->
      if bgcStatusCode completion == 0
        then callback (Right (bgcGrantedMtu completion))
        else callback (Left (BleGattFailed (bgcStatusCode completion)))

-- | Dispatch notification data from the platform to the callback
-- registered by 'subscribeBleCharacteristic'.  Data for a
-- characteristic without a registered callback indicates a platform
-- bug (or a notification racing an unsubscribe) and is logged loudly.
dispatchBleNotification
  :: BleState -> BleServiceUuid -> BleCharacteristicUuid -> BleCharacteristicValue -> IO ()
dispatchBleNotification bleState serviceUuid characteristicUuid payload = do
  callbacks <- readIORef (blesNotificationCallbacks bleState)
  case Map.lookup (bleCharacteristicKey serviceUuid characteristicUuid) callbacks of
    Nothing -> hPutStrLn stderr $
      "dispatchBleNotification: notification for "
      ++ show (serviceUuid, characteristicUuid)
      ++ " without a registered callback"
    Just callback -> callback payload

-- | FFI import: check BLE adapter status via the C bridge.
foreign import ccall "ble_check_adapter"
  c_bleCheckAdapter :: IO CInt

-- | FFI import: start BLE scan via the C bridge.  The second argument
-- is a service UUID filter, or null for an unfiltered scan.
foreign import ccall "ble_start_scan"
  c_bleStartScan :: Ptr () -> CString -> IO ()

-- | FFI import: stop BLE scan via the C bridge.
foreign import ccall "ble_stop_scan"
  c_bleStopScan :: IO ()

-- | FFI import: connect to a BLE device via the C bridge.
foreign import ccall "ble_connect"
  c_bleConnect :: Ptr () -> CString -> IO ()

-- | FFI import: disconnect the active BLE connection via the C bridge.
foreign import ccall "ble_disconnect"
  c_bleDisconnect :: IO ()

-- | FFI import: discover services via the C bridge.
foreign import ccall "ble_discover_services"
  c_bleDiscoverServices :: Ptr () -> IO ()

-- | FFI import: read a characteristic via the C bridge.
foreign import ccall "ble_read_characteristic"
  c_bleReadCharacteristic :: Ptr () -> CString -> CString -> IO ()

-- | FFI import: write a characteristic via the C bridge.  The payload
-- travels as a CString + explicit length pair (same convention as the
-- HTTP bridge's request body).
foreign import ccall "ble_write_characteristic"
  c_bleWriteCharacteristic :: Ptr () -> CString -> CString -> CString -> CInt -> CInt -> IO ()

-- | FFI import: enable/disable characteristic notifications via the C bridge.
foreign import ccall "ble_set_characteristic_notification"
  c_bleSetCharacteristicNotification :: Ptr () -> CString -> CString -> CInt -> IO ()

-- | FFI import: request an ATT MTU via the C bridge.
foreign import ccall "ble_request_mtu"
  c_bleRequestMtu :: Ptr () -> CInt -> IO ()
