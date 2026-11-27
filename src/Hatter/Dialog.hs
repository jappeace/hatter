{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Modal dialog / alert API for mobile platforms.
--
-- Provides an imperative API for showing platform-native modal dialogs
-- (Android AlertDialog, iOS UIAlertController, watchOS SwiftUI .alert).
-- Dialogs are fire-and-forget: the platform manages the dialog lifecycle
-- independently of the Haskell UI rendering loop.
--
-- Results come back by request number, as for the other platform
-- requests ("Hatter.Requests").
-- Up to 3 buttons are supported (Android AlertDialog's maximum).
module Hatter.Dialog
  ( DialogAction(..)
  , DialogConfig(..)
  , DialogState(..)
  , newDialogState
  , dialogActionFromInt
  , showDialog
  , dispatchDialogResult
  )
where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Text (Text)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import Hatter.Marshal (withMaybeText, withText)
import Hatter.Requests (Requests, answered, newRequests, request)
import System.IO (hPutStrLn, stderr)

-- | Which button was tapped, or whether the dialog was dismissed.
data DialogAction
  = DialogButton1
  | DialogButton2
  | DialogButton3
  | DialogDismissed
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Configuration for a dialog.  At least one button ('dcButton1') is
-- required.  The second and third buttons are optional.
data DialogConfig = DialogConfig
  { dcTitle   :: Text
  , dcMessage :: Text
  , dcButton1 :: Text
  , dcButton2 :: Maybe Text
  , dcButton3 :: Maybe Text
  }

-- | What waits for the platform's dialog requests.
data DialogState = DialogState
  { dsRequests   :: Requests (DialogAction -> IO ())
    -- ^ What waits for each request's result.
  , dsContextPtr :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'DialogState' with no pending callbacks.
-- The context pointer is initially null and must be set via
-- 'dsContextPtr' before calling 'showDialog'.
newDialogState :: IO DialogState
newDialogState = do
  requests   <- newRequests
  contextPtr <- newIORef nullPtr
  pure DialogState
    { dsRequests   = requests
    , dsContextPtr = contextPtr
    }

-- | Convert a C bridge action code to 'DialogAction'.
-- Returns 'Nothing' for unknown codes.
dialogActionFromInt :: CInt -> Maybe DialogAction
dialogActionFromInt 0 = Just DialogButton1
dialogActionFromInt 1 = Just DialogButton2
dialogActionFromInt 2 = Just DialogButton3
dialogActionFromInt 3 = Just DialogDismissed
dialogActionFromInt _ = Nothing

-- | Show a modal dialog with the given configuration.  Registers
-- @callback@ and calls the C bridge.  The callback fires when the
-- user taps a button or dismisses the dialog (or synchronously on
-- desktop via the stub that auto-presses button 1).
showDialog :: DialogState -> DialogConfig -> (DialogAction -> IO ()) -> IO ()
showDialog dialogState config callback = do
  requestId <- request (dsRequests dialogState) callback
  ctx <- readIORef (dsContextPtr dialogState)
  withText (dcTitle config) $ \cTitle ->
    withText (dcMessage config) $ \cMessage ->
      withText (dcButton1 config) $ \cButton1 ->
        withMaybeText (dcButton2 config) $ \cButton2 ->
          withMaybeText (dcButton3 config) $ \cButton3 ->
            c_dialogShow ctx requestId cTitle cMessage cButton1 cButton2 cButton3

-- | Dispatch a dialog result from the platform back to the
-- registered Haskell callback.  Removes the callback after firing.
-- Unknown request IDs or action codes are silently logged to stderr.
dispatchDialogResult :: DialogState -> CInt -> CInt -> IO ()
dispatchDialogResult dialogState requestId actionCode =
  case dialogActionFromInt actionCode of
    Nothing -> hPutStrLn stderr $
      "dispatchDialogResult: unknown action code " ++ show actionCode
    Just action -> do
      waiting <- answered "dispatchDialogResult" (dsRequests dialogState) requestId
      mapM_ ($ action) waiting

-- | FFI import: show a dialog via the C bridge.
foreign import ccall "dialog_show"
  c_dialogShow :: Ptr () -> CInt -> CString -> CString -> CString -> CString -> CString -> IO ()
