[![CI](https://img.shields.io/github/actions/workflow/status/jappeace/hatter/ci.yaml?branch=master)](https://github.com/jappeace/hatter/actions)
[![Hackage version](https://img.shields.io/hackage/v/hatter.svg?label=Hackage)](https://hackage.haskell.org/package/hatter) 

>  Why is a raven like a writing-desk?

![hatter](./hatter.png)

# Hatter
It's like flutter but instead of dart, haskell!

Write native mobile apps in Haskell.
This works similar to react native where we have
tight bindings on the existing UI frameworks
provided by android and IOS.

This project cross-compiles a Haskell library to Android (APK) and iOS (static library / IPA),
with a thin platform-native UI layer (Kotlin for Android, Swift for iOS).
There is support for android wear and wearOS as well,
because I personally want to build apps for those. 
IOS and Android support was just a side effect.

Supports native:

+ android
+ android wearable
+ IOS
+ WearOS (IOS on wearables)

The library fully controls the UI.
This is different from say Simplex chat where they call into the library to do Haskell from dirty java/swift code.
This library should've written all swift/java code you'll ever need,
so you can focus on your sweet Haskell.

Haskell is a fantastic language for UI.
Having strong type safety around callbacks and widgets 
makes it a lot easier to write them.
I basically copied flutters' approach to encoding UI,
but in flutter it's a fair bit of guess work, 
it becomes /very/ nice in Haskell however.
I've been many times annoyed at the ~~garbage~~ languages
they keep shoving into our face for UI.
With [vibes](https://jappie.me/haskell-vibes.html) in hand I put my malice
into crafting something good.
Flutter is already pretty good, but the syntax is complex,
and it has many inherited footguns from Java.
I think I made here what flutter wanted to be.

Please note this is /new/ software, I've encountered a fair few bugs
while using it (and addressed them).
I'd not throw it into production yet 
(unless you really hate java/swift with a passion),
you can see my confidence by the version of the release.
If it reaches a 1.0.0 I'm confident enough that I would use it in production.


# How to use

## Writing your app

Your app is a Haskell module with a `main :: IO (Ptr AppContext)`.
You define a `MobileApp` record and pass it to `startMobileApp`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.Text qualified as Text
import Foreign.Ptr (Ptr)
import Hatter
  ( startMobileApp, MobileApp(..)
  , loggingMobileContext
  , newActionState, runActionM, createAction, Action
  )
import Hatter.AppContext (AppContext)
import Hatter.Widget

main :: IO (Ptr AppContext)
main = do
  actionState <- newActionState
  counter <- newIORef (0 :: Int)
  increment <- runActionM actionState $
    createAction (modifyIORef' counter (+ 1))
  startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \_userState -> do
        n <- readIORef counter
        pure $ column
          [ text $ "Count: " <> Text.pack (show n)
          , button "+" increment
          ]
    , maActionState = actionState
    }
```

`maView` is called on every render cycle and returns a `Widget` tree.
Button taps (and other events) fire `Action` handles created via `runActionM`,
then the framework re-renders automatically.



## Building for Android

Requires Nix. The build cross-compiles your Haskell to a `.so` shared library
and packages it into an APK with the Java UI layer.

### 1. Build the APK (hatter demo)

```bash
nix-build nix/apk.nix
```

This produces `result/hatter.apk` containing both arm64-v8a and armeabi-v7a architectures.

To build just the shared library for a single architecture:

```bash
nix-build nix/android.nix                               # aarch64 (default)
nix-build nix/android.nix --arg androidArch '"armv7a"'   # armv7a
```

### 2. Install

```bash
adb install result/hatter.apk
```

### 3. Consumer projects

Consumer apps create their own nix files that import hatter's `nix/lib.nix`
builder functions. Pin hatter via [npins](https://github.com/andir/npins)
(or `builtins.fetchGit`) and write thin wrappers.

**`nix/android.nix`** — build the shared library:

```nix
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/Main.hs
}:
let
  hatterSrc = sources.hatter;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources androidArch; };

  crossDeps = import "${hatterSrc}/nix/cross-deps.nix" {
    inherit sources androidArch hatterSrc;
    # Option A: point to your .cabal file (uses IFD to extract deps)
    consumerCabalFile = ../your-app.cabal;
    # Option B: inline cabal2nix function
    # consumerCabal2Nix = { mkDerivation, base, text, aeson, lib }:
    #   mkDerivation {
    #     pname = "your-app"; version = "0.1.0.0";
    #     libraryHaskellDepends = [ base text aeson ];
    #     license = lib.licenses.mit;
    #   };
  };
in
lib.mkAndroidLib {
  inherit hatterSrc mainModule crossDeps;
  pname = "your-app-android";
  javaPackageName = "com.example.yourapp";
  # GHC uses one-shot compilation by default; consumer modules need --make
  extraGhcFlags = ["--make" "-no-link"];
  extraModuleCopy = ''
    # Remove hatter source files — hatter is pre-compiled in the package DB
    rm -f Hatter.hs
    rm -rf Hatter/
    # Copy your app's modules
    mkdir -p YourApp
    cp ${../src/YourApp/App.hs} YourApp/App.hs
  '';
  extraLinkObjects = [
    "$(pwd)/YourApp/App.o"
  ];
}
```

**`nix/apk.nix`** — package into an APK:

```nix
{ sources ? import ../npins, androidArch ? "aarch64" }:
let
  hatterSrc = sources.hatter;
  abiDir = { aarch64 = "arm64-v8a"; armv7a = "armeabi-v7a"; }.${androidArch};
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources androidArch; };
  sharedLib = import ./android.nix { inherit sources androidArch; };
in
lib.mkApk {
  sharedLibs = [{ lib = sharedLib; inherit abiDir; }];
  androidSrc = ../android;                          # your AndroidManifest.xml + res/
  baseJavaSrc = "${hatterSrc}/android/java";        # hatter's Java sources
  apkName = "your-app.apk";
  name = "your-app-apk";
}
```

**`install.sh`** — build and install on a phone:

```bash
#!/usr/bin/env bash
set -euo pipefail
adb install "$(nix-build nix/apk.nix)/your-app.apk"
```

**`install-wear.sh`** — build and install on a Wear OS watch (armv7a):

```bash
#!/usr/bin/env bash
set -euo pipefail
adb install "$(nix-build nix/apk.nix --argstr androidArch armv7a)/your-app.apk"
```

Your `android/` directory needs `AndroidManifest.xml` and `res/` with your
app's name, icon, and theme. Your `MainActivity` just extends `HatterActivity`:

```java
package com.example.yourapp;
import me.jappie.hatter.HatterActivity;
public class MainActivity extends HatterActivity {}
```

### How it works under the hood

The Java activity (`HatterActivity`) loads the `.so` via `System.loadLibrary`,
which triggers `JNI_OnLoad` in `cbits/jni_bridge.c`. That initializes the GHC RTS,
runs your Haskell `main`, and stores the returned `AppContext` pointer.
When `onCreate` fires, Java calls `renderUI` through JNI, which invokes your `maView`
and the framework translates the `Widget` tree into Android `View` calls.

You never need to write Java — `HatterActivity` handles all the native UI,
permissions, camera, location, etc.

## Building for iOS

Requires macOS with Nix. The build produces a static `.a` library that links into
an Xcode project via a Swift bridge.

### 1. Build the static library (hatter demo)

```bash
nix-build nix/ios.nix                    # device
nix-build nix/ios.nix --arg simulator true  # simulator
```

This produces `result/lib/libHatter.a` and headers in `result/include/`.

### 2. Set up and run in Xcode

The nix build stages an Xcode project with the pre-built library via `mkSimulatorApp`.
A setup script copies the (read-only) nix output to a writable directory and
generates the Xcode project:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET="device"
[ "${1:-}" = "--simulator" ] && TARGET="simulator"

if [ "$TARGET" = "simulator" ]; then
  result=$(nix-build nix/ios-app.nix)        # your wrapper calling lib.mkSimulatorApp
else
  result=$(nix-build nix/ios-device-app.nix)
fi

rm -rf ios-project
cp -r "$result/share/ios/." ios-project/
chmod -R u+w ios-project

cd ios-project
xcodegen generate

echo "Open ios-project/Hatter.xcodeproj in Xcode, then Product → Run."
```

Configure signing in Xcode (team, bundle ID, provisioning profile), then
build and run on a device or simulator.

### 3. Consumer iOS projects

Consumer apps create their own nix files, similar to Android.

**`nix/ios.nix`**:

```nix
{ sources ? import ../npins, simulator ? false, mainModule ? ../app/Main.hs }:
let
  hatterSrc = sources.hatter;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources; };

  iosDeps = import "${hatterSrc}/nix/ios-deps.nix" {
    inherit sources;
    consumerCabalFile = ../your-app.cabal;
  };
in
lib.mkIOSLib {
  inherit hatterSrc mainModule simulator;
  pname = "your-app-ios";
  crossDeps = iosDeps;
  extraModuleCopy = ''
    mkdir -p YourApp
    cp ${../src/YourApp/App.hs} YourApp/App.hs
  '';
}
```

**`nix/ios-app.nix`** — stage the Xcode project (simulator):

```nix
{ sources ? import ../npins }:
let
  hatterSrc = sources.hatter;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources; };
  iosLib = import ./ios.nix { inherit sources; simulator = true; };
in
lib.mkSimulatorApp {
  inherit iosLib;
  iosSrc = "${hatterSrc}/ios";
  name = "your-app-ios-simulator";
}
```

**`nix/ios-device-app.nix`** — stage the Xcode project (device):

```nix
{ sources ? import ../npins }:
let
  hatterSrc = sources.hatter;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources; };
  iosLib = import ./ios.nix { inherit sources; simulator = false; };
in
lib.mkSimulatorApp {
  inherit iosLib;
  iosSrc = "${hatterSrc}/ios";
  name = "your-app-ios-device";
}
```

### How it works under the hood

The Swift bridge (`ios/Hatter/HaskellBridge.swift`) calls `hs_init` and
`haskellRunMain` to boot the GHC RTS and run your Haskell `main`.
It then sets up all the platform bridges (permissions, camera, location, etc.)
and calls `haskellRenderUI` when SwiftUI requests a view update.

The bridging header (`Hatter-Bridging-Header.h`) exposes the C FFI functions
to Swift. The `project.yml` links against the required system frameworks
(CoreLocation, CoreBluetooth, AVFoundation, WebKit, etc.).

## Building for watchOS

```bash
nix-build nix/watchos.nix
```

Works the same as iOS — produces a static library for watchOS.
The `watchos/` directory contains the WatchKit app structure.

## Desktop development

For fast iteration, build and test natively:

```bash
nix-shell
cabal build all
cabal test all
```

The desktop build uses stub C bridges that simulate platform responses
(e.g. permissions always granted, location returns fixed coordinates).
This lets you develop and test your app logic without a device.

# Contributing

Always make sure to include tests.
If we deal with platform integration or add native code
we need tests in the simulator / emulator
as well to ensure new builds don't crash.

Sometimes we're able to make some rudmentary tests
on screen as well.

In general we can assume if something doesn't
have tests it may as well not exist.

## Integration requests

Please find or make issues about integration requests.
I can prioritize adding these first.
The real time sink for these is usually testing
out if the integration works.
Animations for example required several iterations,
whereas HTTP worked on first try.

The claudes should be able to mostly implement this stuff
especially if you use [vibes](https://github.com/jappeace/vibes).

I think you can implement this stuff by hand
as well but I find it way to tedious.
