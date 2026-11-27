# Hatter's Qt Quick host, a library an app's program links with (see
# ../hatter-qt.cabal). It doesn't link against the app: the app hands it
# Hatter's entry points.
cmake_minimum_required(VERSION 3.21)
project(hatter-qt LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Multimedia Qml Quick QuickControls2 Svg Widgets)
# Linux desktops show notifications for apps on the session bus.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(HATTER_QT_DBUS ON)
    find_package(Qt6 6.5 REQUIRED COMPONENTS DBus)
endif()

set(HATTER_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../include" CACHE PATH "Hatter's C headers")

add_library(hatter-qt-host SHARED calls.cpp host.cpp icons.cpp node.cpp platform.cpp rows.cpp)
# All its functions from its Windows DLL, as from a Unix library: Qt's
# generated code exports a few, after which none of ours would be.
if(MINGW)
    target_link_options(hatter-qt-host PRIVATE -Wl,--export-all-symbols)
endif()
# Qt 6.8's: our QML is in a subdirectory, which gets its own qmldir.
if(QT_KNOWN_POLICY_QTP0004)
    qt_policy(SET QTP0004 NEW)
endif()
# Compiled ahead of time: Qt's cache of QML compiled at run time goes by
# the files' times, which Nix sets all alike, so it would keep old QML.
qt_add_qml_module(hatter-qt-host URI Hatter.Qt VERSION 1.0 NO_PLUGIN RESOURCE_PREFIX /
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/Hatter/Qt
    QML_FILES
        qml/HatterArea.qml qml/HatterBackground.qml qml/HatterButton.qml qml/HatterCamera.qml qml/HatterDialog.qml
        qml/HatterField.qml qml/HatterFlickable.qml qml/HatterImage.qml qml/HatterList.qml
        qml/HatterSheet.qml qml/HatterSwitch.qml qml/HatterText.qml qml/HatterWindow.qml)
target_include_directories(hatter-qt-host PRIVATE ${HATTER_INCLUDE})
target_compile_options(hatter-qt-host PRIVATE -Wall -Wextra)
target_link_libraries(hatter-qt-host PRIVATE Qt6::Gui Qt6::Multimedia Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::Svg Qt6::Widgets)
# Notifications: on the session bus, from macOS's user notification centre
# (Nix's Qt on macOS brings D-Bus too, which no Mac runs), and Windows' toasts.
if(HATTER_QT_DBUS)
    target_link_libraries(hatter-qt-host PRIVATE Qt6::DBus)
    target_compile_definitions(hatter-qt-host PRIVATE HATTER_QT_DBUS)
elseif(APPLE)
    enable_language(OBJCXX)
    target_sources(hatter-qt-host PRIVATE notifications_mac.mm)
    set_source_files_properties(notifications_mac.mm PROPERTIES COMPILE_OPTIONS -fobjc-arc)
    target_link_libraries(hatter-qt-host PRIVATE "-framework Foundation" "-framework UserNotifications")
elseif(WIN32)
    target_sources(hatter-qt-host PRIVATE toasts_win.cpp)
    target_link_libraries(hatter-qt-host PRIVATE advapi32 runtimeobject shell32)
endif()

# Run on Qt's offscreen platform: ctest.
enable_testing()
add_executable(hatter-qt-host-test test.cpp)
target_include_directories(hatter-qt-host-test PRIVATE ${HATTER_INCLUDE})
target_link_libraries(hatter-qt-host-test PRIVATE hatter-qt-host Qt6::Gui Qt6::Quick)
add_test(NAME hatter-qt-host-test COMMAND hatter-qt-host-test)
# One at a time on the audio server, as each hears what it plays.
set_tests_properties(hatter-qt-host-test PROPERTIES ENVIRONMENT QT_QPA_PLATFORM=offscreen RESOURCE_LOCK audio)
# And in the Wayland compositor at WAYLAND_DISPLAY, as most desktops now.
option(HATTER_TEST_WAYLAND "Also test in a Wayland compositor" OFF)
if(HATTER_TEST_WAYLAND)
    add_test(NAME hatter-qt-host-wayland-test COMMAND hatter-qt-host-test)
    set_tests_properties(hatter-qt-host-wayland-test PROPERTIES ENVIRONMENT QT_QPA_PLATFORM=wayland RESOURCE_LOCK audio)
endif()

include(GNUInstallDirs)
install(TARGETS hatter-qt-host)
install(FILES hatter_qt.h ${HATTER_INCLUDE}/CallAudioBridge.h ${HATTER_INCLUDE}/CallVideoBridge.h ${HATTER_INCLUDE}/PermissionBridge.h ${HATTER_INCLUDE}/UIBridge.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/hatter-qt)
configure_file(hatter-qt-host.pc.in hatter-qt-host.pc @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hatter-qt-host.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
