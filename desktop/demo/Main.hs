{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | A Hatter app for trying the Qt platform: a counter, a text field, and a
-- list kept at its end as notes come in. The notes are kept in the app's
-- files, so they are there again when it starts again. Tapping the count
-- adds ten, holding it starts again from nought and takes its notification
-- away, Notify shows the count in a notification, and opening that adds a
-- note saying so.
module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Foreign.Ptr (Ptr)
import Hatter (MobileApp (..), MobileContext (..), createAction, createOnChange, loggingMobileContext,
               newActionState, runActionM, startMobileApp)
import Hatter.AppContext (AppContext)
import Hatter.FilesDir (getAppFilesDir)
import Hatter.Notification (Notification (..), NotificationKind (..), cancelNotification, showNotification)
import Hatter.Desktop ()
import Hatter.Widget

main :: IO (Ptr AppContext)
main = do
  actions <- newActionState
  count <- newIORef (0 :: Int)
  draft <- newIORef Text.empty
  file <- (<> "/notes") <$> getAppFilesDir
  notes <- newIORef . either (const []) (Text.lines . Text.decodeUtf8Lenient)
    =<< (try (BS.readFile file) :: IO (Either IOException BS.ByteString))
  let save = BS.writeFile file . Text.encodeUtf8 . Text.unlines =<< readIORef notes
      addNote line = modifyIORef' notes (<> [line]) >> save
  (more, less, ten, reset, notify, add, typed) <- runActionM actions $ (,,,,,,)
    <$> createAction (modifyIORef' count (+ 1))
    <*> createAction (modifyIORef' count (subtract 1))
    <*> createAction (modifyIORef' count (+ 10))
    <*> createAction (writeIORef count 0 >> cancelNotification "count")
    <*> createAction (readIORef count >>= \n -> showNotification Notification
          { notificationKey = "count"
          , notificationChannel = "Count"
          , notificationIcon = "ic_count"
          , notificationTitle = "Count"
          , notificationLines = [Text.pack (show n)]
          , notificationKind = MessageNotification
          })
    <*> createAction (readIORef draft >>= addNote >> writeIORef draft Text.empty)
    <*> createOnChange (writeIORef draft)
  let view n note written = column
        [ LongPressable reset . Tappable ten $
            Styled defaultStyle { wsPadding = Just 16 } (text ("Count: " <> Text.pack (show n)))
        , row [button "+" more, button "-" less, button "Notify" notify]
        , TextInput TextInputConfig
            { tiInputType = InputText
            , tiHint = "A note"
            , tiValue = note
            , tiOnChange = typed
            , tiFontConfig = Nothing
            , tiTextColor = Nothing
            , tiAutoFocus = True
            }
        , button "Add" add
        , Styled defaultStyle { wsWeight = Just 1, wsKeepAtEnd = Just True }
            (LazyColumn [keyedItem i (Styled defaultStyle { wsPadding = Just 8 } (text line)) | (i, line) <- zip [0 ..] written])
        ]
  startMobileApp MobileApp
    { maContext = loggingMobileContext
        { onNotificationOpened = \key ->
            onNotificationOpened loggingMobileContext key >> addNote ("Opened from the " <> key <> " notification")
        }
    , maView = \_ -> view <$> readIORef count <*> readIORef draft <*> readIORef notes
    , maActionState = actions
    }
