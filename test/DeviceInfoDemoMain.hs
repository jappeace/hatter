{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the device-info-demo test app.
--
-- Used by the emulator and simulator device info integration tests.
-- After the platform bridge is initialised (via startMobileApp), retrieves
-- the device information and logs each field.
module Main where

import Data.Text (Text)
import Foreign.Ptr (Ptr)
import Hatter
  ( MobileApp(..)
  , startMobileApp
  , platformLog
  , loggingMobileContext
  , newActionState
  )
import Hatter.AppContext (AppContext)
import Hatter.DeviceInfo (DeviceInfo(..), getDeviceInfo)
import Hatter.Widget (TextConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  actionState <- newActionState

  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> deviceInfoDemoView
    , maActionState = actionState
    }
  platformLog "DeviceInfo demo app registered"

  info <- getDeviceInfo
  platformLog ("DeviceInfo model: " <> diModel info)
  platformLog ("DeviceInfo osVersion: " <> diOsVersion info)
  platformLog ("DeviceInfo screenDensity: " <> diScreenDensity info)
  platformLog ("DeviceInfo screenWidth: " <> diScreenWidth info)
  platformLog ("DeviceInfo screenHeight: " <> diScreenHeight info)

  pure ctxPtr

-- | Displays device info fields in a column.
deviceInfoDemoView :: IO Widget
deviceInfoDemoView = do
  info <- getDeviceInfo
  pure $ column
    [ infoRow "Model" (diModel info)
    , infoRow "OS Version" (diOsVersion info)
    , infoRow "Density" (diScreenDensity info)
    , infoRow "Width" (diScreenWidth info)
    , infoRow "Height" (diScreenHeight info)
    ]

-- | A text widget showing a label-value pair.
infoRow :: Text -> Text -> Widget
infoRow label value =
  Text TextConfig { tcLabel = label <> ": " <> value, tcFontConfig = Nothing }
