{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
-- | Picture files read and written again, from any thread.  Without a
-- platform's implementation, no picture is read.
module Hatter.Picture
  ( picturePixels
  , PictureKind (..)
  , shrinkPicture
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Unsafe qualified as BS
import Data.Int (Int32)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import Hatter.Marshal (withPath)

foreign import ccall safe "picture_pixels"
  c_picturePixels :: CString -> Int32 -> Ptr Int32 -> Ptr Int32 -> IO (Ptr Word8)

foreign import ccall safe "picture_shrink"
  c_pictureShrink :: CString -> CString -> CInt -> IO CInt

-- | What a shrunk picture was written as.
data PictureKind = Jpeg | Png
  deriving (Show, Eq)

-- | A picture written again to a file, turned the way its camera says, no
-- longer than so many pixels on either side and without its metadata,
-- such as where it was taken, if the first file is one.
shrinkPicture :: FilePath -> FilePath -> Int -> IO (Maybe PictureKind)
shrinkPicture path out longest =
  withPath path $ \cpath -> withPath out $ \cout ->
    c_pictureShrink cpath cout (fromIntegral longest) >>= \case
      1 -> pure (Just Jpeg)
      2 -> pure (Just Png)
      _ -> pure Nothing

-- | Width, height and RGBA pixels, row by row and not premultiplied, of a
-- picture turned the way its camera says, halved until it has at most so
-- many pixels, if the file is one.
picturePixels :: FilePath -> Int -> IO (Maybe (Int, Int, ByteString))
picturePixels path most =
  withPath path $ \cpath -> alloca $ \pw -> alloca $ \ph -> do
    pixels <- c_picturePixels cpath (fromIntegral most) pw ph
    if pixels == nullPtr
      then pure Nothing
      else do
        w <- fromIntegral <$> peek pw
        h <- fromIntegral <$> peek ph
        bytes <- BS.unsafePackMallocCStringLen (castPtr pixels, w * h * 4)
        pure (Just (w, h, bytes))
