[![CI](https://img.shields.io/github/actions/workflow/status/jappeace/haskell-mobile/ci.yaml?branch=master)](https://github.com/jappeace/haskell-mobile/actions)

>  Why is a raven like a writing-desk?

![hatter](./hatter.png)

# Hatter
It's like flutter but instead of dart, haskell!

Write native mobile apps in Haskell.
This works similar to react native where we have
thight bindings on the existing UI frameworks
provided android and IOS.

This project cross-compiles a Haskell library to Android (APK) and iOS (static library / IPA),
with a thin platform-native UI layer (Kotlin for Android, Swift for iOS).
There is support for android wear and wearOS as well,
because I personally want to build apps for those. 
IOS and Android support was just a side effect.

The library fully controls the UI.
This is different from say Simplex chat where they call into the library to do Haskell from dirty java/swift code.
This library should've written all swift/java code you'll ever need,
so you can focus on your sweet Haskell.

Haskell is a fantastic language for UI.
Having strong type safety around callbacks and widget's 
makes it a lot easier to write them.
I've been many times annoyed at the garbage languages
they keep shoving into our face for UI.
With [vibes](https://jappie.me/haskell-vibes.html) in hand I put my malice
into crafting something good.

# How to use
