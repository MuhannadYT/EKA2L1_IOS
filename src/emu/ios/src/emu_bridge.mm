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
#import <Foundation/Foundation.h>

#include <ios/emu_bridge.h>
#include <ios/state.h>
#include <ios/thread.h>

#include <common/fileutils.h>
#include <common/language.h>
#include <common/log.h>
#include <common/path.h>
#include <common/types.h>

#include <drivers/graphics/graphics.h>
#include <drivers/audio/audio.h>
#include <drivers/hwrm/vibration.h>
#include <drivers/sensor/sensor.h>

#include <services/window/window.h>

#include <system/devices.h>

#include <miniz.h>

#include <chrono>
#include <memory>
#include <mutex>

namespace eka2l1::ios::bridge {
    namespace {
        std::unique_ptr<eka2l1::ios::emulator> g_state;
        std::mutex g_mutex;

        bool g_running = false;
        bool g_has_device = false;

        // Remember the surface so the emulator can be torn down and rebuilt in place
        // (e.g. after a device is installed).
        void *g_layer = nullptr;
        int g_width = 0;
        int g_height = 0;

        // Remembered so the writable data dir can be re-staged after a full wipe.
        std::string g_data_dir;
        std::string g_bundle_res;

        std::function<void()> g_app_exit_cb;

        void copy_bundle_subdir(NSString *bundleRoot, NSString *dataRoot, NSString *name) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *src = [bundleRoot stringByAppendingPathComponent:name];
            NSString *dst = [dataRoot stringByAppendingPathComponent:name];

            if (![fm fileExistsAtPath:src]) {
                return;
            }
            if ([fm fileExistsAtPath:dst]) {
                // Already populated; keep the existing copy (preserves caches).
                return;
            }

            NSError *err = nil;
            if (![fm copyItemAtPath:src toPath:dst error:&err]) {
                LOG_ERROR(eka2l1::FRONTEND_CMDLINE, "Failed to copy bundled '{}' resources: {}",
                    [name UTF8String], err ? [[err localizedDescription] UTF8String] : "unknown");
            }
        }

        bool start_locked() {
            if (g_running) {
                return g_has_device;
            }

            g_state = std::make_unique<eka2l1::ios::emulator>();
            // emulator_entry runs stage_one/stage_two inline (which mounts and parses the
            // ROM); do it on a large stack to survive the deep ROM-loader recursion.
            bool has_device = false;
            eka2l1::ios::run_with_large_stack([&]() {
                has_device = eka2l1::ios::emulator_entry(*g_state, g_layer, g_width, g_height);
            });
            g_has_device = has_device;

            if (g_state->launcher_) {
                g_state->launcher_->set_app_exit_callback([]() {
                    if (g_app_exit_cb) {
                        g_app_exit_cb();
                    }
                });
            }

            init_threads(*g_state);
            start_threads(*g_state);

            g_running = true;
            return g_has_device;
        }

        void shutdown_locked() {
            if (!g_running || !g_state) {
                return;
            }
            eka2l1::ios::shutdown_threads(*g_state);
            g_state.reset();
            g_running = false;
            g_has_device = false;
        }

        // Stage the read-only bundled assets into the writable data dir and make it the cwd.
        void stage_data_directory(const std::string &data_dir, const std::string &bundle_resource_dir) {
            @autoreleasepool {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *dataRoot = [NSString stringWithUTF8String:data_dir.c_str()];
                // Bundled assets are staged under an "assets" subdir (see ios/CMakeLists.txt
                // for why they cannot sit directly in the bundle root).
                NSString *bundleRoot = [[NSString stringWithUTF8String:bundle_resource_dir.c_str()]
                    stringByAppendingPathComponent:@"assets"];

                [fm createDirectoryAtPath:dataRoot withIntermediateDirectories:YES attributes:nil error:nil];

                // Read-only assets shipped in the .app, copied into the writable area.
                copy_bundle_subdir(bundleRoot, dataRoot, @"resources");
                copy_bundle_subdir(bundleRoot, dataRoot, @"compat");
                copy_bundle_subdir(bundleRoot, dataRoot, @"patch");
            }

            // Everything the emulator reads/writes is relative to the working directory.
            eka2l1::common::set_current_directory(data_dir + "/");
        }

