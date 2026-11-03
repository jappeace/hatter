{-# LANGUAGE ForeignFunctionInterface #-}
-- | The video of a call: the camera's frames, upright, and frames drawn
-- into the images whose source is an 'Hatter.Widget.ImageStream'.  Any
-- thread may call these.  One camera at a time.
--
-- Frames are I420: the Y plane, then U and V at half the width and height.
--
-- Without a platform's implementation, the camera's start and stop are
-- logged, no frames come, and frames shown are dropped.
module Hatter.CallVideo
  ( VideoFrame(..)
  , CallCamera
  , startCallCamera
  , stopCallCamera
  , showVideoFrame
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BS
import Data.Text (Text)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (FunPtr, Ptr, castPtr, freeHaskellFunPtr)
import Hatter.Marshal (withText)

data VideoFrame = VideoFrame
  { frameWidth  :: Int
  , frameHeight :: Int
  , frameI420   :: ByteString
  } deriving (Show, Eq)

-- | Passing frames on, until stopped.
newtype CallCamera = CallCamera (FunPtr FrameCallback)

type FrameCallback = Ptr Word8 -> CInt -> CInt -> CInt -> IO ()

foreign import ccall "wrapper"
  c_frameCallback :: FrameCallback -> IO (FunPtr FrameCallback)

foreign import ccall safe "call_video_camera_start"
  c_cameraStart :: CInt -> FunPtr FrameCallback -> IO ()

foreign import ccall safe "call_video_camera_stop"
  c_cameraStop :: IO ()

foreign import ccall safe "call_video_show"
  c_show :: CString -> CInt -> CInt -> Ptr Word8 -> CInt -> IO ()

-- | The front camera's frames, or the back one's, each passed to the
-- function on the platform's camera thread.
startCallCamera :: Bool -> (VideoFrame -> IO ()) -> IO CallCamera
startCallCamera front onFrame = do
  callback <- c_frameCallback $ \bytes len width height -> do
    i420 <- BS.packCStringLen (castPtr bytes, fromIntegral len)
    onFrame (VideoFrame (fromIntegral width) (fromIntegral height) i420)
  c_cameraStart (if front then 1 else 0) callback
  pure (CallCamera callback)

-- | Returns once the frame function is no longer called.
stopCallCamera :: CallCamera -> IO ()
stopCallCamera (CallCamera callback) = do
  c_cameraStop
  freeHaskellFunPtr callback

-- | Draw the frame into the images that show the stream with the key.
showVideoFrame :: Text -> VideoFrame -> IO ()
showVideoFrame key frame =
  withText key $ \ckey ->
  BS.unsafeUseAsCStringLen (frameI420 frame) $ \(bytes, len) ->
    c_show ckey (fromIntegral (frameWidth frame)) (fromIntegral (frameHeight frame)) (castPtr bytes) (fromIntegral len)
