-- | Shared test helpers used across multiple test modules.
module Test.Helpers
  ( withActions
  , withAppContext
  , withContext
  , makeDummyApp
  , makeSimpleApp
  , testApp
  , viewIsErrorWidget
  , oneTwoThree
  , captureStderr
  , inCLocale
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Foreign.Ptr (Ptr)
import GHC.IO.Encoding (getForeignEncoding, mkTextEncoding, setForeignEncoding)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (stderr, hFlush, openTempFile, hClose)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO.Unsafe (unsafePerformIO)
import Hatter
  ( MobileApp(..)
  , UserState(..)
  , ActionM
  , newActionState
  , runActionM
  )
import Hatter.AppContext (AppContext(..), newAppContext, freeAppContext, derefAppContext)
import Hatter.Lifecycle
  ( LifecycleEvent(..)
  , MobileContext(..)
  , defaultMobileContext
  , loggingMobileContext
  )
import Hatter.Animation (newAnimationState)
import Hatter.Widget (LayoutItem(..), LayoutSettings(..), TextConfig(..), Widget(..))
import Hatter.Render (RenderState, newRenderState)

-- | Helper: create an ActionState, register actions via ActionM, and
-- build a RenderState.  Returns the registered value together with the
-- RenderState so tests can dispatch by handle ID.
withActions :: ActionM a -> IO (a, RenderState)
withActions actionM = do
  actionState <- newActionState
  result <- runActionM actionState actionM
  animState <- newAnimationState
  rs <- newRenderState actionState animState
  pure (result, rs)

-- | Helper: create an 'AppContext' from a 'MobileApp',
-- run an action with the typed 'Ptr AppContext', then free the context.
withAppContext :: MobileApp -> (Ptr AppContext -> IO a) -> IO a
withAppContext app action = do
  ptr <- newAppContext app
  result <- action ptr
  freeAppContext ptr
  pure result

-- | Helper: create an 'AppContext' with the given lifecycle callback,
-- run an action with the typed 'Ptr AppContext', then free the context.
withContext :: (LifecycleEvent -> IO ()) -> (Ptr AppContext -> IO a) -> IO a
withContext callback action = do
  dummyApp <- makeDummyApp callback
  withAppContext dummyApp action

-- | Create a dummy MobileApp with the given lifecycle callback.
makeDummyApp :: (LifecycleEvent -> IO ()) -> IO MobileApp
makeDummyApp callback = do
  actionState <- newActionState
  pure MobileApp
    { maContext     = defaultMobileContext { onLifecycle = callback, onError = \_ -> pure () }
    , maView        = \_userState -> pure (Text TextConfig { tcLabel = "dummy", tcFontConfig = Nothing, tcTextColor = Nothing })
    , maActionState = actionState
    }

-- | Helper: make a simple MobileApp with default context.
makeSimpleApp :: (UserState -> IO Widget) -> IO MobileApp
makeSimpleApp viewFn = do
  actionState <- newActionState
  pure MobileApp
    { maContext     = defaultMobileContext
    , maView        = viewFn
    , maActionState = actionState
    }

-- | Trivial test app with loggingMobileContext and a simple Text view.
testApp :: IO MobileApp
testApp = do
  actionState <- newActionState
  pure MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> pure (Text TextConfig { tcLabel = "test", tcFontConfig = Nothing, tcTextColor = Nothing })
    , maActionState = actionState
    }

oneTwoThree :: [Int]
oneTwoThree = [1, 2, 3]

-- | Helper: check whether the context's view function produces an error widget
-- (a Column whose first child is a Text with "An error occurred").
viewIsErrorWidget :: Ptr AppContext -> IO Bool
viewIsErrorWidget ctxPtr = do
  appCtx <- derefAppContext ctxPtr
  viewFn <- readIORef (acViewFunction appCtx)
  let userState = UserState
        { userPermissionState    = acPermissionState appCtx
        , userSecureStorageState = acSecureStorageState appCtx
        , userBleState           = acBleState appCtx
        , userDialogState        = acDialogState appCtx
        , userLocationState      = acLocationState appCtx
        , userAuthSessionState   = acAuthSessionState appCtx
        , userCameraState        = acCameraState appCtx
        , userBottomSheetState   = acBottomSheetState appCtx
        , userHttpState          = acHttpState appCtx
        , userNetworkStatusState = acNetworkStatusState appCtx
        , userAnimationState        = acAnimationState appCtx
        , userPlatformSignInState  = acPlatformSignInState appCtx
        , userRequestRedraw        = pure ()
        }
  widget <- viewFn userState
  case widget of
    Column (LayoutSettings (LayoutItem _ (Text config) : _) _) -> pure (tcLabel config == "An error occurred")
    Column _                 -> pure False
    Text _                   -> pure False
    Button _                 -> pure False
    TextInput _              -> pure False
    Switch _                 -> pure False
    LazyColumn _             -> pure False
    Image _                  -> pure False
    WebView _                -> pure False
    MapView _                -> pure False
    Row _                    -> pure False
    Stack _                  -> pure False
    Styled _ _               -> pure False
    Animated _ _             -> pure False
    Tappable _ _             -> pure False
    LongPressable _ _        -> pure False
    Scrolled _ _ _           -> pure False

-- | Capture stderr output produced during an IO action, as the UTF-8 the
-- bridges' stubs print. One at a time, as each redirects the process's
-- stderr; what other tests write meanwhile is captured too.
captureStderr :: IO a -> IO (a, String)
captureStderr action = withMVar capturing $ \() -> do
  hFlush stderr
  oldStderr <- hDuplicate stderr
  tmpDir <- getTemporaryDirectory
  (tmpPath, tmpHandle) <- openTempFile tmpDir "stderr-capture.txt"
  hDuplicateTo tmpHandle stderr
  -- On macOS a write from another thread fails while dup2 swaps fd 2, and
  -- then C prints nothing more until this.
  c_clearStderrError
  result <- action
  hFlush stderr
  hDuplicateTo oldStderr stderr
  hClose oldStderr
  hClose tmpHandle
  captured <- BS.readFile tmpPath
  removeFile tmpPath
  pure (result, Text.unpack (Text.decodeUtf8Lenient captured))

-- | Run an action with C strings encoded as the C locale has them, ASCII.
inCLocale :: IO a -> IO a
inCLocale action = do
  ascii <- mkTextEncoding "ASCII//ROUNDTRIP"
  bracket getForeignEncoding setForeignEncoding (\_ -> setForeignEncoding ascii >> action)

capturing :: MVar ()
capturing = unsafePerformIO (newMVar ())
{-# NOINLINE capturing #-}

foreign import ccall unsafe "hatter_test_clear_stderr_error" c_clearStderrError :: IO ()
