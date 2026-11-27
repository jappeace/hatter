{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Bottom sheet / action menu API for mobile platforms.
--
-- Provides an imperative API for showing platform-native bottom sheets
-- (Android BottomSheetDialog, iOS UISheetPresentationController,
-- watchOS .confirmationDialog).
-- Bottom sheets are fire-and-forget: the platform manages the sheet lifecycle
-- independently of the Haskell UI rendering loop.
--
-- Results come back by request number, as for the other platform
-- requests ("Hatter.Requests").
module Hatter.BottomSheet
  ( BottomSheetAction(..)
  , BottomSheetConfig(..)
  , BottomSheetState(..)
  , newBottomSheetState
  , bottomSheetActionFromInt
  , showBottomSheet
  , dispatchBottomSheetResult
  )
where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as Text
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import Hatter.Marshal (withText)
import Hatter.Requests (Requests, answered, newRequests, request)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt

-- | Result of a bottom sheet interaction.
data BottomSheetAction
  = BottomSheetItemSelected Int32  -- ^ 0-based index of the selected item
  | BottomSheetDismissed           -- ^ The user dismissed the sheet without selecting
  deriving (Show, Eq)

-- | Configuration for a bottom sheet.
data BottomSheetConfig = BottomSheetConfig
  { bscTitle :: Text       -- ^ Sheet title
  , bscItems :: [Text]     -- ^ Selectable item labels, each on one line
  }

-- | What waits for the platform's bottom sheet requests.
data BottomSheetState = BottomSheetState
  { bssRequests   :: Requests (BottomSheetAction -> IO ())
    -- ^ What waits for each request's result.
  , bssContextPtr :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'BottomSheetState' with no pending callbacks.
-- The context pointer is initially null and must be set via
-- 'bssContextPtr' before calling 'showBottomSheet'.
newBottomSheetState :: IO BottomSheetState
newBottomSheetState = do
  requests   <- newRequests
  contextPtr <- newIORef nullPtr
  pure BottomSheetState
    { bssRequests   = requests
    , bssContextPtr = contextPtr
    }

-- | Convert a C bridge action code to 'BottomSheetAction'.
-- @-1@ is dismissed, @>= 0@ is item index.
-- Returns 'Nothing' for codes @< -1@.
bottomSheetActionFromInt :: CInt -> Maybe BottomSheetAction
bottomSheetActionFromInt (-1) = Just BottomSheetDismissed
bottomSheetActionFromInt code
  | code >= 0 = Just (BottomSheetItemSelected (CInt.toInt32 code))
  | otherwise = Nothing

-- | Show a bottom sheet with the given configuration.  Registers
-- @callback@ and calls the C bridge.  The callback fires when the
-- user taps an item or dismisses the sheet (or synchronously on
-- desktop via the stub that auto-selects the first item).
showBottomSheet :: BottomSheetState -> BottomSheetConfig -> (BottomSheetAction -> IO ()) -> IO ()
showBottomSheet bottomSheetState config callback = do
  requestId <- request (bssRequests bottomSheetState) callback
  ctx <- readIORef (bssContextPtr bottomSheetState)
  -- The platforms split the items at newlines.
  let joinedItems = Text.intercalate "\n" (map (Text.replace "\n" " ") (bscItems config))
  withText (bscTitle config) $ \cTitle ->
    withText joinedItems $ \cItems ->
      c_bottomSheetShow ctx requestId cTitle cItems

-- | Dispatch a bottom sheet result from the platform back to the
-- registered Haskell callback.  Removes the callback after firing.
-- Unknown request IDs or action codes are silently logged to stderr.
dispatchBottomSheetResult :: BottomSheetState -> CInt -> CInt -> IO ()
dispatchBottomSheetResult bottomSheetState requestId actionCode =
  case bottomSheetActionFromInt actionCode of
    Nothing -> hPutStrLn stderr $
      "dispatchBottomSheetResult: unknown action code " ++ show actionCode
    Just action -> do
      waiting <- answered "dispatchBottomSheetResult" (bssRequests bottomSheetState) requestId
      mapM_ ($ action) waiting

-- | FFI import: show a bottom sheet via the C bridge.
foreign import ccall "bottom_sheet_show"
  c_bottomSheetShow :: Ptr () -> CInt -> CString -> CString -> IO ()
