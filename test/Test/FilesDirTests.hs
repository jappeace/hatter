{-# LANGUAGE ForeignFunctionInterface #-}
-- | Unit tests for the app files directory bridge.
module Test.FilesDirTests
  ( filesDirTests
  ) where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Foreign.C.String (CString, newCString)
import System.Directory (removeFile, getTemporaryDirectory)
import System.FilePath ((</>))
import System.Info (os)
import Hatter.FilesDir (getAppFilesDir)

foreign import ccall "setAppFilesDir" c_setAppFilesDir :: CString -> IO ()

-- | Tests run sequentially (via 'sequentialTestGroup') because they
-- mutate a process-wide C global.
filesDirTests :: TestTree
filesDirTests = sequentialTestGroup "FilesDir" AllFinish
  [ testCase "getAppFilesDir returns non-empty path" $ do
      path <- getAppFilesDir
      assertBool "path should not be empty" (not (null path))
  , testCase "setAppFilesDir / getAppFilesDir roundtrip" $ do
      tmpDir <- getTemporaryDirectory
      cstr <- newCString tmpDir
      c_setAppFilesDir cstr
      path <- getAppFilesDir
      path @?= tmpDir
      -- Restore desktop default
      cstrDot <- newCString "."
      c_setAppFilesDir cstrDot
  , testCase "on Windows, a files dir beyond ASCII is the folder the platform named" $
      -- Its file names are text, which every platform hands over in UTF-8.
      when (os == "mingw32") $ do
        tmpDir <- getTemporaryDirectory
        let named = tmpDir </> "caf\233 \x1F60D"
        path <- BS.useAsCString (Text.encodeUtf8 (Text.pack named)) $ \given ->
          c_setAppFilesDir given *> getAppFilesDir <* (newCString "." >>= c_setAppFilesDir)
        path @?= named
  , testCase "can write file to app files dir" $ do
      dir <- getAppFilesDir
      let testFile = dir </> "hatter_filesdir_test.txt"
          testContent = "hatter-test-ok"
      writeFile testFile testContent
      result <- readFile testFile
      result @?= testContent
      removeFile testFile
  ]
