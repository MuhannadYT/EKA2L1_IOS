# EKA2L1 iOS frontend (UIKit + OpenGL ES).
#
# eka2l1_ios_bridge : platform glue (window, lifecycle, launcher, threads) + a C++
#                     API consumed by the UIKit application.
# eka2l1            : the runnable .app bundle (Objective-C++ UIKit frontend).

add_library(eka2l1_ios_bridge STATIC
    include/ios/emu_bridge.h
    include/ios/emu_window_ios.h
    include/ios/input_dialog.h
    include/ios/launcher.h
    include/ios/state.h
    include/ios/thread.h
    src/applauncher.mm
    src/emu_bridge.mm
    src/emu_window_ios.cpp
    src/input_dialog.cpp
    src/launcher.cpp
    src/state.cpp
    src/thread.cpp)

target_include_directories(eka2l1_ios_bridge PUBLIC include)

target_link_libraries(eka2l1_ios_bridge PUBLIC
    common
    cpu
    drivers
    epoc
    epockern
    epocpkg
    epocservs
    epocloader
    config
    glad
    lunasvg
    sqlite3
    yaml-cpp)

# Pull in the prebuilt Symbian patch DLLs (avkon fep, media client, etc.) just like
# the Android frontend does, so the emulator can hot-patch the guest ROM.
add_dependencies(eka2l1_ios_bridge
    avkonfep
    audiooutputrouting
    ecam
    scdv
    mediaclientaudio
    mediaclientaudiostream
    mediaclientvideo
    vibractrl
    backlightctrl
    postingsurfacefactory
    goommonitor)

# ---------------------------------------------------------------------------
# The runnable application bundle.
# ---------------------------------------------------------------------------
set(IOS_APP_SOURCES
    app/main.mm
    app/AppDelegate.h
    app/AppDelegate.mm
    app/EmulatorView.h
    app/EmulatorView.mm
    app/GameControlsView.h
    app/GameControlsView.mm
    app/GameSettingsStore.h
    app/GameSettingsStore.mm
    app/GameSettingsViewController.h
    app/GameSettingsViewController.mm
    app/KeybindStore.h
    app/KeybindStore.mm
    app/InputManager.h
    app/InputManager.mm
    app/GameMenuView.h
    app/GameMenuView.mm
    app/KeybindCaptureViewController.h
    app/KeybindCaptureViewController.mm
    app/KeybindEditorViewController.h
    app/KeybindEditorViewController.mm
    app/LayoutEditorViewController.h
    app/LayoutEditorViewController.mm
    app/PackageListViewController.h
    app/PackageListViewController.mm
    app/HiddenAppsViewController.h
    app/HiddenAppsViewController.mm
    app/SyncManager.h
    app/SyncManager.mm
    app/SyncViewController.h
    app/SyncViewController.mm
    app/RootViewController.h
    app/RootViewController.mm)

add_executable(eka2l1 MACOSX_BUNDLE ${IOS_APP_SOURCES})

# The UIKit frontend is written against ARC.
target_compile_options(eka2l1 PRIVATE -fobjc-arc)

target_link_libraries(eka2l1 PRIVATE
    eka2l1_ios_bridge
    "-framework UIKit"
    "-framework Foundation"
    "-framework CoreGraphics"
    "-framework QuartzCore"
    "-framework OpenGLES"
    "-framework GameController"
    "-framework UniformTypeIdentifiers")

set_target_properties(eka2l1 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/app/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "EKA2L1"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.eka2l1.emulator"
    MACOSX_BUNDLE_BUNDLE_VERSION "1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")

# Stage the read-only assets the emulator needs (GLES shaders, soundfont banks,
# compatibility db, Symbian patch DLLs) into the .app bundle. The app copies them
# into its writable Documents directory on first launch.
#
# IMPORTANT: assets live under an "assets" subdirectory rather than directly in the
# bundle root. A top-level "resources" folder collides (case-insensitively on macOS)
# with CFBundle's reserved "Resources" directory, which makes CFBundle mis-detect the
# bundle layout and fail to read the Info.plist (CoreSimulator: "Missing bundle ID").
set(EKA2L1_ASSETS_DIR "$<TARGET_BUNDLE_DIR:eka2l1>/assets")
set(DRIVERS_RES "${PROJECT_SOURCE_DIR}/src/emu/drivers/resources")

add_custom_command(TARGET eka2l1 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${EKA2L1_ASSETS_DIR}/resources"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${DRIVERS_RES}/gles" "${EKA2L1_ASSETS_DIR}/resources"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${DRIVERS_RES}/upscale" "${EKA2L1_ASSETS_DIR}/resources/upscale"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${DRIVERS_RES}/defaultbank.hsb" "${EKA2L1_ASSETS_DIR}/resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${DRIVERS_RES}/defaultbank.sf2" "${EKA2L1_ASSETS_DIR}/resources"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${EKA2L1_ASSETS_DIR}/compat"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${PROJECT_SOURCE_DIR}/miscs/compat" "${EKA2L1_ASSETS_DIR}/compat"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${EKA2L1_ASSETS_DIR}/patch"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_BINARY_DIR}/bin/patch" "${EKA2L1_ASSETS_DIR}/patch"
    VERBATIM)

# ---------------------------------------------------------------------------
# App icon (Apple Icon Composer "Liquid Glass" .icon, Xcode 26).
#
# This is a Ninja build, so Xcode's automatic asset-catalog compilation does not
# run. Invoke actool directly to compile app/AppIcon.icon into an Assets.car (the
# Liquid Glass asset used on iOS 26) plus flat PNG fallbacks, written into the
# bundle root. The matching CFBundleIcons keys live in Info.plist.
set(EKA2L1_APPICON "${CMAKE_CURRENT_SOURCE_DIR}/app/AppIcon.icon")
add_custom_command(TARGET eka2l1 POST_BUILD
    COMMAND xcrun actool --compile "$<TARGET_BUNDLE_DIR:eka2l1>"
        --app-icon AppIcon
        --output-partial-info-plist "${CMAKE_CURRENT_BINARY_DIR}/appicon_partial.plist"
        --platform iphonesimulator
        --minimum-deployment-target 15.0
        --target-device iphone --target-device ipad
        "${EKA2L1_APPICON}"
    VERBATIM)
