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

#include <common/types.h>
#include <common/vecx.h>

#include <drivers/ui/input_dialog.h>
#include <drivers/graphics/common.h>
#include <services/applist/applist.h>
#include <services/window/window.h>
#include <services/drm/rights/rights.h>
#include <system/installation/common.h>
#include <package/manager.h>
#include <config/config.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace eka2l1 {
    class system;
    class kernel_system;
    class fbs_server;

    namespace epoc {
        struct screen;
    }
}

namespace eka2l1::ios {
    // RGBA8888 icon decoded for display in UIKit.
    struct app_icon {
        std::vector<std::uint8_t> rgba;
        int width = 0;
        int height = 0;

        bool valid() const {
            return (width > 0) && (height > 0) && !rgba.empty();
        }
    };

    // iOS port of the EKA2L1 launcher controller. Exposes the operations the UIKit
    // frontend drives (install device / app, enumerate + launch apps, render the
    // emulated screen). Mirrors eka2l1::android::launcher but without any JNI.
    class launcher {
        eka2l1::system *sys;
        config::state *conf;
        eka2l1::kernel_system *kern;
        applist_server *alserv;
        window_server *winserv;
        fbs_server *fbsserv;
        rights_server *rightsserv;

        eka2l1::vecx<std::uint8_t, 3> background_color_;
        float scale_ratio_;
        std::uint32_t scale_type_;
        std::uint32_t gravity_;

        // The emulated screen's on-screen rectangle, as fractions (0..1) of the swapchain,
        // updated every draw(). Lets the iOS frontend fit the on-screen controls into the empty
        // space beside/below the guest (the "auto scale buttons" option). Written on the
        // graphics thread, read from the main thread — a benign read.
        std::atomic<float> guest_fx_{0.0f};
        std::atomic<float> guest_fy_{0.0f};
        std::atomic<float> guest_fw_{0.0f};   // 0 = not drawn yet (frontend treats as "full size")
        std::atomic<float> guest_fh_{0.0f};

        eka2l1::drivers::ui::input_dialog_complete_callback input_complete_callback_;
        eka2l1::drivers::ui::yes_no_dialog_complete_callback yes_no_complete_callback_;

        std::function<void()> app_exit_callback_;

        void set_language_to_property(const language new_one);
        void set_language_current(const language lang);
        void retrieve_servers();

        // After uninstalling an N-Gage game's package, clear the runtime per-game record the
        // N-Gage platform generates under its store's private dir (uid 0x20007B39). The SIS
        // uninstall doesn't track it, so it survives and makes the guest's N-Gage installer
        // abort a reinstall with KErrAlreadyExists (-11). No-op for non-N-Gage apps.
        void remove_ngage_store_leftovers(std::uint32_t uid);

    public:
        explicit launcher(eka2l1::system *sys);

        void set_app_exit_callback(std::function<void()> cb) {
            app_exit_callback_ = std::move(cb);
        }

        std::vector<std::string> get_apps();
        app_icon get_app_icon(std::uint32_t uid);
        void launch_app(std::uint32_t uid);
        package::installation_result install_app(std::string &path);
        std::vector<std::string> get_devices();
        std::vector<std::string> get_device_firmware_codes();
        void set_current_device(std::uint32_t id, const bool temporary);
        void rename_device(std::uint32_t id, const std::string &new_name);
        // The language codes a device's ROM/firmware ships (read from its languages.txt,
        // populated for every device on load). Empty if the index is out of range.
        std::vector<int> get_device_languages(std::uint32_t id);
        // A device's currently selected system language code (its own chosen one, or its ROM
        // default if it has none yet). -1 if the index is out of range.
        int get_device_language(std::uint32_t id);
        // Set the system language for a device, persisted on the device itself (devices.yml),
        // independently of the other devices. Only touches the live config if this is the
        // currently-booted device (the caller then reboots in place to apply it).
        void set_device_language(std::uint32_t id, int language_id);
        // Removes the device at `index` from the list; returns the new current device index
        // (-1 if no devices remain). Keeps conf->device in sync + persists.
        int delete_device(std::uint32_t index);
        void rescan_devices();
        std::uint32_t get_current_device();
        device_installation_error install_device(std::string &rpkg_path, std::string &rom_path, bool install_rpkg,
            progress_changed_callback progress_cb = nullptr);
        // Copies an ".n-gage" game file into the E drive's n-gage folder (mirrors Android's
        // manual drives/e/n-gage drop). Returns 0 on success; out_name = the file's name.
        int install_ngage_file(const std::string &src_path, std::string &out_name);
        int install_ngage_game(const std::string &folder_path, std::string &out_name);
        bool does_rom_need_rpkg(const std::string &rom_path);
        std::vector<std::string> get_packages();
        void uninstall_package(std::uint32_t uid, std::int32_t ext_index);
        void mount_sd_card(std::string &path);
        void load_config();

        void draw(drivers::graphics_command_builder &builder, epoc::screen *scr,
            std::uint32_t width, std::uint32_t height);

        // The emulated screen's on-screen rectangle as fractions (0..1) of the surface.
        void get_guest_rect(float &fx, float &fy, float &fw, float &fh) const {
            fx = guest_fx_.load(std::memory_order_relaxed);
            fy = guest_fy_.load(std::memory_order_relaxed);
            fw = guest_fw_.load(std::memory_order_relaxed);
            fh = guest_fh_.load(std::memory_order_relaxed);
        }

        void set_screen_params(std::uint32_t background_color, std::uint32_t scale_ratio,
            std::uint32_t scale_type, std::uint32_t gravity);

        // Set just the screen gravity (0=Left,1=Top,2=Center,3=Right,4=Bottom). The iOS
        // frontend changes this per game + orientation; the draw callback picks it up.
        void set_screen_gravity(std::uint32_t gravity);

        // Persist a per-app refresh rate (fps) into the emulator's app-settings store
        // (compat/<UID>.yml). Picked up when the app's window group is created on launch.
        void set_app_refresh_rate(std::uint32_t uid, std::uint32_t fps);

        // Per-app upscale/filter shader by name (e.g. "natural"); "" = off. Written to compat/<UID>.yml
        // and consumed by screen::restore_from_config (driver->set_upscale_shader) on the app's launch.
        void set_app_filter_shader(std::uint32_t uid, const std::string &shader_name);

        // Text input / question dialog plumbing (driven by the dispatch + notifier services).
        bool open_input_view(const std::u16string &initial_text, const int max_len,
            drivers::ui::input_dialog_complete_callback complete_callback);
        void close_input_view();
        void on_finished_text_input(const std::string &text, const bool force_close);

        bool open_question_dialog(const std::u16string &text, const std::u16string &button1_text,
            const std::u16string &button2_text, drivers::ui::yes_no_dialog_complete_callback complete_callback);
        void on_question_dialog_finished(const int result);

        fbs_server *get_fbs_serv() {
            return fbsserv;
        }
    };
}
