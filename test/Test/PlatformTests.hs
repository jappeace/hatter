-- | Platform service tests: Permission, SecureStorage, BLE, Dialog,
-- AuthSession, PlatformSignIn, Location, BottomSheet, Camera, HTTP,
-- NetworkStatus.
module Test.PlatformTests
  ( permissionTests
  , secureStorageTests
  , bleTests
  , dialogTests
  , authSessionTests
  , platformSignInTests
  , locationTests
  , bottomSheetTests
  , cameraTests
  , httpTests
  , networkStatusTests
  ) where

import Test.Tasty
import Test.Tasty.HUnit

import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.IntMap.Strict qualified as IntMap
import Data.UUID.Types qualified as UUID
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text qualified as Text
import Foreign.C.String (newCString)
import Foreign.Marshal.Alloc (free)
import Foreign.Ptr (castPtr, nullPtr)
import Hatter.AppContext (AppContext(..), freeAppContext, derefAppContext)
import Hatter.AppContext (newAppContext)
import Hatter.Widget (TextConfig(..), Widget(..))
import Hatter.Permission
  ( PermissionStatus(..)
  , PermissionState(..)
  , newPermissionState
  , requestPermission
  , checkPermission
  , dispatchPermissionResult
  , permissionToInt
  , permissionStatusFromInt
  , Permission(..)
  )
import Hatter.SecureStorage
  ( SecureStorageStatus(..)
  , SecureStorageState(..)
  , newSecureStorageState
  , secureStorageWrite
  , secureStorageRead
  , secureStorageDelete
  , dispatchSecureStorageResult
  , storageStatusFromInt
  )
