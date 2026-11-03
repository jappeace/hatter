# A Qt Quick platform for Hatter: plan

Status: steps 1, 2 and 6 (Linux) done, in `desktop/` (2026-11-11). Step 3 under
way: macOS and Windows build and pass their tests in CI (2026-11-26).

## Goal

Hatter apps as desktop apps on Linux, macOS and Windows, through a new
platform. An app's code stays as it is: like Android, the browser and the
terminal, the desktop is one more Hatter platform.

Fixed points:

- One native process with a native UI. Never a native process driving a
  webview or a browser tab.
- The web version stays the all-wasm browser build (`browser/`). The desktop
  doesn't share its renderer.
- Hatter's idea holds: native widgets per platform, the platform's toolkit
  lays them out and draws them.

## Why Qt Quick

- Hatter's widgets are a phone UI: rounded boxes, pills, round pictures,
  colours with alpha, overlapping stacks. Qt Quick does all of that as is.
  Qt Widgets would need style sheets and painting code for most of it.
- One toolkit for all three systems, with input methods, accessibility,
  high-DPI and dark mode.
- GPU drawing, which long lists and video want.

GTK 4 is the other candidate (a C API, no C++), but it is weak on macOS and
Windows. Drawing everything ourselves (SDL, Skia) would leave text input,
input methods, the clipboard and accessibility to us.

QML is only the glue: the backend creates items from C++, from one small QML
component per kind of widget, because Qt Quick's text and input items are
only public through QML. An app's UI is never written in QML.

## Shape

Like Android and the browser, not like the terminal:

- Hatter's renderer diffs the widget tree and calls `UIBridgeCallbacks`
  (create node, set property, add/remove child, set handler, set root). The
  Qt host keeps a `QQuickItem` per node.
- The host lays the items out with Android's rules, as `browser/host`'s
  `host.ts` does with CSS: wrap or match per parent, fixed sizes, weights
  (space a parent lacks comes from weighted children first), stacks with
  every child in the one cell, scrolling columns kept at their end, lazy
  columns.
