{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
-- | Consumer simulation demo app — exercises the crossDeps + extraJniBridge
-- build path with heavy Hackage dependencies matching prrrrrrrrr's profile.
--
-- This reproduces the build configuration used by real consumer apps like
-- prrrrrrrrr, which crashed with SIGSEGV at startup (issue #156).
-- Hatter's own test APKs all use empty crossDeps; this test ensures the
-- consumer build path also produces a working .so under ARM binary translation.
--
-- Dependencies: aeson + servant + servant-client-core + http-types +
-- http-media + case-insensitive + time.  Together these produce a large .so
-- (~130+ MB stripped) that is likely to trigger libndk_translation's
-- HandleNoExec fault on non-executable mmap'd pages from GHC's RTS.
module Main where

import Data.Aeson (encode, ToJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Proxy (Proxy(..))
import Data.Text qualified as Text
import Data.Time (getCurrentTime, UTCTime)
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
-- ToJSON forces aeson's full code path (scientific, vector, attoparsec,
-- hashable, unordered-containers, primitive, etc.)
data ConsumerPayload = ConsumerPayload
  { cpName      :: Text.Text
  , cpValue     :: Int
  , cpTimestamp :: Maybe UTCTime
  } deriving (Generic)

instance ToJSON ConsumerPayload

-- | Servant API type — forces servant's type-level machinery into the .so.
-- This matches prrrrrrrrr's ServantNative pattern.
type ConsumerAPI =
       "exercises" :> Get '[JSON] [ConsumerPayload]
  :<|> "exercises" :> ReqBody '[JSON] ConsumerPayload :> Post '[JSON] ConsumerPayload
  :<|> "exercises" :> Capture "id" Int :> Get '[JSON] ConsumerPayload

-- | Reference the API proxy to ensure servant instances are compiled in.
consumerAPI :: Proxy ConsumerAPI
consumerAPI = Proxy

main :: IO (Ptr AppContext)
main = do
  platformLog "ConsumerSim demo app registered"
  now <- getCurrentTime
  let payload = ConsumerPayload { cpName = "test", cpValue = 42, cpTimestamp = Just now }
      jsonBytes = encode payload
      -- Force servant-client-core into the .so
      _baseUrl = BaseUrl Http "localhost" 8080 ""
      -- Force http-types into the .so
      _statusCode = status200
      _method = methodGet
      -- Force case-insensitive into the .so
      _ciHeader = CI.mk ("Content-Type" :: BS.ByteString)
      -- Force http-media into the .so
      _mediaType = "application" // "json"
      -- Reference servant API proxy to pull in type class instances
      _ = consumerAPI
  platformLog ("aeson sanity: " <> Text.pack (show (BSL.length jsonBytes)) <> " bytes")
  platformLog ("timestamp: " <> Text.pack (show now))
  actionState <- newActionState
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> pure (Text TextConfig { tcLabel = "Consumer sim", tcFontConfig = Nothing })
    , maActionState = actionState
    }
