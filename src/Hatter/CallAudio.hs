{-# LANGUAGE ForeignFunctionInterface #-}
-- | The audio of a call: the microphone in frames, and the other side's
-- audio played, both in the platform's voice call mode, with its echo
-- cancellation.  Any thread may call these, also while no screen is open.
-- One call's audio at a time.  A headset that connects takes the call, and
-- the screen goes dark near the ear while the earpiece plays it.
--
-- Samples are 16-bit, in the platform's byte order.
--
-- Without a platform's implementation, starting and stopping are logged,
-- no frames come, and what is played is dropped.
module Hatter.CallAudio
  ( CallAudio
  , startCallAudio
  , stopCallAudio
  , playCallAudio
  , callAudioLatency
  , CallRoute (..)
  , setCallRoute
  , CallTone (..)
  , setCallTone
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BS
import Data.Bits (testBit)
import Data.Int (Int16)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (FunPtr, Ptr, castPtr, freeHaskellFunPtr)

-- | Recording and playing, until stopped.
data CallAudio = CallAudio (FunPtr FrameCallback) (FunPtr RoutesCallback)

type FrameCallback = Ptr Int16 -> CInt -> IO ()

type RoutesCallback = CInt -> CInt -> IO ()

foreign import ccall "wrapper"
  c_frameCallback :: FrameCallback -> IO (FunPtr FrameCallback)

foreign import ccall "wrapper"
  c_routesCallback :: RoutesCallback -> IO (FunPtr RoutesCallback)

foreign import ccall safe "call_audio_start"
  c_callAudioStart :: CInt -> CInt -> CInt -> FunPtr FrameCallback -> FunPtr RoutesCallback -> IO ()

foreign import ccall safe "call_audio_stop"
  c_callAudioStop :: IO ()

foreign import ccall safe "call_audio_play"
  c_callAudioPlay :: CInt -> CInt -> Ptr Int16 -> CInt -> IO CInt

foreign import ccall safe "call_audio_latency"
  c_callAudioLatency :: IO CInt

foreign import ccall safe "call_audio_route"
  c_callAudioRoute :: CInt -> IO ()

foreign import ccall safe "call_audio_tone"
  c_callAudioTone :: CInt -> IO ()

-- | What the phone plays outside a call's audio.
data CallTone
  = Quiet
  | Ringtone
    -- ^ A call coming in: the user's ringtone, looping, with vibration
    -- unless the phone is silent.
  | Ringback
    -- ^ A call going out, while the friend's phone rings.
  deriving (Show, Eq)

-- | Play a tone instead of the one before.
setCallTone :: CallTone -> IO ()
setCallTone tone = c_callAudioTone $ case tone of
  Quiet    -> 0
  Ringtone -> 1
  Ringback -> 2

-- | Where a call's audio goes.
data CallRoute = Earpiece | Speaker | Wired | Bluetooth
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Record mono frames of so many samples at the sampling rate, each
-- passed to the first function on the platform's recording thread.  The
-- audio goes to a headset if there is one, else to the loudspeaker if
-- asked, else to the earpiece.  The second function hears of the route
-- the audio takes and those there are, whenever they change, on any
-- thread, also before this returns and during 'setCallRoute': it must not
-- wait for what their callers hold.
startCallAudio :: Int -> Int -> Bool -> (ByteString -> IO ()) -> (CallRoute -> [CallRoute] -> IO ()) -> IO CallAudio
startCallAudio rate samples speaker onFrame onRoutes = do
  frames <- c_frameCallback $ \pcm count ->
    BS.packCStringLen (castPtr pcm, fromIntegral count * 2) >>= onFrame
  routes <- c_routesCallback $ \route available ->
    onRoutes (toEnum (fromIntegral route)) [r | r <- [minBound ..], testBit available (fromEnum r)]
  c_callAudioStart (fromIntegral rate) (fromIntegral samples) (if speaker then 1 else 0) frames routes
  pure (CallAudio frames routes)

-- | Returns once neither function is called any more.
stopCallAudio :: CallAudio -> IO ()
stopCallAudio (CallAudio frames routes) = do
  c_callAudioStop
  freeHaskellFunPtr frames
  freeHaskellFunPtr routes

-- | Play interleaved samples at the sampling rate with so many channels, as
-- they come. Returns the milliseconds of audio waiting to be played, these
-- included (0 where the platform doesn't say).
playCallAudio :: Int -> Int -> ByteString -> IO Int
playCallAudio rate channels pcm = BS.unsafeUseAsCStringLen pcm $ \(bytes, len) ->
  fromIntegral <$> c_callAudioPlay (fromIntegral rate) (fromIntegral channels) (castPtr bytes) (fromIntegral (len `div` 2))

-- | How long after it's played audio is heard, in milliseconds (0 until
-- the platform knows, or where it doesn't say).
callAudioLatency :: IO Int
callAudioLatency = fromIntegral <$> c_callAudioLatency

-- | The route the user chooses, kept while it is there and until a
-- headset connects.
setCallRoute :: CallRoute -> IO ()
setCallRoute = c_callAudioRoute . fromIntegral . fromEnum
