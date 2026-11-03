-- | Requests to the platform, each waiting by its number for the platform
-- to answer it, as a permission asked for or a dialog shown.
module Hatter.Requests
  ( Requests
  , newRequests
  , request
  , answered
  , answering
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Foreign.C.Types (CInt)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt
import Unwitch.Convert.Int32 qualified as Int32

-- | What waits for the answer to each request, by its number.
data Requests a = Requests
  { rqWaiting :: IORef (IntMap a)
  , rqNext    :: IORef Int32
  }

newRequests :: IO (Requests a)
newRequests = Requests <$> newIORef IntMap.empty <*> newIORef 0

-- | Keep what waits for a new request's answer, giving the request's
-- number for the platform.
request :: Requests a -> a -> IO CInt
request requests waiting = do
  number <- atomicModifyIORef' (rqNext requests) (\next -> (next + 1, next))
  atomicModifyIORef' (rqWaiting requests)
    (\waitingNow -> (IntMap.insert (Int32.toInt number) waiting waitingNow, ()))
  pure (Int32.toCInt number)

-- | What waited for the request with this number, which the platform
-- answered for the last time. An unknown number is logged, under the
-- name of what got it.
answered :: String -> Requests a -> CInt -> IO (Maybe a)
answered who requests number = do
  waiting <- atomicModifyIORef' (rqWaiting requests)
    (\waitingNow -> (IntMap.delete key waitingNow, IntMap.lookup key waitingNow))
  known who number waiting
  where key = CInt.toInt number

-- | What waits for the request with this number, which the platform
-- answers again later, as a video's frames.
answering :: String -> Requests a -> CInt -> IO (Maybe a)
answering who requests number = do
  waiting <- IntMap.lookup (CInt.toInt number) <$> readIORef (rqWaiting requests)
  known who number waiting

known :: String -> CInt -> Maybe a -> IO (Maybe a)
known who number waiting = do
  case waiting of
    Nothing -> hPutStrLn stderr (who <> ": unknown request ID " <> show number)
    Just _ -> pure ()
  pure waiting
