{-# LANGUAGE ForeignFunctionInterface #-}
module HaskellMobile.Lifecycle
  ( LifecycleEvent(..)
  , lifecycleFromInt
  , lifecycleToInt
  , setLifecycleCallback
  , haskellOnLifecycle
  )
where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Foreign.C.Types (CInt(..))
import System.IO.Unsafe (unsafePerformIO)

-- | Lifecycle events that can be received from the host platform.
-- Maps to Android Activity lifecycle and iOS ScenePhase transitions.
data LifecycleEvent
  = Create
  | Start
  | Resume
  | Pause
  | Stop
  | Destroy
  | LowMemory
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Convert a C int to a 'LifecycleEvent'. Returns 'Nothing' for unknown codes.
lifecycleFromInt :: CInt -> Maybe LifecycleEvent
lifecycleFromInt 0 = Just Create
lifecycleFromInt 1 = Just Start
lifecycleFromInt 2 = Just Resume
lifecycleFromInt 3 = Just Pause
lifecycleFromInt 4 = Just Stop
lifecycleFromInt 5 = Just Destroy
lifecycleFromInt 6 = Just LowMemory
lifecycleFromInt _ = Nothing

-- | Convert a 'LifecycleEvent' to its C int code (0--6).
lifecycleToInt :: LifecycleEvent -> CInt
lifecycleToInt Create    = 0
lifecycleToInt Start     = 1
lifecycleToInt Resume    = 2
lifecycleToInt Pause     = 3
lifecycleToInt Stop      = 4
lifecycleToInt Destroy   = 5
lifecycleToInt LowMemory = 6

-- | Global mutable callback for lifecycle events.
lifecycleCallbackRef :: IORef (LifecycleEvent -> IO ())
lifecycleCallbackRef = unsafePerformIO $ newIORef defaultLifecycleCallback
{-# NOINLINE lifecycleCallbackRef #-}

-- | Default callback that prints the event to stdout.
defaultLifecycleCallback :: LifecycleEvent -> IO ()
defaultLifecycleCallback event = putStrLn $ "Lifecycle event: " ++ show event

-- | Register a callback to be invoked on lifecycle events.
-- Replaces any previously registered callback.
setLifecycleCallback :: (LifecycleEvent -> IO ()) -> IO ()
setLifecycleCallback = writeIORef lifecycleCallbackRef

-- | FFI entry point called from platform code.
-- Dispatches to the registered callback. Unknown event codes are silently ignored.
haskellOnLifecycle :: CInt -> IO ()
haskellOnLifecycle code =
  case lifecycleFromInt code of
    Just event -> do
      callback <- readIORef lifecycleCallbackRef
      callback event
    Nothing -> pure ()

foreign export ccall haskellOnLifecycle :: CInt -> IO ()
