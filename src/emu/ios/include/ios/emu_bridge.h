/*
 * Copyright (c) 2024 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

// C++ API that the UIKit (Objective-C++) frontend calls into. All operations are
// thread-safe to call from the main thread; the emulator itself runs on its own
// OS + graphics threads created by bridge_start().
namespace eka2l1::ios::bridge {
    struct app_entry {
        std::uint32_t uid;
        std::string name;
    };

    struct device_entry {
        std::string name;       // model / display name (renameable)
        std::string firmware;   // firmware code (stable id)
    };

    // A user-installed, removable package (SIS app / augmentation). uid + index together
    // identify it for uninstall (index distinguishes augmentations sharing a uid).
    struct package_entry {
        std::uint32_t uid;
        std::int32_t index;
        std::string name;
    };

    struct icon_image {
        std::vector<std::uint8_t> rgba;
        int width = 0;
        int height = 0;
    };

    // A system language available in a device's ROM/firmware. id = Symbian language code,
    // name = its human-readable name.
    struct language_entry {
        int id;
        std::string name;
    };

    enum touch_action {
        touch_action_down = 0,
        touch_action_move = 1,
        touch_action_up = 2
    };

    // Establish the writable working directory (sets the process cwd and the
    // emulator storage root). Copies the read-only resources shipped in the app
    // bundle into the data directory on first launch.
    void set_data_directory(const std::string &data_dir, const std::string &bundle_resource_dir);

    // Create the emulator and start the OS + graphics threads, rendering into the
    // given CAEAGLLayer. Returns true if a device (ROM) is installed and the guest
    // OS actually booted.
    bool start(void *layer, int width, int height);

    bool is_running();
    bool has_device();

    // ---- CPU backend / JIT (iOS) -----------------------------------------
    // The port defaults to the jitless dyncom interpreter, so it runs on a stock sideloaded app
    // with no "JIT enabler". get_jit_enabled returns the persisted preference; set_jit_enabled
    // opts into the dynarmic recompiler for extra performance and reboots the emulator in place
    // so it takes effect (stage_one re-reads the flag and builds the chosen core). Heavy (reboots
    // the guest) — call set_jit_enabled from a background thread. NOTE: dynarmic only actually
    // executes its generated code when the app has JIT permission (launched via
    // AltStore/SideStore/StikJIT or with a debugger attached); without an enabler it can't map
    // executable memory.
    bool get_jit_enabled();
    void set_jit_enabled(bool enabled);

    void surface_changed(void *layer, int width, int height);
    void pause();
    void resume();
    void shutdown();

    // Factory reset: tears down the emulator, deletes the entire writable data directory
    // (devices, drives, installed apps, config, caches), re-stages the bundled assets, and
    // restarts. Returns true if a device is still present afterwards (false after a wipe).
    // Heavy — call from a background thread.
    bool wipe_app_data();

    void touch(int x, int y, touch_action action, int pointer_id);

    // Send a raw Symbian key scancode (see android Keycode.java). down=true is press.
    void key(int scancode, bool down);

    // Exit the currently running app and return to the booted menu state. Mirrors the
    // Android frontend, which tears down and recreates the emulator instance. Heavy
    // (reboots the guest), so call from a background thread.
    void exit_game();

    // Content management (safe to call before/after the guest has booted).
    // progress (when supplied) is reported as a percentage 0..100 during installation.
    //
    // Two install kinds, matching the Android frontend:
    //   * Device dump (recommended): install_rpkg = true. rom_path is the ROM; rpkg_path is
    //     the optional RPKG (the core picks install_rpkg/install_rom based on the ROM).
    //   * VPL firmware: install_rpkg = false. rpkg_path is empty and rom_path is the .vpl
    //     manifest (its sibling .fpsx/.rofs blobs must live in the same folder).
    int install_device(const std::string &rpkg_path, const std::string &rom_path,
        bool install_rpkg, std::function<void(int)> progress = nullptr);
    int install_app(const std::string &path);

    // Devices. get_devices/get_current_device/rename_device are light (main-thread safe).
    // set_current_device/delete_device may reboot the guest in place, so call them from a
    // background thread.
    std::vector<device_entry> get_devices();
    int get_current_device();
    void set_current_device(int index);
    void rename_device(int index, const std::string &new_name);
    void delete_device(int index);

    // Device language (per device). get_device_languages/get_device_language are light
    // (main-thread safe): get_device_languages returns the languages a device's ROM ships;
    // get_device_language is that device's currently selected language code (its own choice, or
    // its ROM default). set_device_language stores the choice on the device (devices.yml),
    // independently per device; it only reboots the guest when index is the active device (so
    // call it from a background thread for the active device, main thread is fine otherwise).
    std::vector<language_entry> get_device_languages(int index);
    int get_device_language(int index);
    void set_device_language(int index, int language_id);

    // N-Gage. Installs a game-card folder (mirrors the desktop frontend). Heavy (copies
    // the card into the E drive) — call from a background thread. Returns 0 on success or
    // an ngage_game_card_install_error code; out_name receives the detected game name.
    int install_ngage_game(const std::string &folder_path, std::string &out_name);

    // Installs a single ".n-gage" game file by copying it into the E drive's n-gage folder
    // (mirrors Android's manual drives/e/n-gage drop). Returns 0 on success; out_name = the
    // file's name. Call from a background thread.
    int install_ngage_file(const std::string &file_path, std::string &out_name);

    std::vector<app_entry> get_apps();
    icon_image get_app_icon(std::uint32_t uid);
    void launch_app(std::uint32_t uid);

    // Installed removable packages. get_packages is light (main-thread safe). uninstall_package
    // removes the package's files + registration and reboots the guest in place so the app list
    // drops it (mirrors the Android frontend's restart-after-uninstall) — call it from a
    // background thread.
    std::vector<package_entry> get_packages();
    void uninstall_package(std::uint32_t uid, std::int32_t index);

    // Per-game rendering settings (iOS frontend). set_screen_gravity changes where the
    // guest screen sits in the surface (0=Left,1=Top,2=Center,3=Right,4=Bottom) and forces
    // an immediate re-fit/redraw — call it on launch and on device rotation. set_app_refresh_rate
    // persists a per-app fps into the core's app-settings; it takes effect on the app's next launch.
    void set_screen_gravity(int gravity);
    void set_app_refresh_rate(std::uint32_t uid, int fps);
    // Per-app upscale/filter shader by name (e.g. "natural"); nullptr/"" = off. Persisted into the
    // core's app-settings (compat/<UID>.yml); takes effect on the app's next launch.
    void set_app_filter_shader(std::uint32_t uid, const char *shader_name);

    // "Gyroscope passthrough": when true, the CoreMotion accelerometer backend feeds real device
    // tilt to the guest's accelerometer sensor; when false it feeds nothing (like the null stub).
    // Takes effect immediately (next sensor sample). Default true. Call on launch and on change.
    void set_gyro_passthrough(bool enabled);

    // "Haptic passthrough": when true, the guest's vibration requests are passed through to the
    // device's Taptic Engine (CoreHaptics); when false they're ignored (like the null stub).
    // Takes effect immediately (next vibration request). Default true. Call on launch and on change.
    void set_haptic_passthrough(bool enabled);

    // The emulated screen's on-screen rectangle as fractions (0..1) of the device surface
    // {x, y, w, h}. The frontend uses this to fit the on-screen controls into the empty space
    // beside/below the guest ("auto scale buttons"). Cheap + main-thread safe (a try-lock;
    // leaves the outputs untouched if the emulator is mid-reboot or hasn't drawn yet).
    void get_guest_screen_rect(float *fx, float *fy, float *fw, float *fh);

    // Sample the live presented frames-per-second (a rolling figure over the time between
    // calls). Returns false (output untouched) until two samples are available, or if the
    // emulator is busy. The frontend derives "emulator speed %" from this vs the target rate.
    bool get_status(float *fps);

    // ---- Progress Sync / backup ------------------------------------------
    // A backup captures the writable data the user accumulates. "include_devices" extends it
    // from just game progress (the C/D/E drives + per-game settings) to the full install
    // (installed Symbian devices, ROMs and the Z drive) so it can be restored from scratch.

    // Total bytes a backup would occupy (uncompressed) — for the "current backup size" display.
    std::uint64_t backup_size(bool include_devices);

    // Write a .zip backup of the chosen scope to zip_path. Returns true on success. Heavy —
    // call from a background thread.
    bool export_backup(const std::string &zip_path, bool include_devices);

    // Restore a .zip backup into the data directory (overwrites matching files), then reboots
    // the emulator. Returns true on success. Heavy — call from a background thread.
    bool import_backup(const std::string &zip_path);

    void set_app_exit_callback(std::function<void()> cb);
}
