{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
-- | Camera capture API for mobile platforms.
--
-- Provides session management (start\/stop), photo capture, and video
-- recording with results delivered via callbacks.
-- On desktop (no platform bridge registered) the C stub dispatches
-- dummy results so that @cabal test@ exercises the callback path
-- without native code.
--
-- Photo captures deliver raw image bytes as a 'Picture'.
-- Video recording supports per-frame and per-audio-chunk
-- push callbacks that mirror the native Camera2\/AVFoundation model.
--
-- The camera session is owned by 'CameraState', not by the CameraView
-- widget.  The widget is a preview target — the active session attaches
-- its preview when the native renderer creates the view.
module Hatter.Camera
  ( CameraSource(..)
  , CameraStatus(..)
  , Picture(..)
  , CameraResult(..)
  , CameraRequest(..)
  , CameraState(..)
  , newCameraState
  , cameraSourceToInt
  , cameraStatusFromInt
  , startCameraSession
  , stopCameraSession
  , capturePhoto
  , startVideoCapture
  , stopVideoCapture
  , dispatchCameraResult
  , dispatchVideoFrame
  , dispatchAudioChunk
  )
where

import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Int (Int32)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import Hatter.Requests (Requests, answered, answering, newRequests, request)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt
import Unwitch.Convert.Int32 qualified as Int32

-- | Which camera to use.
data CameraSource
  = CameraBack   -- ^ Rear-facing camera.
  | CameraFront  -- ^ Front-facing (selfie) camera.
  deriving (Show, Eq)

-- | Outcome of a camera capture operation.
data CameraStatus
  = CameraSuccess          -- ^ Capture completed successfully.
  | CameraCancelled        -- ^ User cancelled the capture.
  | CameraPermissionDenied -- ^ Camera permission was denied.
  | CameraUnavailable      -- ^ Camera hardware is not available.
  | CameraError            -- ^ An unspecified error occurred.
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Raw image data from a photo capture or video frame.
data Picture = Picture
  { pictureWidth  :: Int
    -- ^ Image width in pixels.
  , pictureHeight :: Int
    -- ^ Image height in pixels.
  , pictureData   :: ByteString
    -- ^ JPEG-encoded image bytes.
  } deriving (Show, Eq)

-- | Result delivered to a capture callback.
data CameraResult = CameraResult
  { crStatus   :: CameraStatus
  , crPicture  :: Maybe Picture
    -- ^ Raw image data for photo captures, or 'Nothing' for video
    -- results and error results.
  } deriving (Show, Eq)

-- | What waits for a capture: its result, and a video's frames and sound
-- while it records.
data CameraRequest = CameraRequest
  { crqResult :: CameraResult -> IO ()
  , crqFrame  :: Picture -> IO ()
  , crqAudio  :: ByteString -> IO ()
  }

-- | What waits for the platform's camera.
data CameraState = CameraState
  { csRequests   :: Requests CameraRequest
    -- ^ What waits for each capture.
  , csContextPtr :: IORef (Ptr ())
    -- ^ Opaque context pointer passed to the C bridge.
    -- Set by 'AppContext.newAppContext' after the 'StablePtr' is created.
  }

-- | Create a fresh 'CameraState' with no pending callbacks.
-- The context pointer is initially null and must be set via
-- 'csContextPtr' before calling any camera operation.
newCameraState :: IO CameraState
newCameraState = CameraState <$> newRequests <*> newIORef nullPtr

-- | Convert a 'CameraSource' to its C integer code.
cameraSourceToInt :: CameraSource -> Int32
cameraSourceToInt CameraBack  = 0
cameraSourceToInt CameraFront = 1

-- | Convert a C bridge status code to 'CameraStatus'.
-- Returns 'Nothing' for unknown codes.
cameraStatusFromInt :: CInt -> Maybe CameraStatus
cameraStatusFromInt 0 = Just CameraSuccess
cameraStatusFromInt 1 = Just CameraCancelled
cameraStatusFromInt 2 = Just CameraPermissionDenied
cameraStatusFromInt 3 = Just CameraUnavailable
cameraStatusFromInt 4 = Just CameraError
cameraStatusFromInt _ = Nothing

-- | Start a camera session for the given source.
-- The session provides a live preview that the CameraView widget can display.
startCameraSession :: CameraState -> CameraSource -> IO ()
startCameraSession cameraState source = do
  ctx <- readIORef (csContextPtr cameraState)
  c_cameraStartSession ctx (Int32.toCInt (cameraSourceToInt source))

-- | Stop the active camera session.
-- Safe to call when no session is active (no-op).
stopCameraSession :: CameraState -> IO ()
stopCameraSession _cameraState =
  c_cameraStopSession

-- | Capture a photo. Registers the callback and calls the C bridge.
-- The callback fires when the platform responds (or synchronously on
-- desktop via the stub).
capturePhoto :: CameraState -> (CameraResult -> IO ()) -> IO ()
capturePhoto cameraState callback = do
  requestId <- request (csRequests cameraState)
    CameraRequest { crqResult = callback, crqFrame = \_ -> pure (), crqAudio = \_ -> pure () }
  ctx <- readIORef (csContextPtr cameraState)
  c_cameraCapturePhoto ctx requestId

-- | Start recording video.  Registers three callbacks:
--
--   * A per-frame callback fired for each video frame ('Picture').
--   * A per-audio-chunk callback fired for each PCM audio chunk ('ByteString').
--   * A completion callback fired when recording stops ('CameraResult').
--
-- The frame and audio callbacks are removed when recording stops.
startVideoCapture :: CameraState
                  -> (Picture -> IO ())        -- ^ Called per video frame.
                  -> (ByteString -> IO ())     -- ^ Called per audio chunk.
                  -> (CameraResult -> IO ())   -- ^ Called when recording stops.
                  -> IO ()
startVideoCapture cameraState frameCallback audioCallback completionCallback = do
  requestId <- request (csRequests cameraState)
    CameraRequest { crqResult = completionCallback, crqFrame = frameCallback, crqAudio = audioCallback }
  ctx <- readIORef (csContextPtr cameraState)
  c_cameraStartVideo ctx requestId

-- | Stop recording video. The callback registered by 'startVideoCapture'
-- will be fired with a completion result.
-- Safe to call when not recording (no-op).
stopVideoCapture :: CameraState -> IO ()
stopVideoCapture _cameraState =
  c_cameraStopVideo

-- | Dispatch a camera result from the platform back to the registered
-- Haskell callback.  Removes the result callback (and any associated
-- frame\/audio callbacks) after firing.
-- Unknown request IDs or status codes are silently logged to stderr.
dispatchCameraResult :: CameraState -> CInt -> CInt
                     -> Maybe ByteString -> CInt -> CInt
                     -> IO ()
dispatchCameraResult cameraState requestId statusCode
                     maybeImageData imageWidth imageHeight =
  case cameraStatusFromInt statusCode of
    Nothing -> hPutStrLn stderr $
      "dispatchCameraResult: unknown status code " ++ show statusCode
    Just status -> do
      let maybePicture = case status of
            CameraSuccess -> case maybeImageData of
              Just imageBytes -> Just Picture
                { pictureWidth  = CInt.toInt imageWidth
                , pictureHeight = CInt.toInt imageHeight
                , pictureData   = imageBytes
                }
              Nothing -> Nothing
            _ -> Nothing
          result = CameraResult
            { crStatus   = status
            , crPicture  = maybePicture
            }
      waiting <- answered "dispatchCameraResult" (csRequests cameraState) requestId
      mapM_ (\capture -> crqResult capture result) waiting

-- | Dispatch a video frame from the platform to the registered frame
-- callback.  Does not remove the callback — it stays active until
-- recording stops.
dispatchVideoFrame :: CameraState -> CInt -> ByteString -> CInt -> CInt -> IO ()
dispatchVideoFrame cameraState requestId frameBytes frameWidth frameHeight = do
  let picture = Picture
        { pictureWidth  = CInt.toInt frameWidth
        , pictureHeight = CInt.toInt frameHeight
        , pictureData   = frameBytes
        }
  waiting <- answering "dispatchVideoFrame" (csRequests cameraState) requestId
  mapM_ (\capture -> crqFrame capture picture) waiting

-- | Dispatch an audio chunk from the platform to the registered audio
-- callback.  Does not remove the callback — it stays active until
-- recording stops.
dispatchAudioChunk :: CameraState -> CInt -> ByteString -> IO ()
dispatchAudioChunk cameraState requestId audioBytes = do
  waiting <- answering "dispatchAudioChunk" (csRequests cameraState) requestId
  mapM_ (\capture -> crqAudio capture audioBytes) waiting

-- | FFI import: start a camera session via the C bridge.
foreign import ccall "camera_start_session"
  c_cameraStartSession :: Ptr () -> CInt -> IO ()

-- | FFI import: stop the camera session via the C bridge.
foreign import ccall "camera_stop_session"
  c_cameraStopSession :: IO ()

-- | FFI import: capture a photo via the C bridge.
foreign import ccall "camera_capture_photo"
  c_cameraCapturePhoto :: Ptr () -> CInt -> IO ()

-- | FFI import: start video recording via the C bridge.
foreign import ccall "camera_start_video"
  c_cameraStartVideo :: Ptr () -> CInt -> IO ()

-- | FFI import: stop video recording via the C bridge.
foreign import ccall "camera_stop_video"
  c_cameraStopVideo :: IO ()
