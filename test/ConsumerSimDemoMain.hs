{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
-- | Consumer simulation demo app — replicates prrrrrrrrr's exact startup
-- behavior to reproduce the libndk_translation SIGSEGV (issue #156).
--
-- This is NOT a minimal test.  It deliberately mimics the patterns that
-- stress the ARM binary translation layer:
--
--   1. Real JNI string marshaling at startup (setFilesDir via storage_helper.c)
--   2. unsafePerformIO globals — lazy init during first render cycle
--   3. forkIO thread spawning at startup
--   4. FFI into cross-compiled sqlite3.c via direct-sqlite
--   5. Disk I/O (sqlite on the Android filesystem, not :memory:)
--   6. IORef mutations during render callbacks
--
-- Any of these could be the trigger for HandleNoExec in libndk_translation:
-- GHC RTS signal handler conflicts, adjustor thunks from libffi, or
-- translated C code encountering non-executable mmap'd pages.
module Main where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, catch)
import Data.Aeson (encode, ToJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy(..))
import Data.Text qualified as Text
import Data.Time (getCurrentTime, UTCTime)
import Database.SQLite.Simple (open, close, execute_, execute, query_, Only(..))
import Foreign.C.String (CString, peekCString)
import Foreign.Ptr (Ptr)
import GHC.Generics (Generic)
import Hatter
  ( MobileApp(..)
  , ActionState
  , startMobileApp
  , platformLog
  , newActionState
  , runActionM
  , createAction
  )
import Hatter.AppContext (AppContext)
import Hatter.Lifecycle (MobileContext(..), LifecycleEvent(..), platformLog)
import Hatter.Types (UserState(..))
import Hatter.Widget (Widget(..), TextConfig(..))
import Network.HTTP.Types (status200, methodGet)
import Network.HTTP.Media ((//))
import Servant.API ((:>), (:<|>), Get, Post, ReqBody, JSON, Capture)
import Servant.Client.Core (BaseUrl(..), Scheme(..))
import System.IO.Unsafe (unsafePerformIO)

-- --------------------------------------------------------------------------
-- FFI into storage_helper.c (same as prrrrrrrrr)
-- --------------------------------------------------------------------------

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | Get the database file path (same pattern as prrrrrrrrr's Storage.hs).
getDbPath :: IO FilePath
getDbPath = do
  dir <- c_get_app_files_dir >>= peekCString
  pure (dir ++ "/consumer_sim.db")

-- --------------------------------------------------------------------------
-- Payload types (force aeson + servant into the .so)
-- --------------------------------------------------------------------------

data ConsumerPayload = ConsumerPayload
  { cpName      :: Text.Text
  , cpValue     :: Int
  , cpTimestamp :: Maybe UTCTime
  } deriving (Generic)

instance ToJSON ConsumerPayload

type ConsumerAPI =
       "exercises" :> Get '[JSON] [ConsumerPayload]
  :<|> "exercises" :> ReqBody '[JSON] ConsumerPayload :> Post '[JSON] ConsumerPayload
  :<|> "exercises" :> Capture "id" Int :> Get '[JSON] ConsumerPayload

consumerAPI :: Proxy ConsumerAPI
consumerAPI = Proxy

-- --------------------------------------------------------------------------
-- Global state via unsafePerformIO (same pattern as prrrrrrrrr's App.hs)
-- --------------------------------------------------------------------------

-- | Mutable counter, lazily initialized on first render.
-- This forces the GHC RTS to evaluate the thunk inside the JNI render
-- callback, which is the exact context where prrrrrrrrr crashes.
data SimState = SimState
  { ssRecordCount :: IORef Int
  , ssDbPath      :: IORef FilePath
  }

-- | Global state — opens SQLite on the filesystem, creates tables, inserts
-- a test row. Evaluated lazily via unsafePerformIO on first access (during
-- the first render cycle, inside the JNI callback).
globalSimState :: SimState
globalSimState = unsafePerformIO $ do
  platformLog "ConsumerSim: initializing global state (unsafePerformIO)"
  dbPath <- getDbPath
  conn <- open dbPath
  execute_ conn "CREATE TABLE IF NOT EXISTS sim_data (id INTEGER PRIMARY KEY, name TEXT, value REAL)"
  execute conn "INSERT INTO sim_data (name, value) VALUES (?, ?)"
    ("startup_check" :: Text.Text, 42.0 :: Double)
  rows <- query_ conn "SELECT COUNT(*) FROM sim_data" :: IO [Only Int]
  close conn
  let recordCount = case rows of
        [Only count] -> count
        _            -> 0
  platformLog ("ConsumerSim: DB initialized, " <> Text.pack (show recordCount) <> " rows")
  countRef <- newIORef recordCount
  pathRef <- newIORef dbPath
  pure SimState { ssRecordCount = countRef, ssDbPath = pathRef }
{-# NOINLINE globalSimState #-}

-- | Global action state (same pattern as prrrrrrrrr).
globalActionState :: ActionState
globalActionState = unsafePerformIO newActionState
{-# NOINLINE globalActionState #-}

-- --------------------------------------------------------------------------
-- Background thread (same pattern as prrrrrrrrr's triggerSync)
-- --------------------------------------------------------------------------

-- | Spawn a background thread that does SQLite I/O, mimicking prrrrrrrrr's
-- sync behavior.  This exercises forkIO + GHC RTS thread management under
-- the binary translation layer.
triggerBackgroundWork :: SimState -> IO ()
triggerBackgroundWork simState = do
  _ <- forkIO $
    backgroundAction simState
      `catch` \(exc :: SomeException) ->
        platformLog ("ConsumerSim background error: " <> Text.pack (show exc))
  pure ()

backgroundAction :: SimState -> IO ()
backgroundAction simState = do
  dbPath <- readIORef (ssDbPath simState)
  conn <- open dbPath
  now <- getCurrentTime
  execute conn "INSERT INTO sim_data (name, value) VALUES (?, ?)"
    ("background_" <> Text.pack (show now), 1.0 :: Double)
  rows <- query_ conn "SELECT COUNT(*) FROM sim_data" :: IO [Only Int]
  close conn
  case rows of
    [Only count] -> do
      writeIORef (ssRecordCount simState) count
      platformLog ("ConsumerSim: background work done, " <> Text.pack (show count) <> " rows")
    _ -> pure ()

-- --------------------------------------------------------------------------
-- Entry point
-- --------------------------------------------------------------------------

main :: IO (Ptr AppContext)
main = do
  platformLog "ConsumerSim demo app registered"

  -- Force aeson + servant deps into the .so
  now <- getCurrentTime
  let payload = ConsumerPayload { cpName = "test", cpValue = 42, cpTimestamp = Just now }
      jsonBytes = encode payload
      _baseUrl = BaseUrl Http "localhost" 8080 ""
      _statusCode = status200
      _method = methodGet
      _ciHeader = CI.mk ("Content-Type" :: BS.ByteString)
      _mediaType = "application" // "json"
      _ = consumerAPI
  platformLog ("aeson sanity: " <> Text.pack (show (BSL.length jsonBytes)) <> " bytes")

  startMobileApp MobileApp
    { maContext = MobileContext
        { onLifecycle = \event -> do
            platformLog ("ConsumerSim lifecycle: " <> Text.pack (show event))
            case event of
              Create -> pure ()
              Resume -> triggerBackgroundWork globalSimState
              Start  -> pure ()
              Pause  -> pure ()
              Stop   -> pure ()
              Destroy -> pure ()
              LowMemory -> pure ()
        , onError = \exc ->
            platformLog ("ConsumerSim error: " <> Text.pack (show exc))
        }
    , maView = \_userState -> do
        -- Force lazy evaluation of globalSimState during render
        -- (same as prrrrrrrrr evaluating globalState in maView)
        count <- readIORef (ssRecordCount globalSimState)
        -- Trigger background thread on first render
        triggerBackgroundWork globalSimState
        pure (Text TextConfig
          { tcLabel = "Consumer sim: " <> Text.pack (show count) <> " rows"
          , tcFontConfig = Nothing
          })
    , maActionState = globalActionState
    }
