{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the network-status-demo test app.
--
-- Used by the emulator and simulator network status integration tests.
-- Starts directly in network-status-demo mode so no runtime switching
-- is needed.
--
-- The view function is kept pure (no IO / FFI calls) to avoid
-- JNI reentrancy issues on armv7a.  Network status FFI calls run on
-- button press instead.
module Main where

import Data.Text (pack)
import Foreign.Ptr (Ptr)
import HaskellMobile
  ( MobileApp(..)
  , UserState(..)
  , startMobileApp
  , platformLog
  , startNetworkMonitoring
  , stopNetworkMonitoring
  , loggingMobileContext
  , AppContext
  )
import HaskellMobile.NetworkStatus (NetworkStatus(..), NetworkTransport(..))
import HaskellMobile.Widget (ButtonConfig(..), TextConfig(..), Widget(..))

main :: IO (Ptr AppContext)
main = do
  platformLog "Network status demo app registered"
  startMobileApp networkStatusDemoApp

-- | Network status demo: provides start/stop monitoring buttons.
-- Used by integration tests to verify the network status FFI bridge
-- end-to-end.
networkStatusDemoApp :: MobileApp
networkStatusDemoApp = MobileApp
  { maContext = loggingMobileContext
  , maView    = networkStatusDemoView
  }

-- | Builds a Column with a label and start/stop monitoring buttons.
-- The view itself is pure — all network status FFI calls happen in
-- button callbacks to avoid JNI reentrancy issues during rendering.
networkStatusDemoView :: UserState -> IO Widget
networkStatusDemoView userState = pure $ Column
  [ Text TextConfig { tcLabel = "Network Status Demo", tcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Start Monitoring"
      , bcAction = do
          startNetworkMonitoring (userNetworkStatusState userState) $ \networkStatus ->
            platformLog ("Network: connected=" <> pack (show (nsConnected networkStatus))
                        <> " transport=" <> pack (show (nsTransport networkStatus)))
          platformLog "Network monitoring started"
      , bcFontConfig = Nothing
      }
  , Button ButtonConfig
      { bcLabel = "Stop Monitoring"
      , bcAction = do
          stopNetworkMonitoring (userNetworkStatusState userState)
          platformLog "Network monitoring stopped"
      , bcFontConfig = Nothing
      }
  ]
