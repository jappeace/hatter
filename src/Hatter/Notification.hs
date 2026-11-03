{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Notifications, which may be shown and cancelled from any thread, also
-- while no screen is open.  Tapping one opens the app and calls
-- 'Hatter.Lifecycle.onNotificationOpened' with its key.
--
-- Without a platform's implementation, the calls are logged.
module Hatter.Notification
  ( Notification(..)
  , NotificationKind(..)
  , showNotification
  , cancelNotification
  , setOngoingCall
  , setShowOverLockScreen
  , setKeepScreenOn
  , setRunInBackground
  , setServiceStatus
  , stopBackground
  , fullScreenAllowed
  , allowFullScreen
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..), CLLong(..))
import Hatter.Marshal (withText)

data Notification = Notification
  { notificationKey     :: Text
    -- ^ Shown again with the same key, it replaces the one before.
  , notificationChannel :: Text
    -- ^ The name of its channel, which the user can mute in the settings.
  , notificationIcon    :: Text
    -- ^ The name of the app's drawable for the status bar.
  , notificationTitle   :: Text
  , notificationLines   :: [Text]
    -- ^ Oldest first, each on one line.  Folded away, it shows the last.
  , notificationKind    :: NotificationKind
  } deriving (Show, Eq)

-- | What a notification is about, which the platform may sort and let
-- through Do Not Disturb by.
data NotificationKind
  = MessageNotification
  | RingingCall
    -- ^ Its channel plays the ringtone, over and over until it is cancelled
    -- or tapped.  A channel keeps the sound it was made with.
  | MissedCall
  deriving (Show, Eq, Enum, Bounded)

foreign import ccall safe "notification_show"
  c_notificationShow :: CString -> CString -> CString -> CString -> CString -> CInt -> IO ()

foreign import ccall safe "notification_cancel"
  c_notificationCancel :: CString -> IO ()

showNotification :: Notification -> IO ()
showNotification n =
  withText (notificationKey n) $ \key ->
  withText (notificationChannel n) $ \channel ->
  withText (notificationIcon n) $ \icon ->
  withText (notificationTitle n) $ \title ->
  -- The platforms split the lines at newlines.
  withText (Text.intercalate "\n" (map (Text.replace "\n" " ") (notificationLines n))) $ \text ->
    c_notificationShow key channel icon title text (fromIntegral (fromEnum (notificationKind n)))

foreign import ccall safe "notification_ongoing"
  c_notificationOngoing :: CString -> CString -> CLLong -> IO ()

-- | The call going on, with the key 'Hatter.Lifecycle.onCallButton' gets
-- when its hang-up is pressed, whom it is with and since when, or none,
-- for the platform to show while it goes on.
setOngoingCall :: Text -> Maybe (Text, UTCTime) -> IO ()
setOngoingCall key call =
  withText key $ \ckey ->
  withText (maybe "" fst call) $ \title ->
    c_notificationOngoing ckey title (maybe 0 (round . (* 1000) . utcTimeToPOSIXSeconds . snd) call)

foreign import ccall safe "notification_status"
  c_notificationStatus :: CString -> IO ()

-- | What the app says it is doing while it runs in the background, for the
-- platform to show.
setServiceStatus :: Text -> IO ()
setServiceStatus text = withText text c_notificationStatus

foreign import ccall safe "notification_run_in_background"
  c_notificationRunInBackground :: CInt -> IO ()

foreign import ccall safe "notification_stop_background"
  c_notificationStopBackground :: IO ()

-- | Whether the app runs in the background, kept so that it does again
-- after the device starts.
setRunInBackground :: Bool -> IO ()
setRunInBackground on = c_notificationRunInBackground (if on then 1 else 0)

-- | Stops the app running in the background, which ends the process.
stopBackground :: IO ()
stopBackground = c_notificationStopBackground

foreign import ccall safe "notification_over_lock_screen"
  c_notificationOverLockScreen :: CInt -> IO ()

foreign import ccall safe "notification_keep_screen_on"
  c_notificationKeepScreenOn :: CInt -> IO ()

foreign import ccall safe "notification_full_screen_allowed"
  c_notificationFullScreenAllowed :: IO CInt

foreign import ccall safe "notification_allow_full_screen"
  c_notificationAllowFullScreen :: IO ()

-- | While set, the app shows over the lock screen and turns the screen on,
-- as while a call shows: what it shows then is open to anyone holding the
-- phone.  From any thread.
setShowOverLockScreen :: Bool -> IO ()
setShowOverLockScreen on = c_notificationOverLockScreen (if on then 1 else 0)

-- | While set, the screen doesn't turn off by itself while the app shows, as
-- during a call.  Near the ear, the call's audio still turns it off.  From
-- any thread.
setKeepScreenOn :: Bool -> IO ()
setKeepScreenOn on = c_notificationKeepScreenOn (if on then 1 else 0)

-- | Whether a ringing notification may show the app over the lock screen,
-- which the user may forbid.
fullScreenAllowed :: IO Bool
fullScreenAllowed = (/= 0) <$> c_notificationFullScreenAllowed

-- | Opens the setting that lets a ringing notification show the app over
-- the lock screen.
allowFullScreen :: IO ()
allowFullScreen = c_notificationAllowFullScreen

cancelNotification :: Text -> IO ()
cancelNotification key = withText key c_notificationCancel
