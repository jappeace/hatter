{-# LANGUAGE ForeignFunctionInterface #-}
module HaskellMobile
  ( main
  , haskellInit
  , haskellGreet
  )
where

import Foreign.C.String (CString, newCString, peekCString)

main :: IO ()
main = putStrLn "hello, world flaky"

-- | Placeholder for RTS initialization, called from JNI_OnLoad
haskellInit :: IO ()
haskellInit = putStrLn "Haskell RTS initialized"

foreign export ccall haskellInit :: IO ()

-- | Takes a name as CString, returns "Hello from Haskell, <name>!" as CString.
-- Caller is responsible for freeing the returned CString.
haskellGreet :: CString -> IO CString
haskellGreet cname = do
  name <- peekCString cname
  newCString ("Hello from Haskell, " ++ name ++ "!")

foreign export ccall haskellGreet :: CString -> IO CString