import Hatter.Ble
  ( BleAdapterStatus(..)
  , BleScanResult(..)
  , BleDeviceAddress(..)
  , BleServiceUuid(..)
  , BleCharacteristicUuid(..)
  , BleCharacteristicValue(..)
  , BleMtu(..)
  , BleConnectionEvent(..)
  , BleCharacteristicProperty(..)
  , BleDiscoveredCharacteristic(..)
  , BleWriteMode(..)
  , BleGattOperation(..)
  , BleGattError(..)
  , BleGattCompletion(..)
  , BleState(..)
  , BleAdvertisement(..)
  , ManufacturerId(..)
  , AdvertisementParseError(..)
  , AdvertisementParseErrors(..)
  , BleAdvertisementWithErrors(..)
  , AdStructureOffset(..)
  , AdStructureTruncation(..)
  , ServiceDataTruncation(..)
  , ManufacturerDataTruncation(..)
  , emptyBleAdvertisement
  , parseBleAdvertisement
  , serviceDataForUuid
  , newBleState
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
import Hatter.Dialog
  ( DialogAction(..)
  , DialogConfig(..)
  , DialogState(..)
  , newDialogState
  , showDialog
  , dispatchDialogResult
  , dialogActionFromInt
  )
import Hatter.AuthSession
  ( AuthSessionResult(..)
  , AuthSessionState(..)
  , newAuthSessionState
  , startAuthSession
  , dispatchAuthSessionResult
  , authSessionResultFromInt
  )
import Hatter.PlatformSignIn
  ( SignInProvider(..)
  , SignInCredential(..)
  , SignInResult(..)
  , PlatformSignInState(..)
  , newPlatformSignInState
  , startPlatformSignIn
  , dispatchPlatformSignInResult
  , signInResultFromInt
  , providerToInt
  , providerFromInt
  )
import Hatter.Location
  ( LocationData(..)
  , LocationState(..)
  , newLocationState
  , startLocationUpdates
  , stopLocationUpdates
  , dispatchLocationUpdate
  )
import Hatter.BottomSheet
  ( BottomSheetAction(..)
  , BottomSheetConfig(..)
  , BottomSheetState(..)
  , newBottomSheetState
  , showBottomSheet
  , dispatchBottomSheetResult
  , bottomSheetActionFromInt
  )
import Hatter.Camera
  ( CameraStatus(..)
  , Picture(..)
  , CameraResult(..)
  , CameraState(..)
  , newCameraState
  , cameraSourceToInt
  , cameraStatusFromInt
  , capturePhoto
  , startVideoCapture
  , stopCameraSession
  , dispatchCameraResult
  , dispatchVideoFrame
  , dispatchAudioChunk
  , CameraSource(..)
  )
import Hatter.Http
  ( HttpMethod(..)
  , HttpRequest(..)
  , HttpResponse(..)
  , HttpError(..)
  , HttpState(..)
  , newHttpState
  , httpMethodToInt
  , performRequest
  , serializeHeaders
  , parseHeaders
  , dispatchHttpResult
  )
import Hatter.NetworkStatus
  ( NetworkTransport(..)
  , NetworkStatus(..)
  , NetworkStatusState(..)
  , newNetworkStatusState
  , startNetworkMonitoring
  , stopNetworkMonitoring
  , dispatchNetworkStatusChange
  , networkTransportFromInt
  , networkTransportToInt
  )
import Test.Helpers (makeSimpleApp)

-- | Permission tests.  The @ffiPermState@ parameter is the 'PermissionState'
-- from a context created once in 'main' via 'startMobileApp'.  This
-- ensures the C desktop stub's @g_permission_ctx@ points to a valid context
-- for the FFI round-trip tests, without racing with other tests.
-- | Uses 'sequentialTestGroup' because these tests share a
-- 'PermissionState' with a mutable request ID counter.
permissionTests :: PermissionState -> TestTree
permissionTests ffiPermState = sequentialTestGroup "Permission" AllFinish
  [ testCase "requestPermission fires callback with PermissionGranted on desktop" $ do
      ref <- newIORef (Nothing :: Maybe PermissionStatus)
      requestPermission ffiPermState PermissionCamera
        (\status -> modifyIORef' ref (const (Just status)))
      result <- readIORef ref
      result @?= Just PermissionGranted

  , testCase "checkPermission returns PermissionGranted on desktop" $ do
      status <- checkPermission PermissionLocation
      status @?= PermissionGranted

  , testCase "dispatchPermissionResult with PermissionDenied fires callback correctly" $ do
      ref <- newIORef (Nothing :: Maybe PermissionStatus)
      permState <- newPermissionState
      modifyIORef' (psCallbacks permState) (\_ ->
        IntMap.singleton 0 (\status -> modifyIORef' ref (const (Just status))))
      dispatchPermissionResult permState 0 1
      result <- readIORef ref
      result @?= Just PermissionDenied

  , testCase "callback is removed after dispatch (second dispatch is a no-op)" $ do
      ref <- newIORef (0 :: Int)
      permState <- newPermissionState
      modifyIORef' (psCallbacks permState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchPermissionResult permState 0 0
      count1 <- readIORef ref
      count1 @?= 1
      -- Second dispatch for same ID should be a no-op (callback removed)
      dispatchPermissionResult permState 0 0
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "unknown request ID does not crash" $ do
      permState <- newPermissionState
      -- Should not throw (logs to stderr)
      dispatchPermissionResult permState 999 0

  , testCase "unknown status code does not fire callback" $ do
      ref <- newIORef (0 :: Int)
      permState <- newPermissionState
      modifyIORef' (psCallbacks permState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchPermissionResult permState 0 42
      count <- readIORef ref
      count @?= 0

  , testCase "multiple simultaneous pending requests dispatch independently" $ do
      refA <- newIORef (Nothing :: Maybe PermissionStatus)
      refB <- newIORef (Nothing :: Maybe PermissionStatus)
      requestPermission ffiPermState PermissionCamera
        (\status -> modifyIORef' refA (const (Just status)))
      requestPermission ffiPermState PermissionContacts
        (\status -> modifyIORef' refB (const (Just status)))
      resultA <- readIORef refA
      resultB <- readIORef refB
      resultA @?= Just PermissionGranted
      resultB @?= Just PermissionGranted

  , testCase "permissionToInt covers all constructors" $ do
      permissionToInt PermissionLocation   @?= 0
      permissionToInt PermissionBluetooth  @?= 1
      permissionToInt PermissionCamera     @?= 2
      permissionToInt PermissionMicrophone @?= 3
      permissionToInt PermissionContacts   @?= 4
      permissionToInt PermissionStorage    @?= 5

  , testCase "permissionStatusFromInt roundtrips valid codes" $ do
      permissionStatusFromInt 0 @?= Just PermissionGranted
      permissionStatusFromInt 1 @?= Just PermissionDenied

  , testCase "permissionStatusFromInt returns Nothing for unknown codes" $ do
      permissionStatusFromInt 2 @?= Nothing
      permissionStatusFromInt (-1) @?= Nothing
      permissionStatusFromInt 100 @?= Nothing
  ]

-- | Secure storage tests.  The @ffiSecureStorageState@ parameter is the
-- 'SecureStorageState' from a context created once in 'main' via
-- 'haskellCreateContext', ensuring the C desktop stub dispatches through
-- a valid context pointer.
-- Uses 'sequentialTestGroup' because these tests share mutable state
-- (the C global key-value store and the Haskell callback registry).
secureStorageTests :: SecureStorageState -> TestTree
secureStorageTests ffiSecureStorageState = sequentialTestGroup "SecureStorage" AllFinish
  [ testCase "write then read returns written value" $ do
      statusRef <- newIORef (Nothing :: Maybe SecureStorageStatus)
      valueRef  <- newIORef (Nothing :: Maybe Text.Text)
      secureStorageWrite ffiSecureStorageState "test_key" "test_value"
        (\status -> modifyIORef' statusRef (const (Just status)))
      writeStatus <- readIORef statusRef
      writeStatus @?= Just StorageSuccess
      secureStorageRead ffiSecureStorageState "test_key"
        (\status maybeVal -> do
          modifyIORef' statusRef (const (Just status))
          modifyIORef' valueRef  (const maybeVal))
      readStatus <- readIORef statusRef
      readValue  <- readIORef valueRef
      readStatus @?= Just StorageSuccess
      readValue  @?= Just "test_value"

  , testCase "read nonexistent key returns StorageNotFound" $ do
      statusRef <- newIORef (Nothing :: Maybe SecureStorageStatus)
      valueRef  <- newIORef (Nothing :: Maybe Text.Text)
      secureStorageRead ffiSecureStorageState "nonexistent_key_12345"
        (\status maybeVal -> do
          modifyIORef' statusRef (const (Just status))
          modifyIORef' valueRef  (const maybeVal))
      readStatus <- readIORef statusRef
      readValue  <- readIORef valueRef
      readStatus @?= Just StorageNotFound
      readValue  @?= Nothing

  , testCase "delete then read returns StorageNotFound" $ do
      statusRef <- newIORef (Nothing :: Maybe SecureStorageStatus)
      valueRef  <- newIORef (Nothing :: Maybe Text.Text)
      secureStorageWrite ffiSecureStorageState "delete_me" "some_value"
        (\_ -> pure ())
      secureStorageDelete ffiSecureStorageState "delete_me"
        (\status -> modifyIORef' statusRef (const (Just status)))
      deleteStatus <- readIORef statusRef
      deleteStatus @?= Just StorageSuccess
      secureStorageRead ffiSecureStorageState "delete_me"
        (\status maybeVal -> do
          modifyIORef' statusRef (const (Just status))
          modifyIORef' valueRef  (const maybeVal))
      readStatus <- readIORef statusRef
      readValue  <- readIORef valueRef
      readStatus @?= Just StorageNotFound
      readValue  @?= Nothing

  , testCase "write overwrites existing value" $ do
      valueRef <- newIORef (Nothing :: Maybe Text.Text)
      secureStorageWrite ffiSecureStorageState "overwrite_key" "first"
        (\_ -> pure ())
      secureStorageWrite ffiSecureStorageState "overwrite_key" "second"
        (\_ -> pure ())
      secureStorageRead ffiSecureStorageState "overwrite_key"
        (\_ maybeVal -> modifyIORef' valueRef (const maybeVal))
      readValue <- readIORef valueRef
      readValue @?= Just "second"

  , testCase "write callback removed after dispatch" $ do
      ref <- newIORef (0 :: Int)
      storageState <- newSecureStorageState
      modifyIORef' (ssWriteCallbacks storageState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchSecureStorageResult storageState 0 0 Nothing
      count1 <- readIORef ref
      count1 @?= 1
      -- Second dispatch for same ID should be a no-op
      dispatchSecureStorageResult storageState 0 0 Nothing
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "storageStatusFromInt roundtrips valid codes" $ do
      storageStatusFromInt 0 @?= Just StorageSuccess
      storageStatusFromInt 1 @?= Just StorageNotFound
      storageStatusFromInt 2 @?= Just StorageError

  , testCase "storageStatusFromInt rejects unknown codes" $ do
      storageStatusFromInt 3 @?= Nothing
      storageStatusFromInt (-1) @?= Nothing
      storageStatusFromInt 100 @?= Nothing

  , testCase "unknown request ID does not crash" $ do
      storageState <- newSecureStorageState
      -- Should not throw (logs to stderr)
      dispatchSecureStorageResult storageState 999 0 Nothing

  , testCase "unknown status code does not fire callback" $ do
      ref <- newIORef (0 :: Int)
      storageState <- newSecureStorageState
      modifyIORef' (ssWriteCallbacks storageState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchSecureStorageResult storageState 0 42 Nothing
      count <- readIORef ref
      count @?= 0
  ]

-- | BLE scanning and connection tests.  The 'BleState' argument is
-- wired to a real FFI app context, so the connect test exercises the
-- actual desktop C stub round trip (Haskell -> ble_connect ->
-- haskellOnBleConnectionEvent -> callback).
-- | KKM's 0x2080 ext-data service UUID, built with the total
-- fromWords.
kkmExtDataUuid :: UUID.UUID
kkmExtDataUuid = UUID.fromWords 0x00002080 0x00001000 0x80000080 0x5F9B34FB

bleTests :: BleState -> TestTree
bleTests ffiBleState = testGroup "BLE"
  [ testCase "bleAdapterStatusFromInt roundtrips all constructors" $ do
      let allStatuses = [BleAdapterOff, BleAdapterOn, BleAdapterUnauthorized, BleAdapterUnsupported]
      mapM_ (\status ->
        bleAdapterStatusFromInt (bleAdapterStatusToInt status) @?= Just status
        ) allStatuses

  , testCase "bleAdapterStatusFromInt returns Nothing for unknown codes" $ do
      bleAdapterStatusFromInt 4 @?= Nothing
      bleAdapterStatusFromInt (-1) @?= Nothing
      bleAdapterStatusFromInt 100 @?= Nothing

  , testCase "bleAdapterStatusToInt produces expected codes" $ do
      bleAdapterStatusToInt BleAdapterOff          @?= 0
      bleAdapterStatusToInt BleAdapterOn           @?= 1
      bleAdapterStatusToInt BleAdapterUnauthorized @?= 2
      bleAdapterStatusToInt BleAdapterUnsupported  @?= 3

  , testCase "checkBleAdapter returns BleAdapterOn on desktop" $ do
      status <- checkBleAdapter
      status @?= BleAdapterOn

  , testCase "startBleScan registers callback" $ do
      bleState <- newBleState
      startBleScan bleState (\_ -> pure ())
      maybeCb <- readIORef (blesScanCallback bleState)
      case maybeCb of
        Nothing -> assertFailure "callback should be Just after startBleScan"
        Just _  -> pure ()

  , testCase "stopBleScan clears callback" $ do
      bleState <- newBleState
      startBleScan bleState (\_ -> pure ())
      stopBleScan bleState
      maybeCb <- readIORef (blesScanCallback bleState)
      case maybeCb of
        Nothing -> pure ()
        Just _  -> assertFailure "callback should be Nothing after stopBleScan"

  , testCase "dispatchBleScanResult fires registered callback" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe BleScanResult)
      startBleScan bleState (\result -> writeIORef ref (Just result))
      cName <- newCString "TestDevice"
      cAddr <- newCString "AA:BB:CC:DD:EE:FF"
      dispatchBleScanResult bleState cName cAddr (-42) nullPtr 0
      free cName
      free cAddr
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just scanResult -> do
          bsrDeviceName scanResult @?= "TestDevice"
          bsrDeviceAddress scanResult @?= BleDeviceAddress "AA:BB:CC:DD:EE:FF"
          bsrRssi scanResult @?= (-42)
          bsrAdvertisement scanResult @?= Right emptyBleAdvertisement

  , testCase "dispatchBleScanResult with no active scan is no-op" $ do
      bleState <- newBleState
      cName <- newCString "Ignored"
      cAddr <- newCString "00:00:00:00:00:00"
      -- Should not throw or crash
      dispatchBleScanResult bleState cName cAddr 0 nullPtr 0
      free cName
      free cAddr

  , testCase "multiple scan results accumulate" $ do
      bleState <- newBleState
      ref <- newIORef ([] :: [BleScanResult])
      startBleScan bleState (\result -> modifyIORef' ref (++ [result]))
      cName1 <- newCString "Device1"
      cAddr1 <- newCString "11:22:33:44:55:66"
      dispatchBleScanResult bleState cName1 cAddr1 (-50) nullPtr 0
      free cName1
      free cAddr1
      cName2 <- newCString "Device2"
      cAddr2 <- newCString "AA:BB:CC:DD:EE:FF"
      dispatchBleScanResult bleState cName2 cAddr2 (-70) nullPtr 0
      free cName2
      free cAddr2
      results <- readIORef ref
      length results @?= 2
      case results of
        [first, second] -> do
          bsrDeviceName first @?= "Device1"
          bsrDeviceName second @?= "Device2"
        _ -> assertFailure "expected exactly 2 results"

  , testCase "startBleScan replaces existing callback" $ do
      bleState <- newBleState
      refOld <- newIORef (0 :: Int)
      refNew <- newIORef (0 :: Int)
      startBleScan bleState (\_ -> modifyIORef' refOld (+ 1))
      -- Replace with new callback
      startBleScan bleState (\_ -> modifyIORef' refNew (+ 1))
      cName <- newCString "Test"
      cAddr <- newCString "00:11:22:33:44:55"
      dispatchBleScanResult bleState cName cAddr (-60) nullPtr 0
      free cName
      free cAddr
      oldCount <- readIORef refOld
      newCount <- readIORef refNew
      oldCount @?= 0
      newCount @?= 1

  , testCase "null device name handled as empty Text" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe BleScanResult)
      startBleScan bleState (\result -> writeIORef ref (Just result))
      cAddr <- newCString "FF:EE:DD:CC:BB:AA"
      dispatchBleScanResult bleState nullPtr cAddr (-80) nullPtr 0
      free cAddr
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just scanResult -> do
          bsrDeviceName scanResult @?= ""
          bsrDeviceAddress scanResult @?= BleDeviceAddress "FF:EE:DD:CC:BB:AA"

  , testCase "dispatchBleScanResult parses the advertisement bytes" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe BleScanResult)
      startBleScan bleState (\result -> writeIORef ref (Just result))
      cName <- newCString "KBPro-F4F5F6"
      cAddr <- newCString "BC:57:29:F4:F5:F6"
      -- flags, then 0x2080 service data carrying 55 00 01 F6.
      let advBytes = BS.pack
            [ 0x02, 0x01, 0x06
            , 0x07, 0x16, 0x80, 0x20, 0x55, 0x00, 0x01, 0xF6
            ]
      BS.length advBytes @?= 11
      BS.useAsCStringLen advBytes (\(advPtr, _len) ->
        dispatchBleScanResult bleState cName cAddr (-42) (castPtr advPtr) 11)
      free cName
      free cAddr
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just scanResult ->
          fmap (serviceDataForUuid kkmExtDataUuid)
              (bsrAdvertisement scanResult)
            @?= Right (Just (BS.pack [0x55, 0x00, 0x01, 0xF6]))

  , testCase "parseBleAdvertisement reads 16-bit service data" $
      parseBleAdvertisement
          (BS.pack [0x02, 0x01, 0x06, 0x05, 0x16, 0xED, 0xFE, 0x2A, 0x63])
        @?= Right BleAdvertisement
          { advServiceData =
              [(UUID.fromWords 0x0000FEED 0x00001000 0x80000080 0x5F9B34FB, BS.pack [0x2A, 0x63])]
          , advManufacturerData = []
          }

  , testCase "parseBleAdvertisement reads 128-bit service data" $
      -- UUID travels little-endian on air; this is
      -- 50DB505C-8AC4-4738-8448-3B1D9CC09CC5 reversed, then one byte.
      parseBleAdvertisement
          (BS.pack
            [ 0x12, 0x21
            , 0xC5, 0x9C, 0xC0, 0x9C, 0x1D, 0x3B, 0x48, 0x84
            , 0x38, 0x47, 0xC4, 0x8A, 0x5C, 0x50, 0xDB, 0x50
            , 0x7F
            ])
        @?= Right BleAdvertisement
          { advServiceData =
              [(UUID.fromWords 0x50DB505C 0x8AC44738 0x84483B1D 0x9CC09CC5, BS.pack [0x7F])]
          , advManufacturerData = []
          }

  , testCase "parseBleAdvertisement reads manufacturer data" $
      -- KKM's company id 0x0A53, little-endian on air.
      parseBleAdvertisement (BS.pack [0x04, 0xFF, 0x53, 0x0A, 0x21])
        @?= Right BleAdvertisement
          { advServiceData = []
          , advManufacturerData = [(ManufacturerId 0x0A53, BS.pack [0x21])]
          }

  , testCase "parseBleAdvertisement keeps entry order across types" $
      parseBleAdvertisement
          (BS.pack
            [ 0x04, 0x16, 0xAA, 0xFE, 0x01
            , 0x03, 0xFF, 0x4C, 0x00
            , 0x04, 0x16, 0x80, 0x20, 0x02
            ])
        @?= Right BleAdvertisement
          { advServiceData =
              [ (UUID.fromWords 0x0000FEAA 0x00001000 0x80000080 0x5F9B34FB, BS.pack [0x01])
              , (UUID.fromWords 0x00002080 0x00001000 0x80000080 0x5F9B34FB, BS.pack [0x02])
              ]
          , advManufacturerData = [(ManufacturerId 0x004C, BS.empty)]
          }

  , testCase "parseBleAdvertisement stops at the zero padding" $
      -- ScanRecord.getBytes() zero-pads to the advertisement buffer
      -- size; the padding must not become phantom entries.
      parseBleAdvertisement
          (BS.pack [0x05, 0x16, 0xED, 0xFE, 0x2A, 0x63, 0x00, 0x00, 0x00, 0x00])
        @?= Right BleAdvertisement
          { advServiceData =
              [(UUID.fromWords 0x0000FEED 0x00001000 0x80000080 0x5F9B34FB, BS.pack [0x2A, 0x63])]
          , advManufacturerData = []
          }

  , testCase "a truncated structure reports its offset and keeps the salvage" $
      -- The second structure (length byte at offset 5) claims 9
      -- bytes but only 3 follow; the well-formed manufacturer data
      -- before it survives in the partial advertisement.
      parseBleAdvertisement
          (BS.pack [0x04, 0xFF, 0x53, 0x0A, 0x21, 0x09, 0x16, 0xED, 0xFE])
        @?= Left BleAdvertisementWithErrors
          { partialAdvertisement = BleAdvertisement
              { advServiceData = []
              , advManufacturerData = [(ManufacturerId 0x0A53, BS.pack [0x21])]
              }
          , advertisementParseErrors = AdvertisementParseErrors
              (AdStructureTruncated (AdStructureTruncation (AdStructureOffset 5) 9 3) :| [])
          }

  , testCase "a mid-stream defect keeps the structures around it" $
      -- Defective service data first, valid manufacturer data after:
      -- the defect skips only its own structure.
      parseBleAdvertisement
          (BS.pack [0x02, 0x16, 0xED, 0x04, 0xFF, 0x53, 0x0A, 0x21])
        @?= Left BleAdvertisementWithErrors
          { partialAdvertisement = BleAdvertisement
              { advServiceData = []
              , advManufacturerData = [(ManufacturerId 0x0A53, BS.pack [0x21])]
              }
          , advertisementParseErrors = AdvertisementParseErrors
              (ServiceDataUuidTruncated
                 (ServiceDataTruncation (AdStructureOffset 0) 0x16 2 1) :| [])
          }

  , testCase "a truncated 128-bit service data UUID never passes as narrower" $ do
      -- A 0x21 structure promises a 16-byte UUID; truncated to two
      -- bytes it must NOT parse as the 16-bit UUID those bytes spell
      -- (regression: [0x80, 0x20] would otherwise read as 0x2080).
      parseBleAdvertisement (BS.pack [0x03, 0x21, 0x80, 0x20])
        @?= Left (BleAdvertisementWithErrors emptyBleAdvertisement
              (AdvertisementParseErrors
                (ServiceDataUuidTruncated
                   (ServiceDataTruncation (AdStructureOffset 0) 0x21 16 2) :| [])))
      parseBleAdvertisement (BS.pack [0x05, 0x21, 0x01, 0x02, 0x03, 0x04])
        @?= Left (BleAdvertisementWithErrors emptyBleAdvertisement
              (AdvertisementParseErrors
                (ServiceDataUuidTruncated
                   (ServiceDataTruncation (AdStructureOffset 0) 0x21 16 4) :| [])))
      parseBleAdvertisement (BS.pack [0x03, 0x20, 0x80, 0x20])
        @?= Left (BleAdvertisementWithErrors emptyBleAdvertisement
              (AdvertisementParseErrors
                (ServiceDataUuidTruncated
                   (ServiceDataTruncation (AdStructureOffset 0) 0x20 4 2) :| [])))

  , testCase "parseBleAdvertisement accumulates every defect" $
      -- Service data too short for its 16-bit UUID at offset 0, then
      -- manufacturer data too short for its company id at offset 3:
      -- all structures defective, so the salvage is empty.
      parseBleAdvertisement
          (BS.pack [0x02, 0x16, 0xED, 0x02, 0xFF, 0x53])
        @?= Left (BleAdvertisementWithErrors emptyBleAdvertisement
              (AdvertisementParseErrors
                (ServiceDataUuidTruncated
                    (ServiceDataTruncation (AdStructureOffset 0) 0x16 2 1)
                  :| [ManufacturerDataTooShort
                       (ManufacturerDataTruncation (AdStructureOffset 3) 1)])))

  , testCase "serviceDataForUuid keys on the UUID value" $ do
      let parsed = parseBleAdvertisement
            (BS.pack [0x05, 0x16, 0x80, 0x20, 0x55, 0x63])
      fmap (serviceDataForUuid kkmExtDataUuid) parsed
        @?= Right (Just (BS.pack [0x55, 0x63]))
      fmap (serviceDataForUuid
             (UUID.fromWords 0x0000FEAA 0x00001000 0x80000080 0x5F9B34FB)) parsed
        @?= Right Nothing
      -- Both platform spellings parse to the same binary key, so the
      -- old case-mismatch bug is unrepresentable.
      UUID.fromText "00002080-0000-1000-8000-00805F9B34FB"
        @?= UUID.fromText "00002080-0000-1000-8000-00805f9b34fb"

  , testCase "bleConnectionEventFromInt roundtrips all constructors" $ do
      let allEvents = [BleConnectionEstablished, BleConnectionClosed, BleConnectionFailed]
      mapM_ (\event ->
        bleConnectionEventFromInt (bleConnectionEventToInt event) @?= Just event
        ) allEvents

  , testCase "bleConnectionEventFromInt returns Nothing for unknown codes" $ do
      bleConnectionEventFromInt 3 @?= Nothing
      bleConnectionEventFromInt (-1) @?= Nothing
      bleConnectionEventFromInt 100 @?= Nothing

  , testCase "desktop stub fails connections through the C bridge" $ do
      -- No platform connect implementation is registered on desktop,
      -- so ble_connect must dispatch BleConnectionFailed back through
      -- haskellOnBleConnectionEvent, so the caller is never left hanging.
      ref <- newIORef (Nothing :: Maybe BleConnectionEvent)
      connectBleDevice ffiBleState (BleDeviceAddress "AA:BB:CC:DD:EE:FF")
        (\event -> writeIORef ref (Just event))
      result <- readIORef ref
      result @?= Just BleConnectionFailed

  , testCase "dispatchBleConnectionEvent fires registered callback" $ do
      bleState <- newBleState
      ref <- newIORef ([] :: [BleConnectionEvent])
      connectBleDevice bleState (BleDeviceAddress "11:22:33:44:55:66")
        (\event -> modifyIORef' ref (++ [event]))
      dispatchBleConnectionEvent bleState BleConnectionEstablished
      dispatchBleConnectionEvent bleState BleConnectionClosed
      events <- readIORef ref
      events @?= [BleConnectionEstablished, BleConnectionClosed]

  , testCase "dispatchBleConnectionEvent without callback is safe" $ do
      bleState <- newBleState
      -- Logs loudly to stderr but must not crash
      dispatchBleConnectionEvent bleState BleConnectionClosed

  , testCase "disconnectBleDevice keeps the connection callback" $ do
      -- The BleConnectionClosed event arrives after the disconnect
      -- call, so the callback must survive disconnectBleDevice.
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe BleConnectionEvent)
      connectBleDevice bleState (BleDeviceAddress "11:22:33:44:55:66")
        (\event -> writeIORef ref (Just event))
      disconnectBleDevice bleState
      dispatchBleConnectionEvent bleState BleConnectionClosed
      result <- readIORef ref
      result @?= Just BleConnectionClosed

  , testCase "bleGattOperationFromInt roundtrips all constructors" $ do
      let allOperations =
            [ BleGattDiscover, BleGattRead, BleGattWrite
            , BleGattSubscribe, BleGattUnsubscribe, BleGattRequestMtu ]
      mapM_ (\operation ->
        bleGattOperationFromInt (bleGattOperationToInt operation) @?= Just operation
        ) allOperations
      bleGattOperationFromInt 6 @?= Nothing
      bleGattOperationFromInt (-1) @?= Nothing

  , testCase "characteristic property bits roundtrip every mask" $ do
      mapM_ (\bits ->
        bleCharacteristicPropertiesToBits (bleCharacteristicPropertiesFromBits bits)
          @?= bits
        ) [0 .. 15]
      bleCharacteristicPropertiesFromBits 9
        @?= [BleCharacteristicRead, BleCharacteristicNotify]

  , testCase "desktop stub fails every GATT operation through the C bridge" $ do
      -- No platform GATT implementation is registered on desktop, so
      -- every operation must come back as BleGattFailed (-1) through
      -- haskellOnBleGattResult; callers are never left waiting.
      discoverRef <- newIORef (Nothing :: Maybe (Either BleGattError [BleDiscoveredCharacteristic]))
      discoverBleServices ffiBleState (\result -> writeIORef discoverRef (Just result))
      discoverResult <- readIORef discoverRef
      discoverResult @?= Just (Left (BleGattFailed (-1)))

      readRef <- newIORef (Nothing :: Maybe (Either BleGattError BleCharacteristicValue))
      readBleCharacteristic ffiBleState testServiceUuid testCharacteristicUuid
        (\result -> writeIORef readRef (Just result))
      readResult <- readIORef readRef
      readResult @?= Just (Left (BleGattFailed (-1)))

      writeRef <- newIORef (Nothing :: Maybe (Either BleGattError ()))
      writeBleCharacteristic ffiBleState testServiceUuid testCharacteristicUuid
        BleWriteWithResponse "payload" (\result -> writeIORef writeRef (Just result))
      writeResult <- readIORef writeRef
      writeResult @?= Just (Left (BleGattFailed (-1)))

      subscribeRef <- newIORef (Nothing :: Maybe (Either BleGattError ()))
      subscribeBleCharacteristic ffiBleState testServiceUuid testCharacteristicUuid
        (\_ -> pure ()) (\result -> writeIORef subscribeRef (Just result))
      subscribeResult <- readIORef subscribeRef
      subscribeResult @?= Just (Left (BleGattFailed (-1)))

      mtuRef <- newIORef (Nothing :: Maybe (Either BleGattError BleMtu))
      requestBleMtu ffiBleState (BleMtu 247) (\result -> writeIORef mtuRef (Just result))
      mtuResult <- readIORef mtuRef
      mtuResult @?= Just (Left (BleGattFailed (-1)))

  , testCase "second GATT operation while one is pending fails with BleGattBusy" $ do
      -- A null-context BleState never receives the stub's completion,
      -- so the first operation stays pending.
      bleState <- newBleState
      discoverBleServices bleState (\_ -> pure ())
      ref <- newIORef (Nothing :: Maybe (Either BleGattError BleCharacteristicValue))
      readBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\result -> writeIORef ref (Just result))
      result <- readIORef ref
      result @?= Just (Left BleGattBusy)

  , testCase "discovery accumulates streamed characteristics in order" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe (Either BleGattError [BleDiscoveredCharacteristic]))
      discoverBleServices bleState (\result -> writeIORef ref (Just result))
      dispatchBleCharacteristicDiscovered bleState testDiscoveredRead
      dispatchBleCharacteristicDiscovered bleState testDiscoveredEcho
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattDiscover, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      result <- readIORef ref
      result @?= Just (Right [testDiscoveredRead, testDiscoveredEcho])

  , testCase "read completion delivers the payload" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe (Either BleGattError BleCharacteristicValue))
      readBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\result -> writeIORef ref (Just result))
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattRead, bgcStatusCode = 0
        , bgcPayload = "hatter", bgcGrantedMtu = BleMtu 0 }
      result <- readIORef ref
      result @?= Just (Right "hatter")

  , testCase "mismatched completion fails the pending operation loudly" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe (Either BleGattError BleCharacteristicValue))
      readBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\result -> writeIORef ref (Just result))
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattWrite, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      result <- readIORef ref
      result @?= Just (Left (BleGattFailed (-2)))

  , testCase "subscription delivers notifications until unsubscribed" $ do
      bleState <- newBleState
      notificationsRef <- newIORef ([] :: [BleCharacteristicValue])
      subscribedRef <- newIORef (Nothing :: Maybe (Either BleGattError ()))
      subscribeBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\payload -> modifyIORef' notificationsRef (++ [payload]))
        (\result -> writeIORef subscribedRef (Just result))
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattSubscribe, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      subscribed <- readIORef subscribedRef
      subscribed @?= Just (Right ())
      dispatchBleNotification bleState testServiceUuid testCharacteristicUuid "one"
      dispatchBleNotification bleState testServiceUuid testCharacteristicUuid "two"
      unsubscribeBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\_ -> pure ())
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattUnsubscribe, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      -- After unsubscribing this is logged loudly but not delivered.
      dispatchBleNotification bleState testServiceUuid testCharacteristicUuid "three"
      notifications <- readIORef notificationsRef
      notifications @?= ["one", "two"]

  , testCase "notifications match subscriptions case-insensitively" $ do
      -- Apps subscribe with whatever case they wrote the UUID in;
      -- Android dispatches notifications with lowercase UUIDs and iOS
      -- with uppercase ones.
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe BleCharacteristicValue)
      subscribeBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\payload -> writeIORef ref (Just payload))
        (\_ -> pure ())
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattSubscribe, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      dispatchBleNotification bleState
        (BleServiceUuid "50db505c-8ac4-4738-8448-3b1d9cc09cc5")
        (BleCharacteristicUuid "486f64c6-4b5f-4b3b-8aff-ede56a8b54f5")
        "lowercase"
      result <- readIORef ref
      result @?= Just "lowercase"

  , testCase "failed subscription removes the notification callback" $ do
      bleState <- newBleState
      notificationsRef <- newIORef (0 :: Int)
      subscribedRef <- newIORef (Nothing :: Maybe (Either BleGattError ()))
      subscribeBleCharacteristic bleState testServiceUuid testCharacteristicUuid
        (\_ -> modifyIORef' notificationsRef (+ 1))
        (\result -> writeIORef subscribedRef (Just result))
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattSubscribe, bgcStatusCode = 133
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }
      subscribed <- readIORef subscribedRef
      subscribed @?= Just (Left (BleGattFailed 133))
      dispatchBleNotification bleState testServiceUuid testCharacteristicUuid "x"
      notifications <- readIORef notificationsRef
      notifications @?= 0

  , testCase "MTU completion delivers the granted value" $ do
      bleState <- newBleState
      ref <- newIORef (Nothing :: Maybe (Either BleGattError BleMtu))
      requestBleMtu bleState (BleMtu 247) (\result -> writeIORef ref (Just result))
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattRequestMtu, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 247 }
      result <- readIORef ref
      result @?= Just (Right (BleMtu 247))

  , testCase "completion without a pending operation is safe" $ do
      bleState <- newBleState
      -- Logs loudly to stderr but must not crash.
      dispatchBleGattCompletion bleState BleGattCompletion
        { bgcOperation = BleGattRead, bgcStatusCode = 0
        , bgcPayload = "", bgcGrantedMtu = BleMtu 0 }

  , testCase "startFilteredBleScan registers the scan callback" $ do
      bleState <- newBleState
      startFilteredBleScan bleState testServiceUuid (\_ -> pure ())
      maybeCallback <- readIORef (blesScanCallback bleState)
      case maybeCallback of
        Nothing -> assertFailure "callback should be Just after startFilteredBleScan"
        Just _  -> pure ()
  ]

