{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Secure key-value storage for mobile platforms.
--
-- Provides a callback-based API for writing, reading, and deleting
-- key-value pairs in platform-secure storage (Android SharedPreferences,
-- iOS/watchOS Keychain).  On desktop (no platform bridge registered)
-- an in-memory C stub provides basic functionality so that @cabal test@
-- exercises write/read round-trips without native code.
--
-- Results come back as for the other platform requests, by number
-- ("Hatter.Requests").
module Hatter.SecureStorage
  ( SecureStorageStatus(..)
  , SecureStorageState(..)
  , newSecureStorageState
  , storageStatusFromInt
  , secureStorageWrite
  , secureStorageRead
  , secureStorageDelete
  , dispatchSecureStorageResult
  )
where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Text (Text)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import Hatter.Marshal (withText)
import Hatter.Requests (Requests, answered, newRequests, request)
import System.IO (hPutStrLn, stderr)

-- | Result of a secure storage operation.
data SecureStorageStatus
  = StorageSuccess
  | StorageNotFound
  | StorageError
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | What waits for the platform's secure storage.
data SecureStorageState = SecureStorageState
  { ssRequests   :: Requests (SecureStorageStatus -> Maybe Text -> IO ())
    -- ^ What waits for each request's result: a read's comes with the
    -- value, if there is one.
  , ssContextPtr :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'SecureStorageState' with no pending callbacks.
-- The context pointer is initially null and must be set via
-- 'ssContextPtr' before calling any storage operation.
newSecureStorageState :: IO SecureStorageState
newSecureStorageState = SecureStorageState <$> newRequests <*> newIORef nullPtr

-- | Convert a C bridge status code to 'SecureStorageStatus'.
-- Returns 'Nothing' for unknown codes.
storageStatusFromInt :: CInt -> Maybe SecureStorageStatus
storageStatusFromInt 0 = Just StorageSuccess
storageStatusFromInt 1 = Just StorageNotFound
storageStatusFromInt 2 = Just StorageError
storageStatusFromInt _ = Nothing

-- | Write a key-value pair to secure storage.  Registers @callback@ and
-- calls the C bridge.  The callback fires when the platform responds
-- (or synchronously on desktop via the in-memory stub).
secureStorageWrite :: SecureStorageState -> Text -> Text -> (SecureStorageStatus -> IO ()) -> IO ()
secureStorageWrite storageState key value callback = do
  requestId <- request (ssRequests storageState) (\status _ -> callback status)
  ctx <- readIORef (ssContextPtr storageState)
  withText key $ \cKey ->
    withText value $ \cValue ->
      c_secureStorageWrite ctx requestId cKey cValue

-- | Read a value from secure storage by key.  Registers @callback@ and
-- calls the C bridge.  The callback receives the status and an optional
-- value ('Just' on success, 'Nothing' on not-found or error).
secureStorageRead :: SecureStorageState -> Text -> (SecureStorageStatus -> Maybe Text -> IO ()) -> IO ()
secureStorageRead storageState key callback = do
  requestId <- request (ssRequests storageState) callback
  ctx <- readIORef (ssContextPtr storageState)
  withText key $ \cKey ->
    c_secureStorageRead ctx requestId cKey

-- | Delete a key from secure storage.  Registers @callback@ and calls
-- the C bridge.  The callback fires when the platform responds.
secureStorageDelete :: SecureStorageState -> Text -> (SecureStorageStatus -> IO ()) -> IO ()
secureStorageDelete storageState key callback = do
  requestId <- request (ssRequests storageState) (\status _ -> callback status)
  ctx <- readIORef (ssContextPtr storageState)
  withText key $ \cKey ->
    c_secureStorageDelete ctx requestId cKey

-- | Dispatch a secure storage result from the platform back to the
-- registered Haskell callback, which is then forgotten.
-- Unknown request IDs or status codes are logged to stderr.
dispatchSecureStorageResult :: SecureStorageState -> CInt -> CInt -> Maybe Text -> IO ()
dispatchSecureStorageResult storageState requestId statusCode maybeValue =
  case storageStatusFromInt statusCode of
    Nothing -> hPutStrLn stderr $
      "dispatchSecureStorageResult: unknown status code " ++ show statusCode
    Just status -> do
      waiting <- answered "dispatchSecureStorageResult" (ssRequests storageState) requestId
      mapM_ (\callback -> callback status maybeValue) waiting

-- | FFI import: write a key-value pair via the C bridge.
foreign import ccall "secure_storage_write"
  c_secureStorageWrite :: Ptr () -> CInt -> CString -> CString -> IO ()

-- | FFI import: read a value via the C bridge.
foreign import ccall "secure_storage_read"
  c_secureStorageRead :: Ptr () -> CInt -> CString -> IO ()

-- | FFI import: delete a key via the C bridge.
foreign import ccall "secure_storage_delete"
  c_secureStorageDelete :: Ptr () -> CInt -> CString -> IO ()
