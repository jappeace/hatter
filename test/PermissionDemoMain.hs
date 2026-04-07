{-# LANGUAGE OverloadedStrings #-}
-- | Mobile entry point for the permission-demo test app.
--
-- Used by the emulator and simulator permission integration tests.
-- Starts directly in permission-demo mode so no runtime switching is needed.
module Main where

import HaskellMobile (runMobileApp, platformLog, globalPermissionState)
import HaskellMobile.App (permissionDemoApp)

main :: IO ()
main = do
  runMobileApp (permissionDemoApp globalPermissionState)
  platformLog "Permission demo app registered"
