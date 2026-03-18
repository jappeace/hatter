module Main where

import HaskellMobile (loggingMobileContext, platformLog)
import HaskellMobile.Lifecycle (LifecycleEvent(..), MobileContext(onLifecycle))

-- | Demonstrate the lifecycle callback API by firing all 7 events
-- through a logging context. On desktop this prints to stderr.
main :: IO ()
main = do
  platformLog "Desktop sample app starting"
  let ctx = loggingMobileContext
  mapM_ (onLifecycle ctx)
    [ Create
    , Start
    , Resume
    , Pause
    , Stop
    , Destroy
    , LowMemory
    ]
  platformLog "Desktop sample app finished"
