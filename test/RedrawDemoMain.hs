{-# LANGUAGE OverloadedStrings #-}
-- | Self-contained redraw demo app.
--
-- Proves that background threads can trigger UI re-renders via
-- 'userRequestRedraw'. A background thread increments a counter
-- every 3 seconds and calls requestRedraw; the view logs each
-- rebuild with the new counter value.
--
-- On desktop the redraw stub calls haskellRenderUI directly.
-- On mobile it posts to the main/UI thread.
module Main where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.Text (pack)
import Foreign.Ptr (Ptr)
import Hatter
  ( MobileApp(..)
  , UserState(..)
  , startMobileApp
  , newActionState
  , loggingMobileContext
  , platformLog
  )
import Hatter.AppContext (AppContext)
import Hatter.Widget (TextConfig(..), Widget(..), column)

main :: IO (Ptr AppContext)
main = do
  platformLog "Redraw demo registered"
  actionState <- newActionState
  counter <- newIORef (0 :: Int)
  -- IORef to store requestRedraw callback from UserState
  redrawRef <- newIORef (pure () :: IO ())
  -- Track whether background thread has been started
  startedRef <- newIORef False
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = redrawView counter redrawRef startedRef
    , maActionState = actionState
    }

-- | View function: stores requestRedraw, kicks off background updater
-- on first render, and logs each rebuild with the current counter.
redrawView :: IORef Int -> IORef (IO ()) -> IORef Bool -> UserState -> IO Widget
redrawView counter redrawRef startedRef userState = do
  -- Store requestRedraw for background thread
  writeIORef redrawRef (userRequestRedraw userState)
  -- On first render, kick off background updater
  started <- readIORef startedRef
  when (not started) $ do
    writeIORef startedRef True
    void $ forkIO $ backgroundUpdater counter redrawRef
  count <- readIORef counter
  platformLog ("view rebuilt: count=" <> pack (show count))
  pure $ column [Text TextConfig
    { tcLabel = "Count: " <> pack (show count)
    , tcFontConfig = Nothing
    }]

-- | Background thread that increments the counter every 3 seconds
-- and requests a redraw. Runs 3 ticks.
backgroundUpdater :: IORef Int -> IORef (IO ()) -> IO ()
backgroundUpdater counter redrawRef = do
  forM_ [1 :: Int .. 3] $ \tick -> do
    threadDelay 3_000_000  -- 3 seconds
    modifyIORef' counter (const tick)
    platformLog ("Background tick: " <> pack (show tick))
    requestRedraw <- readIORef redrawRef
    requestRedraw
