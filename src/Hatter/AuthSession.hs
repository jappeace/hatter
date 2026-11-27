{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
-- | OAuth2/PKCE authentication session API for mobile platforms.
--
-- Provides a callback-based API for starting authentication sessions
-- that open the system browser with an auth URL and receive a redirect
-- callback containing the auth code.
--
-- Platform implementations:
--   * Android: @Intent.ACTION_VIEW@ + intent filter for redirect scheme
--   * iOS: @ASWebAuthenticationSession@
--   * watchOS: @ASWebAuthenticationSession@
--   * Desktop: stub returns a fake redirect URL synchronously
--
-- Results come back by request number, as for the other platform
-- requests ("Hatter.Requests").
module Hatter.AuthSession
  ( AuthSessionResult(..)
  , AuthSessionState(..)
  , newAuthSessionState
  , authSessionResultFromInt
  , startAuthSession
  , dispatchAuthSessionResult
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

-- | Result of an authentication session.
data AuthSessionResult
  = AuthSessionSuccess Text   -- ^ Full redirect URL with query params
  | AuthSessionCancelled      -- ^ User cancelled the session
  | AuthSessionError Text     -- ^ Platform-specific error message
  deriving (Show, Eq)

-- | What waits for the platform's auth session requests.
data AuthSessionState = AuthSessionState
  { asRequests   :: Requests (AuthSessionResult -> IO ())
    -- ^ What waits for each request's result.
  , asContextPtr :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'AuthSessionState' with no pending callbacks.
-- The context pointer is initially null and must be set via
-- 'asContextPtr' before calling 'startAuthSession'.
newAuthSessionState :: IO AuthSessionState
newAuthSessionState = do
  requests   <- newRequests
  contextPtr <- newIORef nullPtr
  pure AuthSessionState
    { asRequests   = requests
    , asContextPtr = contextPtr
    }

-- | Convert a C bridge status code to 'AuthSessionResult'.
-- Returns 'Nothing' for unknown codes.
-- Requires the redirect URL or error message to construct the full result.
authSessionResultFromInt :: CInt -> Maybe Text -> Maybe Text -> Maybe AuthSessionResult
authSessionResultFromInt 0 (Just redirectUrl) _          = Just (AuthSessionSuccess redirectUrl)
authSessionResultFromInt 0 Nothing            _          = Just (AuthSessionSuccess "")
authSessionResultFromInt 1 _                  _          = Just AuthSessionCancelled
authSessionResultFromInt 2 _                  (Just err) = Just (AuthSessionError err)
authSessionResultFromInt 2 _                  Nothing    = Just (AuthSessionError "")
authSessionResultFromInt _ _                  _          = Nothing

-- | Start an authentication session. Opens the system browser with
-- @authUrl@ and waits for a redirect to @callbackScheme@.
-- Registers @callback@ and calls the C bridge. The callback fires
-- when the auth session completes (or synchronously on desktop via
-- the stub that returns a fake redirect URL).
startAuthSession :: AuthSessionState -> Text -> Text -> (AuthSessionResult -> IO ()) -> IO ()
startAuthSession authSessionState authUrl callbackScheme callback = do
  requestId <- request (asRequests authSessionState) callback
  ctx <- readIORef (asContextPtr authSessionState)
  withText authUrl $ \cUrl ->
    withText callbackScheme $ \cScheme ->
      c_authSessionStart ctx requestId cUrl cScheme

-- | Dispatch an auth session result from the platform back to the
-- registered Haskell callback. Removes the callback after firing.
-- Unknown request IDs or status codes are silently logged to stderr.
dispatchAuthSessionResult :: AuthSessionState -> CInt -> CInt -> Maybe Text -> Maybe Text -> IO ()
dispatchAuthSessionResult authSessionState requestId statusCode maybeRedirectUrl maybeErrorMsg =
  case authSessionResultFromInt statusCode maybeRedirectUrl maybeErrorMsg of
    Nothing -> hPutStrLn stderr $
      "dispatchAuthSessionResult: unknown status code " ++ show statusCode
    Just result -> do
      waiting <- answered "dispatchAuthSessionResult" (asRequests authSessionState) requestId
      mapM_ ($ result) waiting

-- | FFI import: start an auth session via the C bridge.
foreign import ccall "auth_session_start"
  c_authSessionStart :: Ptr () -> CInt -> CString -> CString -> IO ()
