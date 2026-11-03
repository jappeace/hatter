-- | Text crosses the bridges in UTF-8, whatever the locale.
module Test.EncodingTests
  ( encodingTests
  ) where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text.Encoding qualified as Text
import Hatter (MobileApp(..), haskellOnUITextChange)
import Hatter.Action (OnChange(..), createOnChange, newActionState, runActionM)
import Hatter.AppContext (AppContext(..), derefAppContext)
import Hatter.Dialog (DialogConfig(..), showDialog)
import Hatter.Lifecycle (defaultMobileContext)
import Hatter.Render (renderWidget)
import Hatter.UIBridge (openFile)
import Hatter.Widget (InputType(..), TextInputConfig(..), Widget(..), text)
import System.Info (os)
import Test.Helpers (captureStderr, inCLocale, withActions, withAppContext)

encodingTests :: TestTree
encodingTests = testGroup "Text encoding"
  [ testCase "text shown goes to the platform in UTF-8 in the C locale" $ do
      ((), rs) <- withActions (pure ())
      ((), out) <- captureStderr (inCLocale (renderWidget rs (text "Liebe \x1F60D")))
      assertBool out ("value=\"Liebe \x1F60D\"" `isInfixOf` out)

  , testCase "text typed comes from the platform in UTF-8 in the C locale" $ do
      typed <- newIORef ""
      actions <- newActionState
      onChange <- runActionM actions (createOnChange (writeIORef typed))
      let field = TextInput TextInputConfig
            { tiInputType = InputText, tiHint = "", tiValue = "", tiOnChange = onChange
            , tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          app = MobileApp
            { maContext = defaultMobileContext, maView = \_ -> pure field, maActionState = actions }
      _ <- captureStderr $ withAppContext app $ \ctx ->
        BS.useAsCString (Text.encodeUtf8 "\x1F60D") $ \typing ->
          inCLocale (haskellOnUITextChange ctx (fromIntegral (onChangeId onChange)) typing)
      readIORef typed >>= (@?= "\x1F60D")

  , testCase "a dialog goes to the platform in UTF-8 in the C locale" $ do
      actions <- newActionState
      let app = MobileApp
            { maContext = defaultMobileContext, maView = \_ -> pure (text ""), maActionState = actions }
          dialog = DialogConfig
            { dcTitle = "\x1F60D", dcMessage = "", dcButton1 = "OK", dcButton2 = Nothing, dcButton3 = Nothing }
      ((), out) <- captureStderr $ withAppContext app $ \ctx -> do
        dialogs <- acDialogState <$> derefAppContext ctx
        inCLocale (showDialog dialogs dialog (\_ -> pure ()))
      assertBool out ("title=\"\x1F60D\"" `isInfixOf` out)

  , testCase "on Windows, a file to show goes to the platform in UTF-8" $
      -- Its file names are text, which every platform takes in UTF-8.
      when (os == "mingw32") $ do
        let path = "C:\\caf\233 \x1F60D.txt"
        ((), out) <- captureStderr (openFile path)
        assertBool out (("openFile(\"" <> path <> "\")") `isInfixOf` out)
  ]
