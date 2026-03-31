{-# LANGUAGE ForeignFunctionInterface #-}
-- | Generic SQLite FFI bindings for haskell-mobile.
--
-- Uses raw FFI bindings to the bundled sqlite3 amalgamation.
-- Databases are stored under the app files directory returned by
-- @get_app_files_dir()@.
--
-- On Android this is set via JNI @setFilesDir@ before lifecycle Create.
-- On iOS it is set from Swift @FileManager.documentDirectory@.
-- On desktop it falls back to @TMPDIR@ or @\/tmp@.
module HaskellMobile.Database
  ( -- * Types
    Sqlite3
  , Sqlite3Stmt
    -- * Connection
  , withDatabase
    -- * Execution
  , execute
    -- * Prepared statements
  , withStatement
  , step
  , columnText
  , columnDouble
  , columnInt
  , bindText
  , bindDouble
  , bindInt
    -- * Constants
  , sqliteRow
  , sqliteDone
    -- * Platform
  , getAppFilesDir
  )
where

import Foreign.C.String (CString, withCString, peekCString)
import Foreign.C.Types (CInt(..), CDouble(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr, FunPtr, nullFunPtr)
import Foreign.Storable (peek)

-- | Opaque SQLite database handle.
data Sqlite3
-- | Opaque SQLite statement handle.
data Sqlite3Stmt

-- SQLite FFI
foreign import ccall "sqlite3_open"
  c_sqlite3_open :: CString -> Ptr (Ptr Sqlite3) -> IO CInt

foreign import ccall "sqlite3_close"
  c_sqlite3_close :: Ptr Sqlite3 -> IO CInt

foreign import ccall "sqlite3_exec"
  c_sqlite3_exec :: Ptr Sqlite3 -> CString -> FunPtr () -> Ptr () -> Ptr CString -> IO CInt

foreign import ccall "sqlite3_prepare_v2"
  c_sqlite3_prepare_v2 :: Ptr Sqlite3 -> CString -> CInt -> Ptr (Ptr Sqlite3Stmt) -> Ptr (Ptr ()) -> IO CInt

foreign import ccall "sqlite3_step"
  c_sqlite3_step :: Ptr Sqlite3Stmt -> IO CInt

foreign import ccall "sqlite3_finalize"
  c_sqlite3_finalize :: Ptr Sqlite3Stmt -> IO CInt

foreign import ccall "sqlite3_column_text"
  c_sqlite3_column_text :: Ptr Sqlite3Stmt -> CInt -> IO CString

foreign import ccall "sqlite3_column_double"
  c_sqlite3_column_double :: Ptr Sqlite3Stmt -> CInt -> IO CDouble

foreign import ccall "sqlite3_column_int"
  c_sqlite3_column_int :: Ptr Sqlite3Stmt -> CInt -> IO CInt

foreign import ccall "sqlite3_bind_text"
  c_sqlite3_bind_text :: Ptr Sqlite3Stmt -> CInt -> CString -> CInt -> Ptr () -> IO CInt

foreign import ccall "sqlite3_bind_double"
  c_sqlite3_bind_double :: Ptr Sqlite3Stmt -> CInt -> CDouble -> IO CInt

foreign import ccall "sqlite3_bind_int"
  c_sqlite3_bind_int :: Ptr Sqlite3Stmt -> CInt -> CInt -> IO CInt

foreign import ccall "get_app_files_dir"
  c_get_app_files_dir :: IO CString

-- | SQLITE_ROW (100) — 'step' returns this when a row is available.
sqliteRow :: CInt
sqliteRow = 100

-- | SQLITE_DONE (101) — 'step' returns this when the statement is finished.
sqliteDone :: CInt
sqliteDone = 101

-- | Get the platform-specific app files directory.
getAppFilesDir :: IO FilePath
getAppFilesDir = c_get_app_files_dir >>= peekCString

-- | Open a database at @\<appFilesDir\>\/\<name\>@, run an action, then close it.
withDatabase :: String -> (Ptr Sqlite3 -> IO a) -> IO a
withDatabase name action = do
  dir <- getAppFilesDir
  let path = dir ++ "/" ++ name
  db <- alloca $ \dbPtr -> do
    rc <- withCString path $ \cpath ->
      c_sqlite3_open cpath dbPtr
    if rc /= 0
      then error $ "Failed to open database: " ++ path
      else peek dbPtr
  result <- action db
  _ <- c_sqlite3_close db
  pure result

-- | Execute a SQL statement with no result rows.
execute :: Ptr Sqlite3 -> String -> IO ()
execute db sql =
  withCString sql $ \csql -> do
    rc <- c_sqlite3_exec db csql nullFunPtr nullPtr nullPtr
    if rc /= 0
      then error $ "execute failed with code: " ++ show rc ++ " for: " ++ sql
      else pure ()

-- | Prepare a SQL statement, run an action with it, then finalize it.
withStatement :: Ptr Sqlite3 -> String -> (Ptr Sqlite3Stmt -> IO a) -> IO a
withStatement db sql action =
  alloca $ \stmtPtr -> do
    rc <- withCString sql $ \csql ->
      c_sqlite3_prepare_v2 db csql (-1) stmtPtr nullPtr
    if rc /= 0
      then error $ "prepare failed with code: " ++ show rc ++ " for: " ++ sql
      else do
        stmt <- peek stmtPtr
        result <- action stmt
        _ <- c_sqlite3_finalize stmt
        pure result

-- | Step the statement. Returns the sqlite3 result code
-- ('sqliteRow' if a row is available, 'sqliteDone' when finished).
step :: Ptr Sqlite3Stmt -> IO CInt
step = c_sqlite3_step

-- | Read a text column (0-indexed). The returned string is only valid
-- until the next 'step' or 'c_sqlite3_finalize'.
columnText :: Ptr Sqlite3Stmt -> CInt -> IO String
columnText stmt col = do
  cstr <- c_sqlite3_column_text stmt col
  if cstr == nullPtr
    then pure ""
    else peekCString cstr

-- | Read a double column (0-indexed).
columnDouble :: Ptr Sqlite3Stmt -> CInt -> IO Double
columnDouble stmt col = do
  CDouble d <- c_sqlite3_column_double stmt col
  pure d

-- | Read an integer column (0-indexed).
columnInt :: Ptr Sqlite3Stmt -> CInt -> IO Int
columnInt stmt col = do
  v <- c_sqlite3_column_int stmt col
  pure (fromIntegral v)

-- | Bind a text value to a parameter (1-indexed).
-- Uses SQLITE_TRANSIENT semantics: the caller must ensure the CString
-- remains valid until after 'step'.  'withCString' in the calling code
-- satisfies this.
bindText :: Ptr Sqlite3Stmt -> CInt -> String -> IO ()
bindText stmt idx val =
  withCString val $ \cval -> do
    _ <- c_sqlite3_bind_text stmt idx cval (-1) nullPtr
    pure ()

-- | Bind a double value to a parameter (1-indexed).
bindDouble :: Ptr Sqlite3Stmt -> CInt -> Double -> IO ()
bindDouble stmt idx val = do
  _ <- c_sqlite3_bind_double stmt idx (CDouble val)
  pure ()

-- | Bind an integer value to a parameter (1-indexed).
bindInt :: Ptr Sqlite3Stmt -> CInt -> Int -> IO ()
bindInt stmt idx val = do
  _ <- c_sqlite3_bind_int stmt idx (fromIntegral val)
  pure ()
