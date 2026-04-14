{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
-- | Consumer simulation demo app — replicates prrrrrrrrr's exact dependency
-- profile to reproduce the libndk_translation SIGSEGV (issue #156).
--
-- prrrrrrrrr crashed with SIGSEGV at startup under ARM binary translation.
-- Hatter's own test APKs all use empty crossDeps; this test uses the same
-- deps as prrrrrrrrr to trigger the same crash.
--
-- Critical dep: sqlite-simple → direct-sqlite → sqlite3.c amalgamation
-- (~240K lines of C code cross-compiled to ARM).  This native C code is
-- what libndk_translation has to translate, and is the most likely trigger
-- for the HandleNoExec fault.
module Main where

import Data.Aeson (encode, ToJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Proxy (Proxy(..))
import Data.Text qualified as Text
import Data.Time (getCurrentTime, UTCTime)
import Database.SQLite.Simple (open, close, execute_, query_, Only(..))
import Foreign.Ptr (Ptr)
import GHC.Generics (Generic)
import Hatter (MobileApp(..), startMobileApp, platformLog, loggingMobileContext, newActionState)
import Hatter.AppContext (AppContext)
import Hatter.Widget (Widget(..), TextConfig(..))
import Network.HTTP.Types (status200, methodGet)
import Network.HTTP.Media ((//))
import Servant.API ((:>), (:<|>), Get, Post, ReqBody, JSON, Capture)
import Servant.Client.Core (BaseUrl(..), Scheme(..))

-- | Payload type matching prrrrrrrrr's GymTracker.Model style.
data ConsumerPayload = ConsumerPayload
  { cpName      :: Text.Text
  , cpValue     :: Int
  , cpTimestamp :: Maybe UTCTime
  } deriving (Generic)

instance ToJSON ConsumerPayload

-- | Servant API type matching prrrrrrrrr's ServantNative pattern.
type ConsumerAPI =
       "exercises" :> Get '[JSON] [ConsumerPayload]
  :<|> "exercises" :> ReqBody '[JSON] ConsumerPayload :> Post '[JSON] ConsumerPayload
  :<|> "exercises" :> Capture "id" Int :> Get '[JSON] ConsumerPayload

consumerAPI :: Proxy ConsumerAPI
consumerAPI = Proxy

main :: IO (Ptr AppContext)
main = do
  platformLog "ConsumerSim demo app registered"

  -- Exercise sqlite-simple → direct-sqlite → sqlite3.c (the critical dep).
  -- This forces the entire sqlite3 C amalgamation into the .so via
  -- the cross-compiled direct-sqlite package.
  sqliteDb <- open ":memory:"
  execute_ sqliteDb "CREATE TABLE IF NOT EXISTS test_table (id INTEGER PRIMARY KEY, name TEXT)"
  execute_ sqliteDb "INSERT INTO test_table (name) VALUES ('consumer_sim_test')"
  rows <- query_ sqliteDb "SELECT name FROM test_table" :: IO [Only Text.Text]
  close sqliteDb
  platformLog ("sqlite sanity: " <> Text.pack (show (length rows)) <> " rows")

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
  platformLog ("timestamp: " <> Text.pack (show now))
  actionState <- newActionState
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> pure (Text TextConfig { tcLabel = "Consumer sim", tcFontConfig = Nothing })
    , maActionState = actionState
    }