-- | Fixed UUIDs used by the GATT unit tests.
testServiceUuid :: BleServiceUuid
testServiceUuid = "50DB505C-8AC4-4738-8448-3B1D9CC09CC5"

testCharacteristicUuid :: BleCharacteristicUuid
testCharacteristicUuid = "486F64C6-4B5F-4B3B-8AFF-EDE56A8B54F5"

testDiscoveredRead :: BleDiscoveredCharacteristic
testDiscoveredRead = BleDiscoveredCharacteristic
  { bdcService        = testServiceUuid
  , bdcCharacteristic = testCharacteristicUuid
  , bdcProperties     = [BleCharacteristicRead]
  }

testDiscoveredEcho :: BleDiscoveredCharacteristic
testDiscoveredEcho = BleDiscoveredCharacteristic
  { bdcService        = testServiceUuid
  , bdcCharacteristic = "8CB7C0F4-3B97-4653-9E4F-6F02BF97C7FB"
  , bdcProperties     = [BleCharacteristicWrite, BleCharacteristicNotify]
  }

-- | Dialog tests.
dialogTests :: DialogState -> TestTree
dialogTests ffiDialogState = sequentialTestGroup "Dialog" AllFinish
  [ testCase "showDialog registers callback and desktop stub fires button1" $ do
      ref <- newIORef (Nothing :: Maybe DialogAction)
      showDialog ffiDialogState
        DialogConfig
          { dcTitle   = "Test Alert"
          , dcMessage = "A test message"
          , dcButton1 = "OK"
          , dcButton2 = Nothing
          , dcButton3 = Nothing
          }
        (\action -> writeIORef ref (Just action))
      result <- readIORef ref
      result @?= Just DialogButton1

  , testCase "dispatchDialogResult fires registered callback" $ do
      ref <- newIORef (Nothing :: Maybe DialogAction)
      dialogState <- newDialogState
      modifyIORef' (dsCallbacks dialogState) (\_ ->
        IntMap.singleton 0 (\action -> writeIORef ref (Just action)))
      dispatchDialogResult dialogState 0 1  -- button2
      result <- readIORef ref
      result @?= Just DialogButton2

  , testCase "dispatchDialogResult with DialogDismissed" $ do
      ref <- newIORef (Nothing :: Maybe DialogAction)
      dialogState <- newDialogState
      modifyIORef' (dsCallbacks dialogState) (\_ ->
        IntMap.singleton 0 (\action -> writeIORef ref (Just action)))
      dispatchDialogResult dialogState 0 3  -- dismissed
      result <- readIORef ref
      result @?= Just DialogDismissed

  , testCase "dispatchDialogResult removes callback after firing" $ do
      ref <- newIORef (0 :: Int)
      dialogState <- newDialogState
      modifyIORef' (dsCallbacks dialogState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchDialogResult dialogState 0 0
      count1 <- readIORef ref
      count1 @?= 1
      -- Second dispatch for same ID should be a no-op (callback removed)
      dispatchDialogResult dialogState 0 0
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "unknown requestId is silently logged" $ do
      dialogState <- newDialogState
      -- Should not throw (logs to stderr)
      dispatchDialogResult dialogState 999 0

  , testCase "unknown action code is silently logged" $ do
      ref <- newIORef (0 :: Int)
      dialogState <- newDialogState
      modifyIORef' (dsCallbacks dialogState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchDialogResult dialogState 0 42
      count <- readIORef ref
      count @?= 0

  , testCase "dialogActionFromInt round-trips" $ do
      dialogActionFromInt 0 @?= Just DialogButton1
      dialogActionFromInt 1 @?= Just DialogButton2
      dialogActionFromInt 2 @?= Just DialogButton3
      dialogActionFromInt 3 @?= Just DialogDismissed
      dialogActionFromInt 4 @?= Nothing
      dialogActionFromInt (-1) @?= Nothing
      dialogActionFromInt 100 @?= Nothing
  ]

