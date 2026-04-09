{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the BLE-demo test app.
--
-- Used by the emulator and simulator BLE integration tests.
-- Starts directly in BLE-demo mode so no runtime switching is needed.
module Main where

import Data.Text (pack)
import Foreign.Ptr (Ptr)
import HaskellMobile
  ( MobileApp(..)
  , UserState(..)
  , BleAdapterStatus(..)
  , startMobileApp
  , platformLog
  , checkBleAdapter
  , startBleScan
  , stopBleScan
  , loggingMobileContext
  , AppContext
  )
import HaskellMobile.Widget (ButtonConfig(..), TextConfig(..), Widget(..))

main :: IO (Ptr AppContext)
main = do
  platformLog "BLE demo app registered"
  startMobileApp bleDemoApp

-- | BLE demo: checks adapter status and provides scan start/stop buttons.
-- Used by integration tests to verify the BLE FFI bridge end-to-end.
bleDemoApp :: MobileApp
bleDemoApp = MobileApp
  { maContext = loggingMobileContext
  , maView    = bleDemoView
  }

-- | Builds a Column with a label, adapter status check, and scan buttons.
bleDemoView :: UserState -> IO Widget
bleDemoView userState = do
  adapterStatus <- checkBleAdapter
  platformLog ("BLE adapter: " <> pack (show adapterStatus))
  pure $ Column
    [ Text TextConfig { tcLabel = "BLE Demo", tcFontConfig = Nothing }
    , Text TextConfig
        { tcLabel = "Adapter: " <> pack (show adapterStatus)
        , tcFontConfig = Nothing
        }
    , Button ButtonConfig
        { bcLabel = "Start Scan"
        , bcAction = do
            startBleScan (userBleState userState) $ \scanResult ->
              platformLog ("BLE scan result: " <> pack (show scanResult))
            platformLog "BLE scan started"
        , bcFontConfig = Nothing
        }
    , Button ButtonConfig
        { bcLabel = "Stop Scan"
        , bcAction = do
            stopBleScan (userBleState userState)
            platformLog "BLE scan stopped"
        , bcFontConfig = Nothing
        }
    ]
