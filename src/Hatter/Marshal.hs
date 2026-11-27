-- | Text, paths and bytes to and from the platform bridges, for Hatter and
-- the platforms' own packages. Text goes in UTF-8, which all of them take,
-- whatever the locale. Paths go in the file system's encoding, as Haskell
-- decoded them, so they name the same files.
module Hatter.Marshal
  ( withText
  , withMaybeText
  , peekText
  , peekMaybeText
  , withPath
  , newPath
  , peekPath
  , peekBytes
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Foreign.C.String (CString)
import Foreign.C.Types (CInt)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import Unwitch.Convert.CInt qualified as CInt

withText :: Text -> (CString -> IO a) -> IO a
withText = BS.useAsCString . Text.encodeUtf8

-- | As 'withText', with a null pointer for 'Nothing'.
withMaybeText :: Maybe Text -> (CString -> IO a) -> IO a
withMaybeText = maybe ($ nullPtr) withText

-- | Bytes that aren't UTF-8 become replacement characters.
peekText :: CString -> IO Text
peekText = fmap Text.decodeUtf8Lenient . BS.packCString

-- | As 'peekText', 'Nothing' for a null pointer.
peekMaybeText :: CString -> IO (Maybe Text)
peekMaybeText cstr
  | cstr == nullPtr = pure Nothing
  | otherwise = Just <$> peekText cstr

withPath :: FilePath -> (CString -> IO a) -> IO a
withPath path action = do
  encoding <- getFileSystemEncoding
  GHC.withCString encoding path action

-- | As 'withPath', for C that keeps it: never freed.
newPath :: FilePath -> IO CString
newPath path = do
  encoding <- getFileSystemEncoding
  GHC.newCString encoding path

peekPath :: CString -> IO FilePath
peekPath cstr = do
  encoding <- getFileSystemEncoding
  GHC.peekCString encoding cstr

-- | A copy of so many bytes, none for a null pointer.
peekBytes :: Ptr a -> CInt -> IO ByteString
peekBytes ptr len
  | ptr == nullPtr || len <= 0 = pure BS.empty
  | otherwise = BS.packCStringLen (castPtr ptr, CInt.toInt len)
