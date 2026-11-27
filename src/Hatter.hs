{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Hatter
-- Description : Cross-platform mobile UI framework for Haskell
--
-- Hatter lets you build native apps in Haskell.  Define your UI as a
-- pure 'Widget' tree, wire up callbacks with 'Action' handles, and the
-- framework takes care of rendering on Android, iOS, watchOS, desktops
-- (Qt), terminals and browsers.
--
-- = Getting started
--
-- @
-- import Hatter
-- import Hatter.Widget
--
-- main :: IO ()
-- main = do
--   acts <- 'newActionState'
--   greet <- 'runActionM' acts $ 'createAction' (putStrLn \"tapped!\")
--   _ <- 'startMobileApp' MobileApp
--     { maContext     = 'defaultMobileContext'
--     , maView        = \\_ -> pure ('button' greet \"Tap me\")
--     , maActionState = acts
--     }
--   pure ()
-- @
--
-- = Platform subsystems
--
-- Domain-specific APIs live in their own modules.  Import them when you
-- need a particular capability:
--
-- * "Hatter.Permission" — runtime permission requests
-- * "Hatter.SecureStorage" — encrypted key-value storage
-- * "Hatter.Ble" — Bluetooth Low Energy scanning
-- * "Hatter.Dialog" — native alert dialogs
-- * "Hatter.Location" — GPS \/ location updates
-- * "Hatter.AuthSession" — OAuth browser sessions
-- * "Hatter.PlatformSignIn" — native platform sign-in (Apple\/Google)
-- * "Hatter.Camera" — photo & video capture
-- * "Hatter.BottomSheet" — modal bottom sheets
-- * "Hatter.Http" — HTTP requests
-- * "Hatter.NetworkStatus" — connectivity monitoring
-- * "Hatter.Locale" — device locale & language
-- * "Hatter.I18n" — internationalisation helpers
-- * "Hatter.FilesDir" — app-private file storage path
-- * "Hatter.AppContext" — low-level context pointer (advanced)
module Hatter
  ( -- * App setup
    MobileApp(..)
  , UserState(..)
  , startMobileApp
    -- * Widget
  , Widget(..)
  , WidgetStyle(wsPadding, wsPaddingY, wsTextAlign, wsBackgroundColor, wsTranslateX, wsTranslateY, wsWidth, wsTouchPassthrough, wsHeight, wsWeight, wsAlignSelf, wsMargin, wsMaxWidth, wsMaxLines, wsCorners, wsKeepAtEnd)
  , SelfAlignment(..)
  , defaultStyle
  , ButtonConfig(..)
  , SwitchConfig(..)
  , TextConfig(..)
  , FontConfig(fontSize, fontWeight, fontFamily, fontSlant)
  , FontWeight(..)
  , FontFamily(..)
  , FontSlant(..)
  , Corners(..)
  , rounded
  , fontOfSize
  , TextInputConfig(..)
  , InputType(..)
  , LayoutSettings(..)
  , WidgetKey(..)
  , LayoutItem(..)
  , ImageConfig(..)
  , ImageSource(..)
  , ResourceName(..)
  , ScaleType(..)
  , TextAlignment(..)
  , WebViewConfig(..)
  , MapViewConfig(..)
  , Color(..)
  , colorFromText
  , colorToHex
    -- ** Smart constructors
  , button
  , switch
  , column
  , item
  , keyedItem
  , row
  , scrollColumn
  , scrollRow
  , text
    -- * Actions
  , Action(..)
  , OnChange(..)
  , OnScroll(..)
  , ListPosition(..)
  , ActionState
  , ActionM
  , createAction
  , createOnChange
  , createOnScroll
  , newActionState
  , runActionM
    -- * Animation
  , KeyframeAt
  , mkKeyframeAt
  , unKeyframeAt
  , Keyframe(..)
  , AnimatedConfig(..)
  , linearAnimation
  , easeInAnimation
  , easeOutAnimation
  , easeInOutAnimation
  , andThen
  , lerpStyle
    -- * Lifecycle
  , LifecycleEvent(..)
  , MobileContext(onLifecycle, onError, onBack, onNotificationOpened, onCallButton, onFilePicked, onPicturePicked, onRendered)
  , CallButton(..)
  , defaultMobileContext
  , loggingMobileContext
  , platformLog
  , isDarkMode
  , is24HourClock
  , copyToClipboard
  , PickedFile(..)
  , pickFile
  , pickFiles
  , pickPicture
  , saveFile
  , imageSize
  , capturePicture
  , openFile
  , openUri
    -- * Error handling
  , errorWidget
    -- * Internal
    -- | FFI entry points used by the test suite.  Application code
    -- should not need them.  The remaining @foreign export ccall@
    -- functions (permission, BLE, camera, etc.) are visible to the
    -- C linker but not re-exported as Haskell API.
  , currentWidget
  , haskellRenderUI
  , haskellOnUIEvent
  , haskellOnUITextChange
  , haskellOnLifecycle
  , haskellOnBack
  , haskellOnNotificationOpened
  , haskellOnCallButton
  , haskellOnLazyBind
  , haskellLazyItemKey
  , haskellOnUIScroll
  , haskellOnFilePicked
  , haskellOnPicturePicked
  , haskellOnDialogResult
  , haskellOnBottomSheetResult
  )
where

import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text, pack)
import Data.Int (Int64)
import Foreign.C.String (CString)
import Foreign.C.Types (CDouble(..), CInt(..))
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Data.ByteString qualified as BS
import Data.Word (Word8)
import System.IO (hPutStrLn, stderr)
import Unwitch.Convert.CInt qualified as CInt
import Unwitch.Convert.Int qualified as Int
import Unwitch.Convert.Int32 qualified as Int32
import Hatter.Action
  ( Action(..)
  , OnChange(..)
  , OnScroll(..)
  , ListPosition(..)
  , ActionState
  , ActionM
  , createAction
  , createOnChange
  , createOnScroll
  , newActionState
  , runActionM
  )
import Hatter.Animation (dispatchAnimationFrame)
import Hatter.AppContext (AppContext(..), newAppContext, derefAppContext)
import Hatter.AuthSession (dispatchAuthSessionResult)
import Hatter.PlatformSignIn (dispatchPlatformSignInResult)
import Hatter.Ble
  ( dispatchBleScanResult
  , dispatchBleConnectionEvent
  , dispatchBleCharacteristicDiscovered
  , dispatchBleGattCompletion
  , dispatchBleNotification
  , bleConnectionEventFromInt
  , bleGattOperationFromInt
  , bleCharacteristicPropertiesFromBits
  , BleGattCompletion(..)
  , BleDiscoveredCharacteristic(..)
  , BleServiceUuid(..)
  , BleCharacteristicUuid(..)
  , BleCharacteristicValue(..)
  , BleMtu(..)
  )
import Hatter.BottomSheet (dispatchBottomSheetResult)
import Hatter.Camera
  ( dispatchCameraResult
  , dispatchVideoFrame
  , dispatchAudioChunk
  )
import Hatter.Dialog (dispatchDialogResult)
import GHC.Clock (getMonotonicTimeNSec)
import Hatter.Http (dispatchHttpResult)
import Hatter.Lifecycle
  ( LifecycleEvent(..)
  , MobileContext(..)
  , CallButton(..)
  , PickedFile(..)
  , callButtonFromInt
  , defaultMobileContext
  , loggingMobileContext
  , platformLog
  , lifecycleFromInt
  )
import Hatter.Locale ()  -- for foreign export ccall haskellLogLocale
import Hatter.DeviceInfo ()  -- for foreign export ccall haskellLogDeviceInfo
import Hatter.Location (dispatchLocationUpdate)
import Hatter.NetworkStatus (dispatchNetworkStatusChange)
import Hatter.Permission (dispatchPermissionResult)
import Hatter.Render (renderWidget, resetRender, dispatchEvent, dispatchTextEvent, dispatchScrollEvent, bindLazyRow, lazyItemKey)
import Hatter.SecureStorage (dispatchSecureStorageResult)
import Hatter.Types (MobileApp(..), UserState(..))
import Hatter.UIBridge qualified as Bridge
import Hatter.Marshal (peekBytes, peekMaybeText, peekPath, peekText)
import Hatter.Widget
  ( AnimatedConfig(..)
  , ButtonConfig(..)
  , SwitchConfig(..)
  , Color(..)
  , FontConfig(..)
  , FontFamily(..)
  , FontSlant(..)
  , Corners(..)
  , rounded
  , FontWeight(..)
  , ImageConfig(..)
  , fontOfSize
  , ImageSource(..)
  , InputType(..)
  , Keyframe(..)
  , KeyframeAt
  , LayoutItem(..)
  , LayoutSettings(..)
  , MapViewConfig(..)
  , ResourceName(..)
  , ScaleType(..)
  , SelfAlignment(..)
  , TextAlignment(..)
  , TextConfig(..)
  , TextInputConfig(..)
  , WebViewConfig(..)
  , Widget(..)
  , WidgetKey(..)
  , WidgetStyle(..)
  , andThen
  , button
  , switch
  , easeInAnimation
  , easeInOutAnimation
  , easeOutAnimation
  , colorFromText
  , colorToHex
  , column
  , defaultStyle
  , item
  , keyedItem
  , linearAnimation
  , lerpStyle
  , mkKeyframeAt
  , row
  , scrollColumn
  , scrollRow
  , text
  , unKeyframeAt
  )

-- | Create an 'AppContext' from a 'MobileApp' and return it as a typed
-- pointer suitable for the C FFI. This is the user-facing API: the user's
-- @main@ calls this to initialise the framework.
startMobileApp :: MobileApp -> IO (Ptr AppContext)
startMobileApp = newAppContext

-- | Wrap an IO action in a catch-all exception handler.
-- On failure, logs the exception, overwrites the context's view
-- with an error widget, and fires the user's 'onError' callback.
withExceptionHandler :: Ptr AppContext -> IO () -> IO ()
withExceptionHandler ctxPtr action =
  catch action (handleException ctxPtr)

-- | As 'withExceptionHandler', for an entry point that answers the
-- platform: with the fallback after an exception.
answering :: a -> Ptr AppContext -> IO a -> IO a
answering fallback ctxPtr action =
  catch action (\exc -> fallback <$ handleException ctxPtr exc)

-- | Handle an uncaught exception from an FFI entry point.
-- Overwrites the context's view function with an error widget so
-- that subsequent renders show the error on screen. The dismiss
-- button uses a pre-registered 'Action' handle; we write the real
-- restore logic into 'acDismissRef'.
-- Also logs via 'platformLog' and best-effort fires 'onError'.
handleException :: Ptr AppContext -> SomeException -> IO ()
handleException ctxPtr exc = do
  appCtx <- derefAppContext ctxPtr
  originalView <- readIORef (acViewFunction appCtx)
  let dismissAction = acDismissAction appCtx
  -- Write the real dismiss logic: restore the original view function.
  writeIORef (acDismissRef appCtx)
    (writeIORef (acViewFunction appCtx) originalView)
  writeIORef (acViewFunction appCtx)
    (\_userState -> pure (errorWidget dismissAction exc))
  platformLog ("Uncaught exception: " <> pack (show exc))
  renderWidget (acRenderState appCtx)
    (errorWidget dismissAction exc)
  fireUserErrorCallback appCtx exc

-- | Best-effort: read the context's 'onError' callback and fire it.
-- Catches any secondary exception so we never crash in the error handler.
fireUserErrorCallback :: AppContext -> SomeException -> IO ()
fireUserErrorCallback appCtx exc =
  catch
    (onError (acMobileContext appCtx) exc)
    (\secondaryExc ->
      platformLog ("onError callback failed: " <> pack (show (secondaryExc :: SomeException))))

-- | Render the current view: read the view function from AppContext and
-- render its widget.
renderView :: Ptr AppContext -> IO ()
renderView ctxPtr = do
  appCtx <- derefAppContext ctxPtr
  start <- getMonotonicTimeNSec
  widget <- currentWidget ctxPtr
  renderWidget (acRenderState appCtx) widget
  end <- getMonotonicTimeNSec
  onRendered (acMobileContext appCtx) (end - start)

-- | The widget the app shows now, for a platform that draws it itself
-- rather than through the native views.
currentWidget :: Ptr AppContext -> IO Widget
currentWidget ctxPtr = do
  appCtx <- derefAppContext ctxPtr
  viewFunction <- readIORef (acViewFunction appCtx)
  let userState = UserState
        { userPermissionState    = acPermissionState appCtx
        , userSecureStorageState = acSecureStorageState appCtx
        , userBleState           = acBleState appCtx
        , userDialogState        = acDialogState appCtx
        , userLocationState      = acLocationState appCtx
        , userAuthSessionState   = acAuthSessionState appCtx
        , userCameraState        = acCameraState appCtx
        , userBottomSheetState   = acBottomSheetState appCtx
        , userHttpState              = acHttpState appCtx
        , userNetworkStatusState    = acNetworkStatusState appCtx
        , userAnimationState        = acAnimationState appCtx
        , userPlatformSignInState   = acPlatformSignInState appCtx
        , userRequestRedraw         = c_requestRedraw (castPtr ctxPtr)
        }
  c_redrawStoreCtx (castPtr ctxPtr)
  viewFunction userState

-- | Whether the platform shows dark colours now, for views that pick
-- their own. It renders again when this changes.
isDarkMode :: IO Bool
isDarkMode = Bridge.darkMode

-- | Whether the user wants times on a 24-hour clock, as the platform's
-- setting says now. A 12-hour clock where it can't say.
is24HourClock :: IO Bool
is24HourClock = Bridge.clock24

-- | Put text on the platform's clipboard, from an action.
copyToClipboard :: Text -> IO ()
copyToClipboard = Bridge.copyText

-- | Let the user pick a file of a MIME type, such as @*/*@, from an action.
-- 'onFilePicked' gets a copy of it.
pickFile :: Text -> IO ()
pickFile = Bridge.pickFile

-- | Let the user save one of the app's files where they choose, under a
-- suggested name and of a MIME type, from an action. The app's file is
-- deleted afterwards, also if they cancel (it may hold secrets).
saveFile :: FilePath -> Text -> Text -> IO ()
saveFile = Bridge.saveFile

-- | The width and height a picture file shows at, turned as its camera
-- says, without decoding it all. Nothing if it isn't one, or where the
-- platform can't tell.
imageSize :: FilePath -> IO (Maybe (Int, Int))
imageSize = Bridge.imageSize

-- | Let the user pick a picture, from an action, which 'onPicturePicked'
-- gets cut to a square and scaled to the first of the sides whose PNG has
-- at most so many bytes. Nothing comes when none fits.
pickPicture :: [Int] -> Int -> IO ()
pickPicture = Bridge.pickPicture

-- | As 'pickFile', letting the user pick several, each a call of
-- 'onFilePicked'.
pickFiles :: Text -> IO ()
pickFiles = Bridge.pickFiles

-- | Take a picture with the platform's camera app, from an action, which
-- 'onFilePicked' gets as a file. Ask for the camera permission first, as
-- some platforms don't start the camera app for an app declaring it
-- without.
capturePicture :: IO ()
capturePicture = Bridge.capturePicture

-- | Show one of the app's files in another app that takes its type, from an
-- action.
openFile :: FilePath -> IO ()
openFile = Bridge.openFile

-- | Open a web or mail address in another app that takes it, from an
-- action.
openUri :: Text -> IO ()
openUri = Bridge.openUri

-- | A widget that displays an error message with a dismiss button.
-- The dismiss button uses a pre-registered 'Action' handle whose
-- closure is populated by the exception handler.
errorWidget :: Action -> SomeException -> Widget
errorWidget dismissAction exc = column
  [ Text TextConfig
      { tcLabel      = "An error occurred"
      , tcFontConfig = Just (fontOfSize 20.0)
      , tcTextColor  = Nothing
      }
  , Text TextConfig
      { tcLabel      = pack (show exc)
      , tcFontConfig = Nothing
      , tcTextColor  = Nothing
      }
  , Button ButtonConfig
      { bcLabel      = "Dismiss"
      , bcAction     = dismissAction
      , bcFontConfig = Nothing
      , bcTextColor  = Nothing
      }
  ]

-- | Render the UI tree. Dereferences the context pointer to obtain the
-- 'RenderState', reads the view function from 'AppContext'
-- to get the widget description, then issues ui_* calls through the
-- registered bridge callbacks. Catches exceptions and shows error widget.
haskellRenderUI :: Ptr AppContext -> IO ()
haskellRenderUI ctxPtr =
  withExceptionHandler ctxPtr (renderView ctxPtr)

foreign export ccall haskellRenderUI :: Ptr AppContext -> IO ()

-- | Forget the native views, for a platform that has dropped them.  The
-- next 'haskellRenderUI' creates them all again.
haskellResetUI :: Ptr AppContext -> IO ()
haskellResetUI ctxPtr = do
  appCtx <- derefAppContext ctxPtr
  resetRender (acRenderState appCtx)

foreign export ccall haskellResetUI :: Ptr AppContext -> IO ()

-- | Handle a UI event from native code. Dispatches the callback
-- identified by @callbackId@, then re-renders the UI.
haskellOnUIEvent :: Ptr AppContext -> CInt -> IO ()
haskellOnUIEvent ctxPtr callbackId =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchEvent (acRenderState appCtx) (CInt.toInt32 callbackId)
    renderView ctxPtr

foreign export ccall haskellOnUIEvent :: Ptr AppContext -> CInt -> IO ()

-- | Handle a text change event from native code. Dispatches the callback
-- identified by @callbackId@ with the new text value, then re-renders
-- the UI so that state changes caused by the callback become visible.
-- TextInput nodes are diffed in-place (see 'Hatter.Render.diffRenderNode')
-- to avoid destroying and recreating the native widget, which would
-- reset the cursor position and cause flicker on Android.
haskellOnUITextChange :: Ptr AppContext -> CInt -> CString -> IO ()
haskellOnUITextChange ctxPtr callbackId cstr =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    typed <- peekText cstr
    dispatchTextEvent (acRenderState appCtx) (CInt.toInt32 callbackId) typed
    renderView ctxPtr

foreign export ccall haskellOnUITextChange :: Ptr AppContext -> CInt -> CString -> IO ()

-- | Handle where a list is from native code, by 'ListPosition''s number,
-- rendering again after.
haskellOnUIScroll :: Ptr AppContext -> CInt -> CInt -> IO ()
haskellOnUIScroll ctxPtr callbackId position =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchScrollEvent (acRenderState appCtx) (CInt.toInt32 callbackId) (CInt.toInt position)
    renderView ctxPtr

foreign export ccall haskellOnUIScroll :: Ptr AppContext -> CInt -> CInt -> IO ()

-- | Handle a permission result from native code. Dispatches to the
-- callback registered by 'Hatter.Permission.requestPermission'.
haskellOnPermissionResult :: Ptr AppContext -> CInt -> CInt -> IO ()
haskellOnPermissionResult ctxPtr requestId statusCode =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchPermissionResult (acPermissionState appCtx) requestId statusCode

foreign export ccall haskellOnPermissionResult :: Ptr AppContext -> CInt -> CInt -> IO ()

-- | Handle a BLE scan result from native code. Dispatches to the
-- callback registered by 'Hatter.Ble.startBleScan'.
haskellOnBleScanResult
  :: Ptr AppContext -> CString -> CString -> CInt -> Ptr Word8 -> CInt -> IO ()
haskellOnBleScanResult ctxPtr cName cAddr cRssi advPtr advLength =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchBleScanResult (acBleState appCtx) cName cAddr cRssi advPtr advLength

foreign export ccall haskellOnBleScanResult
  :: Ptr AppContext -> CString -> CString -> CInt -> Ptr Word8 -> CInt -> IO ()

-- | Handle a BLE connection event from native code. Decodes the C
-- event code here at the FFI boundary so 'dispatchBleConnectionEvent'
-- only deals in 'Hatter.Ble.BleConnectionEvent', then dispatches to
-- the callback registered by 'Hatter.Ble.connectBleDevice'.
haskellOnBleConnectionEvent :: Ptr AppContext -> CInt -> IO ()
haskellOnBleConnectionEvent ctxPtr eventCode =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    case bleConnectionEventFromInt eventCode of
      Nothing -> hPutStrLn stderr $
        "haskellOnBleConnectionEvent: unknown event code " ++ show eventCode
      Just event -> dispatchBleConnectionEvent (acBleState appCtx) event

foreign export ccall haskellOnBleConnectionEvent :: Ptr AppContext -> CInt -> IO ()

-- | Handle one discovered GATT characteristic from native code,
-- streamed during a 'Hatter.Ble.discoverBleServices' run.
haskellOnBleCharacteristicDiscovered
  :: Ptr AppContext -> CString -> CString -> CInt -> IO ()
haskellOnBleCharacteristicDiscovered ctxPtr cService cCharacteristic cProperties =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    serviceUuid <- peekText cService
    characteristicUuid <- peekText cCharacteristic
    dispatchBleCharacteristicDiscovered (acBleState appCtx)
      BleDiscoveredCharacteristic
        { bdcService        = BleServiceUuid serviceUuid
        , bdcCharacteristic = BleCharacteristicUuid characteristicUuid
        , bdcProperties     = bleCharacteristicPropertiesFromBits cProperties
        }

foreign export ccall haskellOnBleCharacteristicDiscovered
  :: Ptr AppContext -> CString -> CString -> CInt -> IO ()

-- | Handle a GATT operation completion from native code.  Decodes the
-- operation code, status, payload (read data) and granted MTU at the
-- FFI boundary, then dispatches to the pending operation registered
-- in 'Hatter.Ble.BleState'.
haskellOnBleGattResult
  :: Ptr AppContext -> CInt -> CInt -> Ptr Word8 -> CInt -> IO ()
haskellOnBleGattResult ctxPtr cOperation cStatus dataPtr dataLength =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    case bleGattOperationFromInt cOperation of
      Nothing -> hPutStrLn stderr $
        "haskellOnBleGattResult: unknown operation code " ++ show cOperation
      Just operation -> do
        -- With a payload the length field is the payload size; without
        -- one it carries the granted MTU (nonzero only for MTU
        -- completions, see BleBridge.h).
        payload <- peekBytes dataPtr dataLength
        let grantedMtu = if dataPtr == nullPtr then CInt.toInt dataLength else 0
        dispatchBleGattCompletion (acBleState appCtx) BleGattCompletion
          { bgcOperation  = operation
          , bgcStatusCode = CInt.toInt cStatus
          , bgcPayload    = BleCharacteristicValue payload
          , bgcGrantedMtu = BleMtu grantedMtu
          }

foreign export ccall haskellOnBleGattResult
  :: Ptr AppContext -> CInt -> CInt -> Ptr Word8 -> CInt -> IO ()

-- | Handle characteristic notification data from native code.
-- Dispatches to the callback registered by
-- 'Hatter.Ble.subscribeBleCharacteristic'.
haskellOnBleNotification
  :: Ptr AppContext -> CString -> CString -> Ptr Word8 -> CInt -> IO ()
haskellOnBleNotification ctxPtr cService cCharacteristic dataPtr dataLength =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    serviceUuid <- peekText cService
    characteristicUuid <- peekText cCharacteristic
    payload <- peekBytes dataPtr dataLength
    dispatchBleNotification (acBleState appCtx)
      (BleServiceUuid serviceUuid)
      (BleCharacteristicUuid characteristicUuid)
      (BleCharacteristicValue payload)

foreign export ccall haskellOnBleNotification
  :: Ptr AppContext -> CString -> CString -> Ptr Word8 -> CInt -> IO ()

-- | Handle a dialog result from native code. Dispatches to the
-- callback registered by 'Hatter.Dialog.showDialog'.
haskellOnDialogResult :: Ptr AppContext -> CInt -> CInt -> IO ()
haskellOnDialogResult ctxPtr requestId actionCode =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchDialogResult (acDialogState appCtx) requestId actionCode

foreign export ccall haskellOnDialogResult :: Ptr AppContext -> CInt -> CInt -> IO ()

-- | Handle a location update from native code. Dispatches to the
-- callback registered by 'Hatter.Location.startLocationUpdates'.
haskellOnLocationUpdate :: Ptr AppContext -> CDouble -> CDouble -> CDouble -> CDouble -> IO ()
haskellOnLocationUpdate ctxPtr cLat cLon cAlt cAcc =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchLocationUpdate (acLocationState appCtx) cLat cLon cAlt cAcc

foreign export ccall haskellOnLocationUpdate :: Ptr AppContext -> CDouble -> CDouble -> CDouble -> CDouble -> IO ()

-- | FFI entry point called from platform code.
-- Takes a context pointer and an event code.
-- Dereferences as 'AppContext' and dispatches to the 'onLifecycle' callback
-- of the inner 'MobileContext'. Unknown event codes are silently ignored.
-- Catches exceptions and fires 'onError'.
haskellOnLifecycle :: Ptr AppContext -> CInt -> IO ()
haskellOnLifecycle ctxPtr code =
  withExceptionHandler ctxPtr $
    case lifecycleFromInt code of
      Just event -> do
        appCtx <- derefAppContext ctxPtr
        onLifecycle (acMobileContext appCtx) event
      Nothing -> pure ()

foreign export ccall haskellOnLifecycle :: Ptr AppContext -> CInt -> IO ()

-- | Handle Back from native code: 1 if the app handled it, after
-- rendering again, 0 to leave it to the platform.
haskellOnBack :: Ptr AppContext -> IO CInt
haskellOnBack ctxPtr = answering 0 ctxPtr $ do
  appCtx <- derefAppContext ctxPtr
  handled <- onBack (acMobileContext appCtx)
  when handled (withExceptionHandler ctxPtr (renderView ctxPtr))
  pure (if handled then 1 else 0)

foreign export ccall haskellOnBack :: Ptr AppContext -> IO CInt

-- | Handle a tap on one of the app's notifications from native code, with
-- its key in UTF-8, rendering again after.
haskellOnNotificationOpened :: Ptr AppContext -> CString -> IO ()
haskellOnNotificationOpened ctxPtr keyPtr = do
  key <- peekText keyPtr
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    onNotificationOpened (acMobileContext appCtx) key
    renderView ctxPtr

foreign export ccall haskellOnNotificationOpened :: Ptr AppContext -> CString -> IO ()

-- | Handle a button of a ringing notification from native code, with its
-- key in UTF-8: 0 answers, which opened the app and renders again after,
-- 1 declines, and 2 hangs up the call going on.
haskellOnCallButton :: Ptr AppContext -> CString -> CInt -> IO ()
haskellOnCallButton ctxPtr keyPtr code = do
  key <- peekText keyPtr
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    let pressed = callButtonFromInt code
    onCallButton (acMobileContext appCtx) key pressed
    when (pressed == Answer) (renderView ctxPtr)

foreign export ccall haskellOnCallButton :: Ptr AppContext -> CString -> CInt -> IO ()

-- | Render a lazy column's item at a position into one of its rows, as
-- the platform asks while it scrolls: the row's node ID, or 0 if the
-- platform is to show nothing there.
haskellOnLazyBind :: Ptr AppContext -> CInt -> CInt -> CInt -> IO CInt
haskellOnLazyBind ctxPtr listId rowId position = answering 0 ctxPtr $ do
  appCtx <- derefAppContext ctxPtr
  Int32.toCInt <$> bindLazyRow (acRenderState appCtx) (CInt.toInt32 listId) (CInt.toInt32 rowId) (CInt.toInt position)

foreign export ccall haskellOnLazyBind :: Ptr AppContext -> CInt -> CInt -> CInt -> IO CInt

-- | The key of a lazy column's item at a position, as the platform's ID
-- for it.
haskellLazyItemKey :: Ptr AppContext -> CInt -> CInt -> IO Int64
haskellLazyItemKey ctxPtr listId position =
  answering (Int.toInt64 (CInt.toInt position)) ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    Int.toInt64 <$> lazyItemKey (acRenderState appCtx) (CInt.toInt32 listId) (CInt.toInt position)

foreign export ccall haskellLazyItemKey :: Ptr AppContext -> CInt -> CInt -> IO Int64

-- | Handle a file the user picked from native code: its path and name in
-- UTF-8, and its size, rendering again after.
haskellOnFilePicked :: Ptr AppContext -> CString -> CString -> Int64 -> IO ()
haskellOnFilePicked ctxPtr pathPtr namePtr size = do
  path <- peekPath pathPtr
  name <- peekText namePtr
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    onFilePicked (acMobileContext appCtx) (PickedFile path name (toInteger size))
    renderView ctxPtr

foreign export ccall haskellOnFilePicked :: Ptr AppContext -> CString -> CString -> Int64 -> IO ()

-- | Handle a picture the user picked from native code, as a PNG, rendering
-- again after.
haskellOnPicturePicked :: Ptr AppContext -> Ptr Word8 -> CInt -> IO ()
haskellOnPicturePicked ctxPtr bytes size = do
  png <- BS.packCStringLen (castPtr bytes, fromIntegral size)
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    onPicturePicked (acMobileContext appCtx) png
    renderView ctxPtr

foreign export ccall haskellOnPicturePicked :: Ptr AppContext -> Ptr Word8 -> CInt -> IO ()

-- | Handle a secure storage result from native code. Dispatches to the
-- callback registered by 'Hatter.SecureStorage.secureStorageWrite',
-- 'Hatter.SecureStorage.secureStorageRead', or
-- 'Hatter.SecureStorage.secureStorageDelete'.  The @cValue@ parameter is non-null only for
-- successful read operations.
haskellOnSecureStorageResult :: Ptr AppContext -> CInt -> CInt -> CString -> IO ()
haskellOnSecureStorageResult ctxPtr requestId statusCode cValue =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    maybeValue <- peekMaybeText cValue
    dispatchSecureStorageResult (acSecureStorageState appCtx) requestId statusCode maybeValue

foreign export ccall haskellOnSecureStorageResult :: Ptr AppContext -> CInt -> CInt -> CString -> IO ()

-- | Handle an auth session result from native code. Dispatches to the
-- callback registered by 'Hatter.AuthSession.startAuthSession'. The @cRedirectUrl@ parameter
-- is non-null only for successful sessions. The @cErrorMsg@ parameter
-- is non-null only for error sessions.
haskellOnAuthSessionResult :: Ptr AppContext -> CInt -> CInt -> CString -> CString -> IO ()
haskellOnAuthSessionResult ctxPtr requestId statusCode cRedirectUrl cErrorMsg =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    maybeRedirectUrl <- peekMaybeText cRedirectUrl
    maybeErrorMsg <- peekMaybeText cErrorMsg
    dispatchAuthSessionResult (acAuthSessionState appCtx) requestId statusCode maybeRedirectUrl maybeErrorMsg

foreign export ccall haskellOnAuthSessionResult :: Ptr AppContext -> CInt -> CInt -> CString -> CString -> IO ()

-- | Handle a platform sign-in result from native code. Dispatches to the
-- callback registered by 'Hatter.PlatformSignIn.startPlatformSignIn'.
-- The @cIdentityToken@, @cUserId@, @cEmail@, @cFullName@ parameters
-- carry credential fields; null values become 'Nothing'.
haskellOnPlatformSignInResult :: Ptr AppContext -> CInt -> CInt -> CString -> CString -> CString -> CString -> CInt -> IO ()
haskellOnPlatformSignInResult ctxPtr requestId statusCode cIdentityToken cUserId cEmail cFullName cProvider =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    maybeToken    <- peekMaybeText cIdentityToken
    maybeUserId   <- peekMaybeText cUserId
    maybeEmail    <- peekMaybeText cEmail
    maybeFullName <- peekMaybeText cFullName
    dispatchPlatformSignInResult (acPlatformSignInState appCtx)
      requestId statusCode maybeToken maybeUserId maybeEmail maybeFullName cProvider

foreign export ccall haskellOnPlatformSignInResult
  :: Ptr AppContext -> CInt -> CInt -> CString -> CString -> CString -> CString -> CInt -> IO ()

-- | Handle a camera result from native code. Dispatches to the
-- callback registered by 'Hatter.Camera.capturePhoto' or 'Hatter.Camera.startVideoCapture'.
-- The @imageDataPtr@/@imageDataLen@/@width@/@height@ parameters carry
-- raw JPEG bytes for photo captures; null\/0 for video completions and
-- error results.
haskellOnCameraResult :: Ptr AppContext -> CInt -> CInt
                      -> Ptr Word8 -> CInt -> CInt -> CInt -> IO ()
haskellOnCameraResult ctxPtr requestId statusCode
                      imageDataPtr imageDataLen width height =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    imageData <- peekBytes imageDataPtr imageDataLen
    let maybeImageData = if BS.null imageData then Nothing else Just imageData
    dispatchCameraResult (acCameraState appCtx) requestId statusCode
      maybeImageData width height

foreign export ccall haskellOnCameraResult
  :: Ptr AppContext -> CInt -> CInt
  -> Ptr Word8 -> CInt -> CInt -> CInt -> IO ()

-- | Handle a video frame from native code. Dispatches to the
-- per-frame callback registered by 'Hatter.Camera.startVideoCapture'.
haskellOnVideoFrame :: Ptr AppContext -> CInt
                    -> Ptr Word8 -> CInt -> CInt -> CInt -> IO ()
haskellOnVideoFrame ctxPtr requestId frameDataPtr frameDataLen width height =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    frameBytes <- BS.packCStringLen (castPtr frameDataPtr, CInt.toInt frameDataLen)
    dispatchVideoFrame (acCameraState appCtx) requestId frameBytes width height

foreign export ccall haskellOnVideoFrame
  :: Ptr AppContext -> CInt -> Ptr Word8 -> CInt -> CInt -> CInt -> IO ()

-- | Handle an audio chunk from native code. Dispatches to the
-- per-audio-chunk callback registered by 'Hatter.Camera.startVideoCapture'.
haskellOnAudioChunk :: Ptr AppContext -> CInt
                    -> Ptr Word8 -> CInt -> IO ()
haskellOnAudioChunk ctxPtr requestId audioDataPtr audioDataLen =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    audioBytes <- BS.packCStringLen (castPtr audioDataPtr, CInt.toInt audioDataLen)
    dispatchAudioChunk (acCameraState appCtx) requestId audioBytes

foreign export ccall haskellOnAudioChunk
  :: Ptr AppContext -> CInt -> Ptr Word8 -> CInt -> IO ()

-- | Handle a bottom sheet result from native code. Dispatches to the
-- callback registered by 'Hatter.BottomSheet.showBottomSheet'.
haskellOnBottomSheetResult :: Ptr AppContext -> CInt -> CInt -> IO ()
haskellOnBottomSheetResult ctxPtr requestId actionCode =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchBottomSheetResult (acBottomSheetState appCtx) requestId actionCode

foreign export ccall haskellOnBottomSheetResult :: Ptr AppContext -> CInt -> CInt -> IO ()

-- | Handle an HTTP result from native code. Dispatches to the
-- callback registered by 'Hatter.Http.performRequest'. The @cHeaders@ parameter
-- is newline-delimited key-value pairs for success, or an error message
-- for network errors. The @bodyPtr@/@bodyLen@ carry the response body.
haskellOnHttpResult :: Ptr AppContext -> CInt -> CInt -> CInt
                    -> CString -> Ptr Word8 -> CInt -> IO ()
haskellOnHttpResult ctxPtr requestId resultCode httpStatus
                    cHeaders bodyPtr bodyLen =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    maybeHeaders <- peekMaybeText cHeaders
    responseBody <- peekBytes bodyPtr bodyLen
    dispatchHttpResult (acHttpState appCtx) requestId resultCode httpStatus
      maybeHeaders responseBody

foreign export ccall haskellOnHttpResult
  :: Ptr AppContext -> CInt -> CInt -> CInt
  -> CString -> Ptr Word8 -> CInt -> IO ()

-- | Handle a network status change from native code. Dispatches to the
-- callback registered by 'Hatter.NetworkStatus.startNetworkMonitoring'.
haskellOnNetworkStatusChange :: Ptr AppContext -> CInt -> CInt -> IO ()
haskellOnNetworkStatusChange ctxPtr cConnected cTransport =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchNetworkStatusChange (acNetworkStatusState appCtx) cConnected cTransport

foreign export ccall haskellOnNetworkStatusChange :: Ptr AppContext -> CInt -> CInt -> IO ()

-- | Handle an animation frame from native code.  Ticks all active tweens,
-- applies interpolated properties, then re-renders the UI so that the
-- user's view function can confirm the target (Eq match → no new tween).
haskellOnAnimationFrame :: Ptr AppContext -> CDouble -> IO ()
haskellOnAnimationFrame ctxPtr (CDouble timestampMs) =
  withExceptionHandler ctxPtr $ do
    appCtx <- derefAppContext ctxPtr
    dispatchAnimationFrame (acAnimationState appCtx) timestampMs
    renderView ctxPtr

foreign export ccall haskellOnAnimationFrame :: Ptr AppContext -> CDouble -> IO ()

-- | FFI import for the platform-agnostic redraw bridge.
-- On mobile, this posts to the main/UI thread; on desktop it calls
-- haskellRenderUI directly.
foreign import ccall "request_redraw" c_requestRedraw :: Ptr () -> IO ()
foreign import ccall "redraw_store_ctx" c_redrawStoreCtx :: Ptr () -> IO ()
