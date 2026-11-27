{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
-- | A key for the app's database from the platform's keystore, made the
-- first time and the same ever after on this device.
module Hatter.DatabaseKey
  ( DatabaseKey (..)
  , databaseKey
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Foreign.C.Types (CInt (..), CUChar)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr, castPtr)

data DatabaseKey
  = NoKeyStore
    -- ^ A platform without one.
  | KeyStoreFailed
    -- ^ One that gave no key, so a database kept with it can't be opened.
  | DatabaseKey ByteString
  deriving (Eq, Show)

foreign import ccall "getDatabaseKey" c_getDatabaseKey :: Ptr CUChar -> IO CInt

keyBytes :: Int
keyBytes = 32

databaseKey :: IO DatabaseKey
databaseKey = allocaArray keyBytes $ \buffer -> c_getDatabaseKey buffer >>= \case
  1 -> DatabaseKey <$> BS.packCStringLen (castPtr buffer, keyBytes)
  0 -> pure NoKeyStore
  _ -> pure KeyStoreFailed