authSessionTests :: AuthSessionState -> TestTree
authSessionTests ffiAuthSessionState = sequentialTestGroup "AuthSession" AllFinish
  [ testCase "desktop stub returns success with fake redirect URL" $ do
      ref <- newIORef (Nothing :: Maybe AuthSessionResult)
      startAuthSession ffiAuthSessionState
        "https://example.com/auth?client_id=demo"
        "hatter"
        (\result -> writeIORef ref (Just result))
      result <- readIORef ref
      case result of
        Just (AuthSessionSuccess redirectUrl) -> do
          assertBool "redirect URL contains scheme" ("hatter://" `Text.isPrefixOf` redirectUrl)
          assertBool "redirect URL contains code param" ("code=DESKTOP_STUB_CODE" `Text.isInfixOf` redirectUrl)
        _ -> assertFailure $ "expected AuthSessionSuccess, got: " ++ show result

  , testCase "dispatchAuthSessionResult fires Success callback with redirect URL" $ do
      ref <- newIORef (Nothing :: Maybe AuthSessionResult)
      authState <- newAuthSessionState
      modifyIORef' (asCallbacks authState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchAuthSessionResult authState 0 0 (Just "myapp://cb?code=abc") Nothing
      result <- readIORef ref
      result @?= Just (AuthSessionSuccess "myapp://cb?code=abc")

  , testCase "dispatchAuthSessionResult fires Cancelled callback" $ do
      ref <- newIORef (Nothing :: Maybe AuthSessionResult)
      authState <- newAuthSessionState
      modifyIORef' (asCallbacks authState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchAuthSessionResult authState 0 1 Nothing Nothing
      result <- readIORef ref
      result @?= Just AuthSessionCancelled

  , testCase "dispatchAuthSessionResult fires Error callback with message" $ do
      ref <- newIORef (Nothing :: Maybe AuthSessionResult)
      authState <- newAuthSessionState
      modifyIORef' (asCallbacks authState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchAuthSessionResult authState 0 2 Nothing (Just "network error")
      result <- readIORef ref
      result @?= Just (AuthSessionError "network error")

  , testCase "callback removed after dispatch (idempotency)" $ do
      ref <- newIORef (0 :: Int)
      authState <- newAuthSessionState
      modifyIORef' (asCallbacks authState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchAuthSessionResult authState 0 0 (Just "myapp://cb") Nothing
      count1 <- readIORef ref
      count1 @?= 1
      dispatchAuthSessionResult authState 0 0 (Just "myapp://cb") Nothing
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "authSessionResultFromInt roundtrips valid codes" $ do
      authSessionResultFromInt 0 (Just "url") Nothing @?= Just (AuthSessionSuccess "url")
      authSessionResultFromInt 1 Nothing Nothing @?= Just AuthSessionCancelled
      authSessionResultFromInt 2 Nothing (Just "err") @?= Just (AuthSessionError "err")

  , testCase "authSessionResultFromInt rejects unknown codes" $ do
      authSessionResultFromInt 3 Nothing Nothing @?= Nothing
      authSessionResultFromInt (-1) Nothing Nothing @?= Nothing
      authSessionResultFromInt 100 Nothing Nothing @?= Nothing

  , testCase "unknown requestId does not crash" $ do
      authState <- newAuthSessionState
      dispatchAuthSessionResult authState 999 0 (Just "url") Nothing

  , testCase "unknown status code does not fire callback" $ do
      ref <- newIORef (0 :: Int)
      authState <- newAuthSessionState
      modifyIORef' (asCallbacks authState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchAuthSessionResult authState 0 42 Nothing Nothing
      count <- readIORef ref
      count @?= 0
  ]