        // Re-blit the current guest screen into the swapchain at the present surface size
        // and present it immediately. Presents are otherwise only driven by a guest screen
        // redraw, so after a rotation a static screen (e.g. a menu) keeps showing the old
        // framebuffer stretched onto the resized layer. Mirrors Android's surfaceRedrawNeeded.
        // Caller must hold g_mutex.
        void redraw_screens_immediately() {
            if (!g_state || !g_state->graphics_driver || !g_state->launcher_ || !g_state->window) {
                return;
            }

            g_state->graphics_driver->wait_for(&g_state->present_status);

            eka2l1::drivers::graphics_command_builder builder;
            eka2l1::epoc::screen *scr = g_state->winserv ? g_state->winserv->get_screens() : nullptr;
            g_state->launcher_->draw(builder, scr, g_state->window->window_fb_size().x,
                g_state->window->window_fb_size().y);

            g_state->present_status = -100;
            builder.present(&g_state->present_status);

            eka2l1::drivers::command_list retrieved = builder.retrieve_command_list();
            g_state->graphics_driver->submit_command_list(retrieved);
        }
    }

    void set_data_directory(const std::string &data_dir, const std::string &bundle_resource_dir) {
        g_data_dir = data_dir;
        g_bundle_res = bundle_resource_dir;
        stage_data_directory(data_dir, bundle_resource_dir);
    }

    bool start(void *layer, int width, int height) {
        std::lock_guard<std::mutex> guard(g_mutex);
        g_layer = layer;
        g_width = width;
        g_height = height;
        return start_locked();
    }

    bool is_running() {
        std::lock_guard<std::mutex> guard(g_mutex);
        return g_running;
    }

    bool has_device() {
        std::lock_guard<std::mutex> guard(g_mutex);
        return g_has_device;
    }

    void surface_changed(void *layer, int width, int height) {
        std::lock_guard<std::mutex> guard(g_mutex);
        g_layer = layer;
        g_width = width;
        g_height = height;
        if (g_state && g_state->window) {
            g_state->window->surface_changed(layer, width, height);
            if (g_state->graphics_driver) {
                g_state->graphics_driver->update_surface_size(eka2l1::vec2(width, height));
                // Force a redraw at the new size so the screen is re-fitted (not stretched)
                // immediately on rotation, without waiting for the next guest redraw.
                redraw_screens_immediately();
            }
        }
    }

    void pause() {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_running) {
            pause_threads(*g_state);
        }
    }

    void resume() {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_running) {
            start_threads(*g_state);
        }
    }

    void shutdown() {
        std::lock_guard<std::mutex> guard(g_mutex);
        shutdown_locked();
    }

    bool wipe_app_data() {
        std::lock_guard<std::mutex> guard(g_mutex);

        // 1. Tear the emulator down so nothing holds the ROM mmap / drive files / log open.
        shutdown_locked();

        // 2. Delete everything under the writable data directory (devices, drives, roms,
        //    config, caches, installed apps, imports, logs) — a clean factory reset.
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *root = [NSString stringWithUTF8String:g_data_dir.c_str()];
            for (NSString *item in [fm contentsOfDirectoryAtPath:root error:nil]) {
                [fm removeItemAtPath:[root stringByAppendingPathComponent:item] error:nil];
            }
        }

        // 3. Re-stage the bundled read-only assets the emulator needs to boot, then start
        //    fresh — with no device installed, this lands on the "install a device" state.
        stage_data_directory(g_data_dir, g_bundle_res);
        return start_locked();
    }

    void touch(int x, int y, touch_action action, int pointer_id) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_running) {
            eka2l1::ios::touch_screen(*g_state, x, y, 0, static_cast<int>(action), pointer_id);
        }
    }

    void key(int scancode, bool down) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_running) {
            // key_state: pressed = 0, released = 1
            eka2l1::ios::press_key(*g_state, scancode, down ? 0 : 1);
        }
    }

    void exit_game() {
        std::lock_guard<std::mutex> guard(g_mutex);
        // Reboot the emulator instance, returning to the booted (menu) state.
        shutdown_locked();
        start_locked();
    }

    int install_device(const std::string &rpkg_path, const std::string &rom_path,
        bool install_rpkg, std::function<void(int)> progress) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state) {
            g_state = std::make_unique<eka2l1::ios::emulator>();
            eka2l1::ios::run_with_large_stack([&]() {
                g_state->stage_one();
            });
        }
        if (!g_state->launcher_) {
            return -1;
        }

        std::string rpkg = rpkg_path;
        std::string rom = rom_path;

        progress_changed_callback pcb = nullptr;
        if (progress) {
            pcb = [progress](const std::size_t done, const std::size_t total) {
                progress(total ? static_cast<int>(done * 100 / total) : 0);
            };
        }

        // Device installation parses the ROM (deep recursion) — run on a large stack.
        // install_rpkg/install_rom already register the device with the device manager
        // and persist devices.yml; we must NOT rescan here (rescan clears the list and
        // re-derives it from drives/z, which is fragile if an extraction temp dir lingers).
        int result = -1;
        eka2l1::ios::run_with_large_stack([&]() {
            result = static_cast<int>(g_state->launcher_->install_device(rpkg, rom, install_rpkg, pcb));
            if (result == 0) {
                // Make the freshly installed device current.
                std::uint32_t count = static_cast<std::uint32_t>(g_state->launcher_->get_devices().size());
                if (count > 0) {
                    g_state->launcher_->set_current_device(count - 1, false);
                }
            }
        });

        if (result == 0) {
            // Reboot the guest in place with the new device (start_locked also parses
            // the ROM on a large stack).
            shutdown_locked();
            start_locked();
        }

        return result;
    }

    int install_app(const std::string &path) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_) {
            return -1;
        }
        std::string p = path;
        return static_cast<int>(g_state->launcher_->install_app(p));
    }

    std::vector<device_entry> get_devices() {
        std::lock_guard<std::mutex> guard(g_mutex);
        std::vector<device_entry> result;
        if (!g_state || !g_state->launcher_) {
            return result;
        }
        std::vector<std::string> models = g_state->launcher_->get_devices();
        std::vector<std::string> firmwares = g_state->launcher_->get_device_firmware_codes();
        for (std::size_t i = 0; i < models.size(); i++) {
            device_entry entry;
            entry.name = models[i];
            entry.firmware = (i < firmwares.size()) ? firmwares[i] : std::string();
            result.push_back(std::move(entry));
        }
        return result;
    }

    int get_current_device() {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_) {
            return -1;
        }
        return static_cast<int>(g_state->launcher_->get_current_device());
    }

    void set_current_device(int index) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_ || index < 0) {
            return;
        }
        // Persist the selection, then reboot the instance so the guest boots the chosen
        // device (start_locked re-reads conf->device and parses its ROM on a large stack).
        g_state->launcher_->set_current_device(static_cast<std::uint32_t>(index), false);
        shutdown_locked();
        start_locked();
    }

    bool get_jit_enabled() {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state) {
            return false;
        }
        return g_state->conf.ios_enable_jit;
    }

    void set_jit_enabled(bool enabled) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || g_state->conf.ios_enable_jit == enabled) {
            return;
        }
        // Persist the choice, then reboot the instance so stage_one re-reads it and builds the
        // chosen CPU core (set_cpu_executor_type runs before startup() in stage_one). dynarmic
        // is the JIT recompiler; dyncom is the jitless interpreter.
        g_state->conf.ios_enable_jit = enabled;
        g_state->conf.serialize(false);
        shutdown_locked();
        start_locked();
    }

    void rename_device(int index, const std::string &new_name) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_ || index < 0 || new_name.empty()) {
            return;
        }
        g_state->launcher_->rename_device(static_cast<std::uint32_t>(index), new_name);
    }

    std::vector<language_entry> get_device_languages(int index) {
        std::lock_guard<std::mutex> guard(g_mutex);
        std::vector<language_entry> result;
        if (!g_state || !g_state->launcher_ || index < 0) {
            return result;
        }
        std::vector<int> codes = g_state->launcher_->get_device_languages(static_cast<std::uint32_t>(index));
        for (int code : codes) {
            language_entry entry;
            entry.id = code;
            entry.name = eka2l1::common::get_language_name_by_code(code);
            result.push_back(std::move(entry));
        }
        return result;
    }

    int get_device_language(int index) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_ || index < 0) {
            return -1;
        }
        return g_state->launcher_->get_device_language(static_cast<std::uint32_t>(index));
    }

    void set_device_language(int index, int language_id) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_ || index < 0) {
            return;
        }
        const bool is_current = (index == static_cast<int>(g_state->launcher_->get_current_device()));

        // Store the choice on the device itself (devices.yml) — independent per device.
        g_state->launcher_->set_device_language(static_cast<std::uint32_t>(index), language_id);

        // Only the active device needs a reboot to apply it now; for any other device the
        // choice is simply remembered and applied when it is next booted.
        if (is_current) {
            shutdown_locked();
            start_locked();
        }
    }

    void delete_device(int index) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_ || index < 0) {
            return;
        }
        const int current_before = static_cast<int>(g_state->launcher_->get_current_device());
        g_state->launcher_->delete_device(static_cast<std::uint32_t>(index));

        // If the running device was removed, reboot onto the new current device (or into
        // the no-device state). Deleting a different device only shifts indices, which
        // delete_device already reconciled with conf->device — no reboot needed.
        if (index == current_before) {
            shutdown_locked();
            g_has_device = start_locked();
        }
    }

    int install_ngage_game(const std::string &folder_path, std::string &out_name) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_) {
            return -1;
        }
        std::string folder = folder_path;
        int result = -1;
        // The card install copies the whole folder into the E drive (deep recursion +
        // potentially large) — run it on a large stack like the other content ops.
        eka2l1::ios::run_with_large_stack([&]() {
            result = g_state->launcher_->install_ngage_game(folder, out_name);
        });
        return result;
    }

    int install_ngage_file(const std::string &file_path, std::string &out_name) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_) {
            return -1;
        }
        const int result = g_state->launcher_->install_ngage_file(file_path, out_name);
        if (result == 0 && g_running) {
            // Reboot so the guest re-mounts the E drive and the N-Gage launcher re-scans
            // E:\n-gage on its next open. A file dropped into an already-running instance
            // is otherwise missed by a launcher that already scanned (the N-Gage app only
            // looks for new game files on a fresh start).
            shutdown_locked();
            start_locked();
        }
        return result;
    }

    std::vector<app_entry> get_apps() {
        std::lock_guard<std::mutex> guard(g_mutex);
        std::vector<app_entry> result;
        if (!g_state || !g_state->launcher_) {
            return result;
        }

        std::vector<std::string> flat = g_state->launcher_->get_apps();
        for (std::size_t i = 0; i + 1 < flat.size(); i += 2) {
            app_entry entry;
            entry.uid = static_cast<std::uint32_t>(std::stoul(flat[i]));
            entry.name = flat[i + 1];
            result.push_back(std::move(entry));
        }
        return result;
    }

    icon_image get_app_icon(std::uint32_t uid) {
        std::lock_guard<std::mutex> guard(g_mutex);
        icon_image out;
        if (!g_state || !g_state->launcher_) {
            return out;
        }
        eka2l1::ios::app_icon icon = g_state->launcher_->get_app_icon(uid);
        if (icon.valid()) {
            out.rgba = std::move(icon.rgba);
            out.width = icon.width;
            out.height = icon.height;
        }
        return out;
    }

    void launch_app(std::uint32_t uid) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_state->launcher_) {
            g_state->launcher_->launch_app(uid);
        }
    }

    std::vector<package_entry> get_packages() {
        std::lock_guard<std::mutex> guard(g_mutex);
        std::vector<package_entry> result;
        if (!g_state || !g_state->launcher_) {
            return result;
        }

        // launcher::get_packages returns a flat [uid, index, name] triplet stream.
        std::vector<std::string> flat = g_state->launcher_->get_packages();
        for (std::size_t i = 0; i + 3 <= flat.size(); i += 3) {
            package_entry entry;
            entry.uid = static_cast<std::uint32_t>(std::stoul(flat[i]));
            entry.index = static_cast<std::int32_t>(std::stol(flat[i + 1]));
            entry.name = flat[i + 2];
            result.push_back(std::move(entry));
        }
        return result;
    }

    void uninstall_package(std::uint32_t uid, std::int32_t index) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_state || !g_state->launcher_) {
            return;
        }
        g_state->launcher_->uninstall_package(uid, index);

        // Reboot the guest in place so the app list server re-scans and drops the
        // uninstalled app (mirrors the Android frontend's restart-after-uninstall).
        if (g_running) {
            shutdown_locked();
            g_has_device = start_locked();
        }
    }

    void set_screen_gravity(int gravity) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_state->launcher_) {
            g_state->launcher_->set_screen_gravity(static_cast<std::uint32_t>(gravity));
            // Re-fit the current screen at the new gravity right away (the guest may be on a
            // static screen that would otherwise not redraw).
            redraw_screens_immediately();
        }
    }

    void set_app_refresh_rate(std::uint32_t uid, int fps) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_state->launcher_) {
            g_state->launcher_->set_app_refresh_rate(uid, static_cast<std::uint32_t>(fps));
        }
    }

    void set_app_filter_shader(std::uint32_t uid, const char *shader_name) {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_state && g_state->launcher_) {
            g_state->launcher_->set_app_filter_shader(uid, shader_name ? std::string(shader_name) : std::string());
        }
    }

    void set_gyro_passthrough(bool enabled) {
        // Just a process-wide flag the CoreMotion sensor backend reads; no emulator lock needed.
        eka2l1::drivers::set_sensor_passthrough_enabled(enabled);
    }

    void set_haptic_passthrough(bool enabled) {
        // Just a process-wide flag the CoreHaptics vibrator backend reads; no emulator lock needed.
        eka2l1::drivers::hwrm::set_haptic_passthrough_enabled(enabled);
    }

    void get_guest_screen_rect(float *fx, float *fy, float *fw, float *fh) {
        // Polled from the main thread; never block on a heavy reboot — just keep the last value.
        std::unique_lock<std::mutex> guard(g_mutex, std::try_to_lock);
        if (!guard.owns_lock() || !g_state || !g_running || !g_state->launcher_) {
            return;
        }
        float x = 0.0f, y = 0.0f, w = 0.0f, h = 0.0f;
        g_state->launcher_->get_guest_rect(x, y, w, h);
        if (fx) *fx = x;
        if (fy) *fy = y;
        if (fw) *fw = w;
        if (fh) *fh = h;
    }

    bool get_status(float *fps) {
        // Sampling state for the rolling fps window (only touched under g_mutex).
        static std::uint64_t s_last_present = 0;
        static double s_last_wall = 0.0;
        static bool s_primed = false;

        std::unique_lock<std::mutex> guard(g_mutex, std::try_to_lock);
        if (!guard.owns_lock() || !g_state || !g_running) {
            s_primed = false;   // re-baseline once the emulator is back
            return false;
        }

        const std::uint64_t presents = g_state->present_count.load(std::memory_order_relaxed);
        const double now = std::chrono::duration<double>(
            std::chrono::steady_clock::now().time_since_epoch()).count();

        // First sample after (re)start, or the counter went backwards (instance rebooted) → reset.
        if (!s_primed || presents < s_last_present) {
            s_last_present = presents;
            s_last_wall = now;
            s_primed = true;
            return false;
        }

        const double dt = now - s_last_wall;
        if (dt < 1e-4) {
            return false;
        }

        const float fps_val = static_cast<float>((presents - s_last_present) / dt);

        s_last_present = presents;
        s_last_wall = now;

        if (fps) *fps = fps_val;
        return true;
    }

    void set_app_exit_callback(std::function<void()> cb) {
        std::lock_guard<std::mutex> guard(g_mutex);
        g_app_exit_cb = std::move(cb);
    }

    // ---- Progress Sync / backup ------------------------------------------
    namespace {
        // Subpaths under the data directory that make up each backup scope. "Game progress" is
        // the user's drives + the iOS frontend's per-game config; "devices" adds the installed
        // Symbian device(s) so a backup can be restored onto a fresh install.
        NSArray<NSString *> *backup_paths(bool include_devices) {
            NSMutableArray *p = [@[ @"drives/c", @"drives/d", @"drives/e",
                                    @"game_settings", @"compat", @"keybinds.json" ] mutableCopy];
            if (include_devices) {
                [p addObjectsFromArray:@[ @"data", @"roms", @"drives/z" ]];
            }
            return p;
        }

        // Enumerate every regular file in `subpath` (file or directory) under `root`, calling
        // body(absolutePath, archiveRelativePath).
        void for_each_backup_file(NSString *root, NSString *subpath,
                                  void (^body)(NSString *abs, NSString *rel)) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *full = [root stringByAppendingPathComponent:subpath];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) return;
            if (!isDir) {
                body(full, subpath);
                return;
            }
            for (NSString *rel in [fm enumeratorAtPath:full]) {
                NSString *abs = [full stringByAppendingPathComponent:rel];
                BOOL d = NO;
                if ([fm fileExistsAtPath:abs isDirectory:&d] && !d) {
                    body(abs, [subpath stringByAppendingPathComponent:rel]);
                }
            }
        }
    }

    std::uint64_t backup_size(bool include_devices) {
        @autoreleasepool {
            NSString *root = [NSString stringWithUTF8String:g_data_dir.c_str()];
            __block unsigned long long total = 0;
            for (NSString *sub in backup_paths(include_devices)) {
                for_each_backup_file(root, sub, ^(NSString *abs, NSString *rel) {
                    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:abs error:nil];
                    total += [attrs fileSize];
                });
            }
            return total;
        }
    }

    bool export_backup(const std::string &zip_path, bool include_devices) {
        @autoreleasepool {
            NSString *root = [NSString stringWithUTF8String:g_data_dir.c_str()];
            __block mz_zip_archive zip;   // __block: mutated inside the per-file block below
            memset(&zip, 0, sizeof(zip));
            if (!mz_zip_writer_init_file(&zip, zip_path.c_str(), 0)) {
                return false;
            }
            __block bool ok = true;
            for (NSString *sub in backup_paths(include_devices)) {
                for_each_backup_file(root, sub, ^(NSString *abs, NSString *rel) {
                    if (!mz_zip_writer_add_file(&zip, [rel UTF8String], [abs UTF8String], NULL, 0, MZ_BEST_SPEED)) {
                        ok = false;
                    }
                });
            }
            ok = mz_zip_writer_finalize_archive(&zip) && ok;
            mz_zip_writer_end(&zip);
            return ok;
        }
    }

    bool import_backup(const std::string &zip_path) {
        std::lock_guard<std::mutex> guard(g_mutex);
        @autoreleasepool {
            // Release the ROM mmap / drive file handles before overwriting them.
            const bool was_running = g_running;
            shutdown_locked();

            NSString *root = [NSString stringWithUTF8String:g_data_dir.c_str()];
            NSFileManager *fm = [NSFileManager defaultManager];
            mz_zip_archive zip;
            memset(&zip, 0, sizeof(zip));
            bool ok = false;
            if (mz_zip_reader_init_file(&zip, zip_path.c_str(), 0)) {
                ok = true;
                mz_uint n = mz_zip_reader_get_num_files(&zip);
                for (mz_uint i = 0; i < n; i++) {
                    if (mz_zip_reader_is_file_a_directory(&zip, i)) continue;
                    mz_zip_archive_file_stat st;
                    if (!mz_zip_reader_file_stat(&zip, i, &st)) continue;
                    NSString *rel = [NSString stringWithUTF8String:st.m_filename];
                    // Guard against path traversal in a malicious archive.
                    if ([rel hasPrefix:@"/"] || [rel containsString:@".."]) continue;
                    NSString *dest = [root stringByAppendingPathComponent:rel];
                    [fm createDirectoryAtPath:[dest stringByDeletingLastPathComponent]
                  withIntermediateDirectories:YES attributes:nil error:nil];
                    if (!mz_zip_reader_extract_to_file(&zip, i, [dest UTF8String], 0)) {
                        ok = false;
                    }
                }
                mz_zip_reader_end(&zip);
            }

            if (was_running || g_state) {
                start_locked();
            }
            return ok;
        }
    }
}
