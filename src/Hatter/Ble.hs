{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
-- | BLE (Bluetooth Low Energy) API for mobile platforms.
--
-- Provides adapter status check, start\/stop scan, and GATT
-- connection management.  Scan results and connection events are
-- delivered via streaming callbacks (multiple invocations per
-- registration), unlike the permission bridge which uses one
-- callback per request.
--
-- On desktop (no platform bridge registered) the C stub reports
-- the adapter as on, start\/stop scan are no-ops, and connection
-- attempts immediately deliver 'BleConnectionFailed', so @cabal test@
-- works without native code.
module Hatter.Ble
  ( BleAdapterStatus(..)
  , BleScanResult(..)
  , BleDeviceAddress(..)
  , BleConnectionEvent(..)
  , BleState(..)
  , newBleState
  , bleAdapterStatusFromInt
  , bleAdapterStatusToInt
  , bleConnectionEventFromInt
  , bleConnectionEventToInt
  , checkBleAdapter
  , startBleScan
  , stopBleScan
  , connectBleDevice
  , disconnectBleDevice
  , dispatchBleScanResult
  , dispatchBleConnectionEvent
  )
where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text, pack, unpack)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt

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

-- | Mutable state for the BLE subsystem.
-- Uses 'IORef (Maybe callback)' instead of 'IntMap' because only
-- one scan and one connection can be active at a time.
data BleState = BleState
  { blesScanCallback :: IORef (Maybe (BleScanResult -> IO ()))
    -- ^ Active scan result callback, or 'Nothing' if not scanning.
  , blesConnectionCallback :: IORef (Maybe (BleConnectionEvent -> IO ()))
    -- ^ Active connection event callback, registered by
    -- 'connectBleDevice'.  Stays registered after a disconnect so
    -- that late events (e.g. the 'BleConnectionClosed' following a
    -- 'disconnectBleDevice') still reach the app; a new
    -- 'connectBleDevice' call overwrites it.
  , blesContextPtr   :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'BleState' with no active scan or connection.
-- The context pointer is initially null and must be set via
-- 'blesContextPtr' before calling 'startBleScan' or 'connectBleDevice'.
newBleState :: IO BleState
newBleState = do
  scanCallback       <- newIORef Nothing
  connectionCallback <- newIORef Nothing
  contextPtr         <- newIORef nullPtr
  pure BleState
    { blesScanCallback       = scanCallback
    , blesConnectionCallback = connectionCallback
    , blesContextPtr         = contextPtr
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

-- | Check the BLE adapter status (synchronous).
checkBleAdapter :: IO BleAdapterStatus
checkBleAdapter = do
  result <- c_bleCheckAdapter
  case bleAdapterStatusFromInt result of
    Just status -> pure status
    Nothing     -> do
      hPutStrLn stderr $ "checkBleAdapter: unknown status code " ++ show result
      pure BleAdapterUnsupported

-- | Start a BLE scan. Stops any existing scan first, then registers
-- the callback and calls the C bridge. The callback will be invoked
-- for each discovered device until 'stopBleScan' is called.
startBleScan :: BleState -> (BleScanResult -> IO ()) -> IO ()
startBleScan bleState callback = do
  -- Stop any existing scan first
  c_bleStopScan
  -- Register the new callback
  writeIORef (blesScanCallback bleState) (Just callback)
  -- Start scanning via C bridge
  ctx <- readIORef (blesContextPtr bleState)
  c_bleStartScan ctx

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

-- | FFI import: check BLE adapter status via the C bridge.
foreign import ccall "ble_check_adapter"
  c_bleCheckAdapter :: IO CInt

-- | FFI import: start BLE scan via the C bridge.
foreign import ccall "ble_start_scan"
  c_bleStartScan :: Ptr () -> IO ()

-- | FFI import: stop BLE scan via the C bridge.
foreign import ccall "ble_stop_scan"
  c_bleStopScan :: IO ()

-- | FFI import: connect to a BLE device via the C bridge.
foreign import ccall "ble_connect"
  c_bleConnect :: Ptr () -> CString -> IO ()

-- | FFI import: disconnect the active BLE connection via the C bridge.
foreign import ccall "ble_disconnect"
  c_bleDisconnect :: IO ()
