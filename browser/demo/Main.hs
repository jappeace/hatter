{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | A Hatter app for trying the browser platform: a counter that a tap
-- sets back to 0, the page's width, whether the tab is shown (the last
-- lifecycle event), a text field, and a list kept at its end as notes come
-- in. The notes and the note being written are kept in
-- the app's files, so they are there again after a reload.
module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hatter (LifecycleEvent (..), MobileApp (..), MobileContext (..), createAction, createOnChange, loggingMobileContext, newActionState, runActionM)
import Hatter.DeviceInfo (DeviceInfo (..), getDeviceInfo)
import Hatter.Browser (runBrowser)
import Hatter.FilesDir (getAppFilesDir)
import Hatter.Widget

foreign export javascript "start" start :: IO ()

start :: IO ()
start = runBrowser demo

-- | The page starts the app with 'start'.
main :: IO ()
main = pure ()

demo :: IO MobileApp
demo = do
  actions <- newActionState
  count <- newIORef (0 :: Int)
  life <- newIORef Create
  dir <- getAppFilesDir
  let kept name = either (const Text.empty) Text.decodeUtf8Lenient
        <$> (try (BS.readFile (dir <> name)) :: IO (Either IOException BS.ByteString))
      keep name = BS.writeFile (dir <> name) . Text.encodeUtf8
  draft <- newIORef =<< kept "/draft"
  notes <- newIORef . Text.lines =<< kept "/notes"
  let write note = writeIORef draft note >> keep "/draft" note
  (more, less, none, add, typed) <- runActionM actions $ (,,,,)
    <$> createAction (modifyIORef' count (+ 1))
    <*> createAction (modifyIORef' count (subtract 1))
    <*> createAction (writeIORef count 0)
    <*> createAction (do
          note <- readIORef draft
          modifyIORef' notes (<> [note])
          keep "/notes" . Text.unlines =<< readIORef notes
          write Text.empty)
    <*> createOnChange write
  let view n note written device event = column
        [ Tappable none (Styled defaultStyle { wsPadding = Just 16 } (text ("Count: " <> Text.pack (show n))))
        , row [button "+" more, button "-" less]
        , text (Text.pack (show (diScreenWidth device)) <> " wide")
        , text (Text.pack (show event))
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
  pure MobileApp
    { maContext = loggingMobileContext { onLifecycle = writeIORef life }
    , maView = \_ -> view <$> readIORef count <*> readIORef draft <*> readIORef notes <*> getDeviceInfo <*> readIORef life
    , maActionState = actions
    }
