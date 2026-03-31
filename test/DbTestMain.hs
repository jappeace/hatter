-- | Emulator/simulator test entry point for SQLite integration.
--
-- Registers a MobileApp whose lifecycle Create handler opens a test
-- database, inserts a row, reads it back, and logs the result via
-- platformLog.  The emulator/simulator test scripts check logcat/os_log
-- for "SQLite roundtrip OK".
module Main where

import Data.Text (pack)
import HaskellMobile
  ( MobileApp(..)
  , MobileContext(..)
  , LifecycleEvent(..)
  , runMobileApp
  , loggingMobileContext
  , platformLog
  )
import HaskellMobile.Widget qualified as W
import HaskellMobile.Database
  ( withDatabase
  , execute
  , withStatement
  , step
  , columnText
  , bindText
  , sqliteRow
  )

main :: IO ()
main = runMobileApp MobileApp
  { maContext = MobileContext
      { onLifecycle = dbTestLifecycle
      }
  , maView = pure (W.Text (pack "SQLite test"))
  }

dbTestLifecycle :: LifecycleEvent -> IO ()
dbTestLifecycle Create = do
  -- Also run the default logging so "Lifecycle: Create" appears
  onLifecycle loggingMobileContext Create
  sqliteRoundtrip
dbTestLifecycle event =
  onLifecycle loggingMobileContext event

sqliteRoundtrip :: IO ()
sqliteRoundtrip = do
  result <- withDatabase "test.db" $ \db -> do
    execute db "CREATE TABLE IF NOT EXISTS test_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    execute db "INSERT OR REPLACE INTO test_kv (key, value) VALUES ('hello', 'world')"
    withStatement db "SELECT value FROM test_kv WHERE key = ?" $ \stmt -> do
      bindText stmt 1 "hello"
      rc <- step stmt
      if rc == sqliteRow
        then columnText stmt 0
        else pure ""
  if result == "world"
    then platformLog (pack "SQLite roundtrip OK")
    else platformLog (pack ("SQLite roundtrip FAIL: expected 'world', got '" ++ result ++ "'"))
