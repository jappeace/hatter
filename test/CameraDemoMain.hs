{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.ByteString qualified as BS
import Data.Text (pack)
import Foreign.Ptr (Ptr)
import HaskellMobile
  ( MobileApp(..)
  , UserState(..)
  , startMobileApp
  , platformLog
  , startCameraSession
  , stopCameraSession
  , capturePhoto
  , startVideoCapture
  , stopVideoCapture
  , loggingMobileContext
  , AppContext
  , Picture(..)
  )
import HaskellMobile.Camera (CameraSource(..), CameraResult(..), CameraStatus(..))
import HaskellMobile.Widget (ButtonConfig(..), TextConfig(..), Widget(..))

main :: IO (Ptr AppContext)
main = do
  platformLog "Camera demo app registered"
  startMobileApp cameraDemoApp

cameraDemoApp :: MobileApp
cameraDemoApp = MobileApp
  { maContext = loggingMobileContext
  , maView    = cameraDemoView
  }

cameraDemoView :: UserState -> IO Widget
cameraDemoView userState = pure $ Column
  [ Text TextConfig { tcLabel = "Camera Demo", tcFontConfig = Nothing }
  , Button ButtonConfig
      { bcLabel = "Start Camera"
      , bcAction = do
          startCameraSession (userCameraState userState) CameraBack
          platformLog "Camera session started (back)"
      , bcFontConfig = Nothing
      }
  , Button ButtonConfig
      { bcLabel = "Capture Photo"
      , bcAction = do
          capturePhoto (userCameraState userState) $ \result ->
            case crStatus result of
              CameraSuccess -> do
                platformLog ("Photo captured: " <> maybe "no path" id (crFilePath result))
                case crPicture result of
                  Just pic ->
                    platformLog ("Picture: " <> pack (show (pictureWidth pic))
                      <> "x" <> pack (show (pictureHeight pic))
                      <> " (" <> pack (show (BS.length (pictureData pic))) <> " bytes)")
                  Nothing ->
                    platformLog "No picture data"
              CameraCancelled ->
                platformLog "Photo capture cancelled"
              CameraPermissionDenied ->
                platformLog "Camera permission denied"
              CameraUnavailable ->
                platformLog "Camera unavailable"
              CameraError ->
                platformLog "Photo capture error"
          platformLog "Photo capture requested"
      , bcFontConfig = Nothing
      }
  , Button ButtonConfig
      { bcLabel = "Start Video"
      , bcAction = do
          startVideoCapture (userCameraState userState)
            (\frame -> platformLog ("Video frame: " <> pack (show (pictureWidth frame))
              <> "x" <> pack (show (pictureHeight frame))
              <> " (" <> pack (show (BS.length (pictureData frame))) <> " bytes)"))
            (\chunk -> platformLog ("Audio chunk: " <> pack (show (BS.length chunk)) <> " bytes"))
            (\result ->
              case crStatus result of
                CameraSuccess ->
                  platformLog ("Video captured: " <> maybe "no path" id (crFilePath result))
                CameraCancelled ->
                  platformLog "Video capture cancelled"
                CameraPermissionDenied ->
                  platformLog "Camera permission denied"
                CameraUnavailable ->
                  platformLog "Camera unavailable"
                CameraError ->
                  platformLog "Video capture error")
          platformLog "Video recording started"
      , bcFontConfig = Nothing
      }
  , Button ButtonConfig
      { bcLabel = "Stop Video"
      , bcAction = do
          stopVideoCapture (userCameraState userState)
          platformLog "Video recording stopped"
      , bcFontConfig = Nothing
      }
  , Button ButtonConfig
      { bcLabel = "Stop Camera"
      , bcAction = do
          stopCameraSession (userCameraState userState)
          platformLog "Camera session stopped"
      , bcFontConfig = Nothing
      }
  ]
