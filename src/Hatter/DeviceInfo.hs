{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Hatter.DeviceInfo
  ( DeviceInfo(..)
  , getDeviceInfo
  , haskellLogDeviceInfo
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Foreign.C.String (CString, peekCString)
import Hatter.Lifecycle (platformLog)

-- | Device information collected from the host platform.
--
-- All fields are 'Text' — numeric values (density, dimensions) are
-- stored as string representations so the consumer can parse as needed.
data DeviceInfo = DeviceInfo
  { diModel         :: Text  -- ^ Device model name (e.g. @\"Pixel 7\"@, @\"iPhone15,2\"@)
  , diOsVersion     :: Text  -- ^ OS version string (e.g. @\"14\"@, @\"17.0\"@)
  , diScreenDensity :: Text  -- ^ Screen density / scale factor (e.g. @\"2.75\"@, @\"3.0\"@)
  , diScreenWidth   :: Text  -- ^ Screen width in physical pixels (e.g. @\"1080\"@)
  , diScreenHeight  :: Text  -- ^ Screen height in physical pixels (e.g. @\"2400\"@)
  } deriving (Show, Eq)

foreign import ccall "getDeviceModel" c_getDeviceModel :: IO CString
foreign import ccall "getDeviceOsVersion" c_getDeviceOsVersion :: IO CString
foreign import ccall "getDeviceScreenDensity" c_getDeviceScreenDensity :: IO CString
foreign import ccall "getDeviceScreenWidth" c_getDeviceScreenWidth :: IO CString
foreign import ccall "getDeviceScreenHeight" c_getDeviceScreenHeight :: IO CString

-- | Query all device information from the host platform.
--
-- * Android: values set from @Build.MODEL@, @Build.VERSION.RELEASE@, @DisplayMetrics@
-- * iOS: values set from @utsname@, @UIDevice@, @UIScreen@
-- * Desktop: returns fallback values (@\"desktop\"@, @\"unknown\"@, @\"1.0\"@, @\"0\"@, @\"0\"@)
getDeviceInfo :: IO DeviceInfo
getDeviceInfo = do
  model         <- peekText =<< c_getDeviceModel
  osVersion     <- peekText =<< c_getDeviceOsVersion
  screenDensity <- peekText =<< c_getDeviceScreenDensity
  screenWidth   <- peekText =<< c_getDeviceScreenWidth
  screenHeight  <- peekText =<< c_getDeviceScreenHeight
  pure DeviceInfo
    { diModel         = model
    , diOsVersion     = osVersion
    , diScreenDensity = screenDensity
    , diScreenWidth   = screenWidth
    , diScreenHeight  = screenHeight
    }

-- | Log all device info fields via 'platformLog'.
-- Called from platform bridges after device info setters are invoked.
haskellLogDeviceInfo :: IO ()
haskellLogDeviceInfo = do
  info <- getDeviceInfo
  platformLog ("DeviceInfo model: " <> diModel info)
  platformLog ("DeviceInfo osVersion: " <> diOsVersion info)
  platformLog ("DeviceInfo screenDensity: " <> diScreenDensity info)
  platformLog ("DeviceInfo screenWidth: " <> diScreenWidth info)
  platformLog ("DeviceInfo screenHeight: " <> diScreenHeight info)

foreign export ccall haskellLogDeviceInfo :: IO ()

-- | Peek a CString into Text.
peekText :: CString -> IO Text
peekText cstr = Text.pack <$> peekCString cstr