- Text sizes come from Qt itself (the items' implicit sizes), so wrapped
  text is measured by what draws it.

The terminal lays out Hatter's whole widget tree itself, in character cells,
and draws it. That fits a terminal, not retained native items, so its
`Layout` module is not reused as is.

Layout: each node is a C++ item (`desktop/host/node.cpp`) that measures and
places its children by Android's rules, ported from the terminal's
`Layout.hs` (measure specs, children measured in turn, weights sharing what
is left, stacks over each other). Qt Quick Layouts weren't used: they have
nothing like a stack (Android's FrameLayout), every node needs a wrapper for
padding and background anyway, and they share space by size hints where
Android measures children in turn (the browser needed `flex-shrink: 1000` to
come close). Leaves are Qt Quick's own `Text`, `Button`, `TextField`,
`TextArea` and `Image` (Material style), measured by their implicit sizes.

A lazy column is a `ListView` (`qml/HatterList.qml`, `rows.cpp`), as
Android's RecyclerView: the app fills rows only for the items that show,
reused as the list scrolls. After a render the first item shown is found
again by its key, so items added or taken before or after it don't move
it; a column kept at its end stays there.

## Threads

As on Android: the GUI thread owns the UI.

- Qt's GUI thread calls into Haskell for taps, text changes and renders
  (Hatter's handlers), so node calls already come on the GUI thread and need
  no queue.
- Redraw requests from other Haskell threads go through the redraw bridge,
  which posts a render to the GUI thread (`QMetaObject::invokeMethod`,
  queued), as `redraw_bridge_android.c` posts to Android's UI thread.
- The other bridges answer on the GUI thread too (dialog buttons, picked
  files), through the same Haskell callbacks Android uses.

## Process and build

- The host is a C++ library built with CMake (`desktop/host/`, for moc
  and Qt's tooling on all three systems), `libhatter-qt-host`, on Qt 6.5
  or later (the desktop's colour scheme, `MultiEffect`). It doesn't link
  against the app: the app hands it Hatter's entry points (`HatterQtApp`
  in `hatter_qt.h`), so link order and Haskell's libraries don't concern
  it. The host and its C API are named for Qt, whose they are; what an
  app uses is named for the desktop (`hatter-desktop`, `Hatter.Desktop`).
- The program is the app's Haskell executable, built with cabal against
  the package `hatter-desktop` (`desktop/hatter-desktop.cabal`,
  `pkgconfig-depends: hatter-qt-host`). Its C `main`
  (`desktop/cbits/qt_main.c`) starts the Haskell runtime and the app the
  way Android's activity does, then Qt's event loop. The app's `Main` is
  the same as on Android (`main :: IO (Ptr AppContext)`, `-no-hs-main`),
  so Hatter's Android demo apps run unchanged. An app with icons tells
  the host where its Android vector drawables are
  (`Hatter.Desktop.setResources`).
- The app's files go where Qt keeps an app's data
  (`QStandardPaths::AppDataLocation`).
- `desktop/shell.nix` builds the host with Nix and gives cabal, Qt's plugin and
  QML paths, fonts, and a virtual display (Xvfb, xdotool, ImageMagick).
- The host's QML (`desktop/host/qml/`) is compiled ahead of time
  (`qt_add_qml_module`): Qt's cache of QML compiled at run time goes by
  the files' times, which Nix sets all alike, so it kept old QML.
- Where Qt Quick finds no GL driver, as a program from Nix on other Linux
  systems, the host draws with Qt Quick's software renderer instead of
  letting Qt abort: without shadows, and pictures' corners square.
- Deployment is CI's for now: Windows' folder from `windeployqt`
  (`desktop-windows`) and macOS's app bundle from `macdeployqt`
  (`desktop-macos-app`, with `desktop/demo/Info.plist`), in
  `.github/workflows/ci.yaml`.

Toolchain per system (an app adds its own C libraries the same way):

| | Linux | macOS | Windows |
|---|---|---|---|
| GHC | Nix (9.10.3, as now) | Nix, as on Linux | ghcup 9.10.3 (its MinGW clang toolchain) |
| Qt | Nix | Nix, as on Linux | Qt 6.10's LLVM-MinGW build, with its LLVM-MinGW 17 for the host |
| Package | AppImage or Flatpak (later) | `.app` via `macdeployqt` | folder/installer via `windeployqt` |

## Bridges

| Bridge | Desktop |
|---|---|
| UI (nodes, darkMode, clock24, copyText, openUri, openFile, pickFile(s), pickPicture, saveFile, capturePicture) | Qt Quick items; `QStyleHints::colorScheme`; `QLocale` time format; `QClipboard`; `QDesktopServices`, with a short note when nothing opens it, as Android's toast; `QFileDialog`; a camera popup, its picture handed on as a picked file |
| Redraw | queued render on the GUI thread |
| Animation | frames on the GUI thread from a timer at the screen's refresh rate, as Android's `Choreographer` gives them |
| Dialog, BottomSheet | QML `Dialog`, a sheet-like `Popup` (Android's button order) |
| Notification | `org.freedesktop.Notifications` on Linux; the user notification centre on macOS, from an app's bundle (else logged); toasts on Windows, under an application user model ID the host registers for the user |
| FilesDir | `QStandardPaths::AppDataLocation` |
| DatabaseKey | a key file only the user can read (0600; on Windows, as their profile's folders), made in one step, as in the terminal; the OS keychain later (Keychain, Credential Manager, libsecret) |
| DeviceInfo | `QSysInfo`, screen size from the window, and what draws it (the GL driver's name, or software) |
| Picture | `QImage` (size, pixels, shrink, square crop) |
| Permission | granted, except location, refused |
| Location | none, as its permission is refused |
| Http | Qt Network, if an app needs it |
| CallAudio, CallVideo | Qt Multimedia, on the desktop's default devices: the microphone in frames and the other side played from a thread of its own (`QAudioSource`, `QAudioSink`), the tones as the browser's; the camera as I420 (`QCamera`, `QVideoSink`), as near 640 by 480 as it has; frames shown in the image nodes showing their stream |

## Steps

Each step ends with something checked, and nothing goes to the next system
until it works on the one before.

1. **Spike (Linux), done 2026-11-10:** a Qt host with the UI bridge's node
   calls, Hatter's demo app (counter, text field, lazy list) running in it,
   and the layout choice settled against the browser's semantics. Checked
   on a virtual display with Mesa's OpenGL: taps on buttons and on other
   nodes, long presses (held, or the secondary button), typing, a lazy list
   kept at its end (not pulled down while the user reads back), wrapped
   text, a window resized, redraws asked for from another thread, and
   Hatter's stretch, stack (taps through an overlay), scroll and
   horizontal-scroll demos placed as Android's rules say. Qt Quick's
   software renderer draws Material buttons' backgrounds at the window's
   corner, so screenshots use Mesa's OpenGL.
2. **The other bridges (Linux), done 2026-11-11:** icons are the app's
   Android vector drawables, drawn tinted in the theme's text colour with
   Qt SVG; pictures' corners are rounded with `MultiEffect`; dialogs and
   sheets are Material popups (Android's button order); file dialogs are
   `QFileDialog` (native where the desktop has one; Qt Quick's own can't
   suggest a name to save as), picked files copied as on Android;
   pictures through `QImageReader`, at most 2^26 pixels as on Android;
   DatabaseKey a 0600 key file made in one step; notifications through
   `org.freedesktop.Notifications` on Linux (a click opens the app at the
   notification's key); location and camera refused; Back is Escape or the
   mouse's back button, unless a popup is open; Start and Stop as the window
   shows or is minimised; light and dark from the desktop's colour scheme.
   Checked on a virtual display with a full chat app: lists, typing,
   pictures, files both ways, dialogs, sheets, notifications (through
   dunst) and dark mode.
3. **macOS and Windows:** the toolchains in the table, linking the app's
   Haskell libraries on each (Windows is the riskiest part), packaging.
   Built and tested in CI, 2026-11-26: on macOS from Nix, as on Linux;
   on Windows without Nix (`desktop/cabal.project.ghcup`), the host a DLL
   that exports all its functions, as a Unix library does, and the
   program calls only in C, so Qt's C++ runtime and GHC's never meet.
   The host's tests and Hatter's pass on both, and the demo links. On
   Windows the demo is packaged as someone would get it (`windeployqt`,
   with the host and the toolchain's runtime beside it, a CI artifact)
   and starts on the desktop with nothing else on the `PATH`; on macOS,
   built without Nix too, as an app bundle (`macdeployqt`, signed for the
   Mac it's on), which notifications need. Not checked there: calls'
   audio (no audio server), and clicking a notification.
4. **CI:** GitHub Actions on Linux, macOS and Windows: build, then start a
   demo app offscreen and check its screen renders.
5. **Desktop extras:** the keychain, letting an app keep running when its
   window closes (a tray icon). Long lists, done 2026-11-11: rows only
   for the items that show.
6. **Calls (Linux), done 2026-11-11:** CallAudio and CallVideo through Qt
   Multimedia, and taking a picture in a camera popup. Checked: a call
   between two desktops, each side's tone heard on the other, the tones
   before it's answered; the far side's video shown; no camera on the
   machine checked, so the camera only offers none. The desktop cancels no
   echo itself: a headset, or the desktop's own echo cancellation.

## Risks

- Windows: GHC's program linked with a C++ DLL built by Qt's toolchain,
  matching GHC's MinGW toolchain with Qt's build. Links and runs its
  tests in CI; not yet tried as an app on a desktop.

## Open questions

- Linux packaging: AppImage, Flatpak, or both?