locationTests :: TestTree
locationTests = testGroup "Location"
  [ testCase "desktop stub dispatches fixed location on startLocationUpdates" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let locationState = acLocationState appCtx
      ref <- newIORef (Nothing :: Maybe LocationData)
      startLocationUpdates locationState (\loc -> writeIORef ref (Just loc))
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired by desktop stub"
        Just loc -> do
          ldLatitude loc @?= 52.37
          ldLongitude loc @?= 4.90
          ldAltitude loc @?= 0.0
          ldAccuracy loc @?= 10.0
      freeAppContext ctxPtr

  , testCase "dispatchLocationUpdate fires callback with correct LocationData" $ do
      locationState <- newLocationState
      ref <- newIORef (Nothing :: Maybe LocationData)
      writeIORef (lsUpdateCallback locationState) (Just (\loc -> writeIORef ref (Just loc)))
      dispatchLocationUpdate locationState 48.86 2.35 35.0 5.0
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just loc -> do
          ldLatitude loc @?= 48.86
          ldLongitude loc @?= 2.35
          ldAltitude loc @?= 35.0
          ldAccuracy loc @?= 5.0

  , testCase "dispatchLocationUpdate with no active listener is no-op" $ do
      locationState <- newLocationState
      dispatchLocationUpdate locationState 0.0 0.0 0.0 0.0

  , testCase "stopLocationUpdates clears callback" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let locationState = acLocationState appCtx
      startLocationUpdates locationState (\_ -> pure ())
      stopLocationUpdates locationState
      maybeCb <- readIORef (lsUpdateCallback locationState)
      case maybeCb of
        Nothing -> pure ()
        Just _  -> assertFailure "callback should be Nothing after stopLocationUpdates"
      freeAppContext ctxPtr

  , testCase "startLocationUpdates replaces existing callback" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let locationState = acLocationState appCtx
      refOld <- newIORef (0 :: Int)
      refNew <- newIORef (0 :: Int)
      writeIORef (lsUpdateCallback locationState) (Just (\_ -> modifyIORef' refOld (+ 1)))
      startLocationUpdates locationState (\_ -> modifyIORef' refNew (+ 1))
      oldCount <- readIORef refOld
      newCount <- readIORef refNew
      oldCount @?= 0
      newCount @?= 1
      freeAppContext ctxPtr
  ]

bottomSheetTests :: BottomSheetState -> TestTree
bottomSheetTests ffiBottomSheetState = sequentialTestGroup "BottomSheet" AllFinish
  [ testCase "showBottomSheet registers callback and desktop stub selects first item" $ do
      ref <- newIORef (Nothing :: Maybe BottomSheetAction)
      showBottomSheet ffiBottomSheetState
        BottomSheetConfig
          { bscTitle = "Actions"
          , bscItems = ["Edit", "Delete", "Share"]
          }
        (\action -> writeIORef ref (Just action))
      result <- readIORef ref
      result @?= Just (BottomSheetItemSelected 0)

  , testCase "dispatchBottomSheetResult fires ItemSelected callback" $ do
      ref <- newIORef (Nothing :: Maybe BottomSheetAction)
      bottomSheetState <- newBottomSheetState
      modifyIORef' (bssCallbacks bottomSheetState) (\_ ->
        IntMap.singleton 0 (\action -> writeIORef ref (Just action)))
      dispatchBottomSheetResult bottomSheetState 0 2
      result <- readIORef ref
      result @?= Just (BottomSheetItemSelected 2)

  , testCase "dispatchBottomSheetResult fires Dismissed callback" $ do
      ref <- newIORef (Nothing :: Maybe BottomSheetAction)
      bottomSheetState <- newBottomSheetState
      modifyIORef' (bssCallbacks bottomSheetState) (\_ ->
        IntMap.singleton 0 (\action -> writeIORef ref (Just action)))
      dispatchBottomSheetResult bottomSheetState 0 (-1)
      result <- readIORef ref
      result @?= Just BottomSheetDismissed

  , testCase "callback removed after dispatch (idempotency)" $ do
      ref <- newIORef (0 :: Int)
      bottomSheetState <- newBottomSheetState
      modifyIORef' (bssCallbacks bottomSheetState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchBottomSheetResult bottomSheetState 0 0
      count1 <- readIORef ref
      count1 @?= 1
      dispatchBottomSheetResult bottomSheetState 0 0
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "bottomSheetActionFromInt roundtrips valid codes" $ do
      bottomSheetActionFromInt 0 @?= Just (BottomSheetItemSelected 0)
      bottomSheetActionFromInt 1 @?= Just (BottomSheetItemSelected 1)
      bottomSheetActionFromInt 5 @?= Just (BottomSheetItemSelected 5)
      bottomSheetActionFromInt (-1) @?= Just BottomSheetDismissed

  , testCase "bottomSheetActionFromInt rejects invalid codes" $ do
      bottomSheetActionFromInt (-2) @?= Nothing
      bottomSheetActionFromInt (-100) @?= Nothing

  , testCase "unknown requestId does not crash" $ do
      bottomSheetState <- newBottomSheetState
      dispatchBottomSheetResult bottomSheetState 999 0
  ]

-- | Tests for the AppContext FFI path.
cameraTests :: TestTree
cameraTests = testGroup "Camera"
  [ testCase "desktop stub dispatches success with picture on capturePhoto" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let cameraState = acCameraState appCtx
      ref <- newIORef (Nothing :: Maybe CameraResult)
      capturePhoto cameraState (\result -> writeIORef ref (Just result))
      maybeResult <- readIORef ref
      case maybeResult of
        Nothing -> assertFailure "callback should have been fired by desktop stub"
        Just result -> do
          crStatus result @?= CameraSuccess
          case crPicture result of
            Nothing -> assertFailure "picture should be present for photo capture"
            Just pic -> do
              pictureWidth pic @?= 1
              pictureHeight pic @?= 1
              assertBool "picture data should not be empty"
                (not (BS.null (pictureData pic)))
      freeAppContext ctxPtr

  , testCase "desktop stub dispatches success on startVideoCapture with frame/audio callbacks" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let cameraState = acCameraState appCtx
      completionRef <- newIORef (Nothing :: Maybe CameraResult)
      frameCount <- newIORef (0 :: Int)
      audioCount <- newIORef (0 :: Int)
      startVideoCapture cameraState
        (\_ -> modifyIORef' frameCount (+ 1))
        (\_ -> modifyIORef' audioCount (+ 1))
        (\result -> writeIORef completionRef (Just result))
      frames <- readIORef frameCount
      frames @?= 2
      audio <- readIORef audioCount
      audio @?= 1
      maybeResult <- readIORef completionRef
      case maybeResult of
        Nothing -> assertFailure "completion callback should have been fired by desktop stub"
        Just result -> do
          crStatus result @?= CameraSuccess
          crPicture result @?= Nothing
      freeAppContext ctxPtr

  , testCase "dispatchCameraResult fires callback with picture data" $ do
      cameraState <- newCameraState
      ref <- newIORef (Nothing :: Maybe CameraResult)
      modifyIORef' (csCallbacks cameraState)
        (IntMap.insert 0 (\result -> writeIORef ref (Just result)))
      let jpegBytes = BS.pack [0xFF, 0xD8, 0xFF, 0xD9]
      dispatchCameraResult cameraState 0 0
        (Just jpegBytes) 640 480
      maybeResult <- readIORef ref
      case maybeResult of
        Nothing -> assertFailure "callback should have been fired"
        Just result -> do
          crStatus result @?= CameraSuccess
          case crPicture result of
            Nothing -> assertFailure "picture should be present"
            Just pic -> do
              pictureWidth pic @?= 640
              pictureHeight pic @?= 480
              pictureData pic @?= jpegBytes

  , testCase "dispatchCameraResult without image data has no picture" $ do
      cameraState <- newCameraState
      ref <- newIORef (Nothing :: Maybe CameraResult)
      modifyIORef' (csCallbacks cameraState)
        (IntMap.insert 0 (\result -> writeIORef ref (Just result)))
      dispatchCameraResult cameraState 0 0
        Nothing 0 0
      maybeResult <- readIORef ref
      case maybeResult of
        Nothing -> assertFailure "callback should have been fired"
        Just result -> do
          crStatus result @?= CameraSuccess
          crPicture result @?= Nothing

  , testCase "dispatchCameraResult with error status has no picture" $ do
      cameraState <- newCameraState
      ref <- newIORef (Nothing :: Maybe CameraResult)
      modifyIORef' (csCallbacks cameraState)
        (IntMap.insert 0 (\result -> writeIORef ref (Just result)))
      let jpegBytes = BS.pack [0xFF, 0xD8, 0xFF, 0xD9]
      dispatchCameraResult cameraState 0 4 (Just jpegBytes) 1 1
      maybeResult <- readIORef ref
      case maybeResult of
        Nothing -> assertFailure "callback should have been fired"
        Just result -> do
          crStatus result @?= CameraError
          crPicture result @?= Nothing

  , testCase "dispatchCameraResult with no callback is no-op" $ do
      cameraState <- newCameraState
      dispatchCameraResult cameraState 99 0 Nothing 0 0

  , testCase "dispatchVideoFrame fires frame callback" $ do
      cameraState <- newCameraState
      ref <- newIORef (Nothing :: Maybe Picture)
      modifyIORef' (csFrameCallbacks cameraState)
        (IntMap.insert 0 (\pic -> writeIORef ref (Just pic)))
      let jpegBytes = BS.pack [0xFF, 0xD8, 0xFF, 0xD9]
      dispatchVideoFrame cameraState 0 jpegBytes 320 240
      maybePic <- readIORef ref
      case maybePic of
        Nothing -> assertFailure "frame callback should have been fired"
        Just pic -> do
          pictureWidth pic @?= 320
          pictureHeight pic @?= 240
          pictureData pic @?= jpegBytes

  , testCase "dispatchAudioChunk fires audio callback" $ do
      cameraState <- newCameraState
      ref <- newIORef (Nothing :: Maybe BS.ByteString)
      modifyIORef' (csAudioCallbacks cameraState)
        (IntMap.insert 0 (\chunk -> writeIORef ref (Just chunk)))
      let pcmBytes = BS.pack [0x00, 0x01, 0x02, 0x03]
      dispatchAudioChunk cameraState 0 pcmBytes
      maybeChunk <- readIORef ref
      case maybeChunk of
        Nothing -> assertFailure "audio callback should have been fired"
        Just chunk -> chunk @?= pcmBytes

  , testCase "dispatchCameraResult cleans up frame/audio callbacks" $ do
      cameraState <- newCameraState
      modifyIORef' (csCallbacks cameraState)
        (IntMap.insert 0 (\_ -> pure ()))
      modifyIORef' (csFrameCallbacks cameraState)
        (IntMap.insert 0 (\_ -> pure ()))
      modifyIORef' (csAudioCallbacks cameraState)
        (IntMap.insert 0 (\_ -> pure ()))
      dispatchCameraResult cameraState 0 0 Nothing 0 0
      callbacks <- readIORef (csCallbacks cameraState)
      IntMap.member 0 callbacks @?= False
      frameCallbacks <- readIORef (csFrameCallbacks cameraState)
      IntMap.member 0 frameCallbacks @?= False
      audioCallbacks <- readIORef (csAudioCallbacks cameraState)
      IntMap.member 0 audioCallbacks @?= False

  , testCase "capturePhoto assigns incremental request IDs" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let cameraState = acCameraState appCtx
      idsBefore <- readIORef (csNextId cameraState)
      idsBefore @?= 0
      capturePhoto cameraState (\_ -> pure ())
      idsAfter1 <- readIORef (csNextId cameraState)
      idsAfter1 @?= 1
      capturePhoto cameraState (\_ -> pure ())
      idsAfter2 <- readIORef (csNextId cameraState)
      idsAfter2 @?= 2
      freeAppContext ctxPtr

  , testCase "cameraStatusFromInt round-trips known codes" $ do
      cameraStatusFromInt 0 @?= Just CameraSuccess
      cameraStatusFromInt 1 @?= Just CameraCancelled
      cameraStatusFromInt 2 @?= Just CameraPermissionDenied
      cameraStatusFromInt 3 @?= Just CameraUnavailable
      cameraStatusFromInt 4 @?= Just CameraError
      cameraStatusFromInt 5 @?= Nothing
      cameraStatusFromInt (-1) @?= Nothing

  , testCase "cameraSourceToInt maps sources correctly" $ do
      cameraSourceToInt CameraBack @?= 0
      cameraSourceToInt CameraFront @?= 1

  , testCase "stopCameraSession is safe when no session active" $ do
      cameraState <- newCameraState
      stopCameraSession cameraState
  ]

httpTests :: HttpState -> TestTree
httpTests ffiHttpState = sequentialTestGroup "Http" AllFinish
  [ testCase "desktop stub returns 200 OK on GET" $ do
      ref <- newIORef (Nothing :: Maybe (Either HttpError HttpResponse))
      let request = HttpRequest
            { hrMethod  = HttpGet
            , hrUrl     = "http://localhost/test"
            , hrHeaders = []
            , hrBody    = BS.empty
            }
      performRequest ffiHttpState request (\result -> writeIORef ref (Just result))
      result <- readIORef ref
      case result of
        Just (Right response) ->
          hrStatusCode response @?= 200
        _ -> assertFailure $ "expected Right HttpResponse, got: " ++ show result

  , testCase "dispatchHttpResult success fires callback with status and body" $ do
      ref <- newIORef (Nothing :: Maybe (Either HttpError HttpResponse))
      httpState <- newHttpState
      modifyIORef' (hsCallbacks httpState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchHttpResult httpState 0 0 200 (Just "Content-Type: text/html\n") (BS.pack [72, 105])
      result <- readIORef ref
      case result of
        Just (Right response) -> do
          hrStatusCode response @?= 200
          hrRespBody response @?= BS.pack [72, 105]
          hrRespHeaders response @?= [("Content-Type", "text/html")]
        _ -> assertFailure $ "expected Right HttpResponse, got: " ++ show result

  , testCase "dispatchHttpResult network error fires Left callback" $ do
      ref <- newIORef (Nothing :: Maybe (Either HttpError HttpResponse))
      httpState <- newHttpState
      modifyIORef' (hsCallbacks httpState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchHttpResult httpState 0 1 0 (Just "connection refused") BS.empty
      result <- readIORef ref
      result @?= Just (Left (HttpNetworkError "connection refused"))

  , testCase "dispatchHttpResult timeout fires Left callback" $ do
      ref <- newIORef (Nothing :: Maybe (Either HttpError HttpResponse))
      httpState <- newHttpState
      modifyIORef' (hsCallbacks httpState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchHttpResult httpState 0 2 0 Nothing BS.empty
      result <- readIORef ref
      result @?= Just (Left HttpTimeout)

  , testCase "callback removed after dispatch (idempotency)" $ do
      ref <- newIORef (0 :: Int)
      httpState <- newHttpState
      modifyIORef' (hsCallbacks httpState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchHttpResult httpState 0 0 200 Nothing BS.empty
      count1 <- readIORef ref
      count1 @?= 1
      -- Second dispatch for same ID should be a no-op (callback removed)
      dispatchHttpResult httpState 0 0 200 Nothing BS.empty
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "unknown requestId does not crash" $ do
      httpState <- newHttpState
      -- Should not throw (logs to stderr)
      dispatchHttpResult httpState 999 0 200 Nothing BS.empty

  , testCase "header serialization round-trips" $ do
      let headers = [("Content-Type", "application/json"), ("Authorization", "Bearer tok123")]
      let serialized = serializeHeaders headers
      let parsed = parseHeaders serialized
      parsed @?= headers

  , testCase "parseHeaders skips malformed lines" $ do
      let headerText = "Good-Header: value\nBadLine\nAnother: ok\n"
      parseHeaders headerText @?= [("Good-Header", "value"), ("Another", "ok")]

  , testCase "httpMethodToInt covers all constructors" $ do
      httpMethodToInt HttpGet @?= 0
      httpMethodToInt HttpPost @?= 1
      httpMethodToInt HttpPut @?= 2
      httpMethodToInt HttpDelete @?= 3
  ]

networkStatusTests :: TestTree
networkStatusTests = testGroup "NetworkStatus"
  [ testCase "desktop stub dispatches connected WiFi on startNetworkMonitoring" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let networkStatusState = acNetworkStatusState appCtx
      ref <- newIORef (Nothing :: Maybe NetworkStatus)
      startNetworkMonitoring networkStatusState (\status -> writeIORef ref (Just status))
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired by desktop stub"
        Just status -> do
          nsConnected status @?= True
          nsTransport status @?= TransportWifi
      freeAppContext ctxPtr

  , testCase "dispatchNetworkStatusChange fires callback with correct data" $ do
      networkStatusState <- newNetworkStatusState
      ref <- newIORef (Nothing :: Maybe NetworkStatus)
      writeIORef (nssUpdateCallback networkStatusState) (Just (\status -> writeIORef ref (Just status)))
      dispatchNetworkStatusChange networkStatusState 1 2
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just status -> do
          nsConnected status @?= True
          nsTransport status @?= TransportCellular

  , testCase "dispatchNetworkStatusChange with no active listener is no-op" $ do
      networkStatusState <- newNetworkStatusState
      dispatchNetworkStatusChange networkStatusState 1 1

  , testCase "stopNetworkMonitoring clears callback" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let networkStatusState = acNetworkStatusState appCtx
      startNetworkMonitoring networkStatusState (\_ -> pure ())
      stopNetworkMonitoring networkStatusState
      maybeCb <- readIORef (nssUpdateCallback networkStatusState)
      case maybeCb of
        Nothing -> pure ()
        Just _  -> assertFailure "callback should be Nothing after stopNetworkMonitoring"
      freeAppContext ctxPtr

  , testCase "startNetworkMonitoring replaces existing callback" $ do
      app <- makeSimpleApp (\_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing }))
      ctxPtr <- newAppContext app
      appCtx <- derefAppContext ctxPtr
      let networkStatusState = acNetworkStatusState appCtx
      refOld <- newIORef (0 :: Int)
      refNew <- newIORef (0 :: Int)
      writeIORef (nssUpdateCallback networkStatusState) (Just (\_ -> modifyIORef' refOld (+ 1)))
      startNetworkMonitoring networkStatusState (\_ -> modifyIORef' refNew (+ 1))
      oldCount <- readIORef refOld
      newCount <- readIORef refNew
      oldCount @?= 0
      newCount @?= 1
      freeAppContext ctxPtr

  , testCase "networkTransportFromInt roundtrips for all transports" $
      mapM_ (\transport ->
        networkTransportFromInt (networkTransportToInt transport) @?= transport
      ) [TransportNone, TransportWifi, TransportCellular, TransportEthernet, TransportOther]

  , testCase "networkTransportFromInt maps unknown codes to TransportOther" $ do
      networkTransportFromInt 99 @?= TransportOther
      networkTransportFromInt (-1) @?= TransportOther

  , testCase "disconnected status sets nsConnected to False" $ do
      networkStatusState <- newNetworkStatusState
      ref <- newIORef (Nothing :: Maybe NetworkStatus)
      writeIORef (nssUpdateCallback networkStatusState) (Just (\status -> writeIORef ref (Just status)))
      dispatchNetworkStatusChange networkStatusState 0 0
      result <- readIORef ref
      case result of
        Nothing -> assertFailure "callback should have been fired"
        Just status -> do
          nsConnected status @?= False
          nsTransport status @?= TransportNone
  ]

platformSignInTests :: PlatformSignInState -> TestTree
platformSignInTests ffiPlatformSignInState = sequentialTestGroup "PlatformSignIn" AllFinish
  [ testCase "desktop stub returns Apple credentials" $ do
      ref <- newIORef (Nothing :: Maybe SignInResult)
      startPlatformSignIn ffiPlatformSignInState AppleSignIn
        (\result -> writeIORef ref (Just result))
      result <- readIORef ref
      case result of
        Just (SignInSuccess cred) -> do
          sicProvider cred @?= AppleSignIn
          sicUserId cred @?= "apple-stub-user-001"
          assertBool "identity token present" (sicIdentityToken cred /= Nothing)
          assertBool "email present" (sicEmail cred /= Nothing)
          assertBool "full name present" (sicFullName cred /= Nothing)
        _ -> assertFailure $ "expected SignInSuccess with Apple credentials, got: " ++ show result

  , testCase "desktop stub returns Google credentials" $ do
      ref <- newIORef (Nothing :: Maybe SignInResult)
      startPlatformSignIn ffiPlatformSignInState GoogleSignIn
        (\result -> writeIORef ref (Just result))
      result <- readIORef ref
      case result of
        Just (SignInSuccess cred) -> do
          sicProvider cred @?= GoogleSignIn
          sicUserId cred @?= "google-stub-user-001"
          assertBool "identity token present" (sicIdentityToken cred /= Nothing)
          assertBool "email present" (sicEmail cred /= Nothing)
        _ -> assertFailure $ "expected SignInSuccess with Google credentials, got: " ++ show result

  , testCase "dispatchPlatformSignInResult fires Success callback" $ do
      ref <- newIORef (Nothing :: Maybe SignInResult)
      signInState <- newPlatformSignInState
      modifyIORef' (psiCallbacks signInState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchPlatformSignInResult signInState 0 0
        (Just "token123") (Just "user-42") (Just "user@example.com") (Just "Test User") 0
      result <- readIORef ref
      case result of
        Just (SignInSuccess cred) -> do
          sicIdentityToken cred @?= Just "token123"
          sicUserId cred @?= "user-42"
          sicEmail cred @?= Just "user@example.com"
          sicFullName cred @?= Just "Test User"
          sicProvider cred @?= AppleSignIn
        _ -> assertFailure $ "expected SignInSuccess, got: " ++ show result

  , testCase "dispatchPlatformSignInResult fires Cancelled callback" $ do
      ref <- newIORef (Nothing :: Maybe SignInResult)
      signInState <- newPlatformSignInState
      modifyIORef' (psiCallbacks signInState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchPlatformSignInResult signInState 0 1 Nothing Nothing Nothing Nothing 0
      result <- readIORef ref
      result @?= Just SignInCancelled

  , testCase "dispatchPlatformSignInResult fires Error callback with message" $ do
      ref <- newIORef (Nothing :: Maybe SignInResult)
      signInState <- newPlatformSignInState
      modifyIORef' (psiCallbacks signInState) (\_ ->
        IntMap.singleton 0 (\result -> writeIORef ref (Just result)))
      dispatchPlatformSignInResult signInState 0 2 Nothing Nothing Nothing (Just "auth failed") 0
      result <- readIORef ref
      result @?= Just (SignInError "auth failed")

  , testCase "callback removed after dispatch (idempotency)" $ do
      ref <- newIORef (0 :: Int)
      signInState <- newPlatformSignInState
      modifyIORef' (psiCallbacks signInState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchPlatformSignInResult signInState 0 0
        (Just "tok") (Just "uid") Nothing Nothing 0
      count1 <- readIORef ref
      count1 @?= 1
      dispatchPlatformSignInResult signInState 0 0
        (Just "tok") (Just "uid") Nothing Nothing 0
      count2 <- readIORef ref
      count2 @?= 1

  , testCase "signInResultFromInt roundtrips valid codes" $ do
      case signInResultFromInt 0 (Just "tok") (Just "uid") Nothing Nothing 0 of
        Just (SignInSuccess cred) -> sicUserId cred @?= "uid"
        other -> assertFailure $ "expected SignInSuccess, got: " ++ show other
      signInResultFromInt 1 Nothing Nothing Nothing Nothing 0 @?= Just SignInCancelled
      signInResultFromInt 2 Nothing Nothing Nothing (Just "err") 0 @?= Just (SignInError "err")

  , testCase "signInResultFromInt rejects unknown codes" $ do
      signInResultFromInt 3 Nothing Nothing Nothing Nothing 0 @?= Nothing
      signInResultFromInt (-1) Nothing Nothing Nothing Nothing 0 @?= Nothing
      signInResultFromInt 100 Nothing Nothing Nothing Nothing 0 @?= Nothing

  , testCase "providerToInt and providerFromInt roundtrip" $ do
      providerFromInt (providerToInt AppleSignIn) @?= Just AppleSignIn
      providerFromInt (providerToInt GoogleSignIn) @?= Just GoogleSignIn
      providerFromInt 99 @?= Nothing
      providerFromInt (-1) @?= Nothing

  , testCase "unknown requestId does not crash" $ do
      signInState <- newPlatformSignInState
      dispatchPlatformSignInResult signInState 999 0
        (Just "tok") (Just "uid") Nothing Nothing 0

  , testCase "unknown status code does not fire callback" $ do
      ref <- newIORef (0 :: Int)
      signInState <- newPlatformSignInState
      modifyIORef' (psiCallbacks signInState) (\_ ->
        IntMap.singleton 0 (\_ -> modifyIORef' ref (+ 1)))
      dispatchPlatformSignInResult signInState 0 42 Nothing Nothing Nothing Nothing 0
      count <- readIORef ref
      count @?= 0
  ]
