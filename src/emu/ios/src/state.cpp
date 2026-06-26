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
#include <ios/state.h>
#include <ios/input_dialog.h>

#include <common/algorithm.h>
#include <common/fileutils.h>
#include <common/log.h>
#include <common/path.h>
#include <common/version.h>

#include <drivers/audio/audio.h>
#include <drivers/graphics/graphics.h>

#include <system/devices.h>

#include <kernel/kernel.h>
#include <kernel/libmanager.h>

#include <services/window/window.h>
#include <services/init.h>

#include <package/manager.h>

namespace eka2l1::ios {
    emulator::emulator()
        : symsys(nullptr)
        , graphics_driver(nullptr)
        , audio_driver(nullptr)
        , launcher_(nullptr)
        , logger(nullptr)
        , window(nullptr)
        , should_emu_quit(false)
        , should_emu_pause(false)
        , should_graphics_pause(false)
        , surface_inited(false)
        , stage_two_inited(false)
        , system_reset_cbh(0)
        , first_time(true)
        , winserv(nullptr)
        , present_status(0) {
    }

    // Defined out-of-line so the unique_ptr members (graphics/audio/sensor drivers)
    // are destroyed where their full definitions are visible.
    emulator::~emulator() = default;

    void emulator::register_draw_callback() {
        if (winserv) {
            int screen_count = 0;
            eka2l1::epoc::screen *screens = winserv->get_screens();
            while (screens) {
                screen_count++;
                std::size_t change_handle = screens->add_screen_redraw_callback(this, [](void *userdata,
                    eka2l1::epoc::screen *scr, const bool is_dsa) {
                    emulator *state_ptr = reinterpret_cast<emulator *>(userdata);
                    if (!state_ptr->graphics_driver) {
                        return;
                    }

                    static bool logged_once = false;
                    if (!logged_once) {
                        logged_once = true;
                        LOG_INFO(FRONTEND_CMDLINE, "Screen redraw callback firing; fb size {}x{}",
                            state_ptr->window->window_fb_size().x, state_ptr->window->window_fb_size().y);
                    }

                    state_ptr->graphics_driver->wait_for(&state_ptr->present_status);

                    drivers::graphics_command_builder builder;
                    state_ptr->launcher_->draw(builder, scr, state_ptr->window->window_fb_size().x,
                        state_ptr->window->window_fb_size().y);

                    state_ptr->present_status = -100;
                    builder.present(&state_ptr->present_status);

                    drivers::command_list retrieved = builder.retrieve_command_list();
                    state_ptr->graphics_driver->submit_command_list(retrieved);
                });

                screen_change_handles.push_back(change_handle);
                screens = screens->next;
            }
            LOG_INFO(FRONTEND_CMDLINE, "register_draw_callback: registered {} screen(s)", screen_count);
        } else {
            LOG_WARN(FRONTEND_CMDLINE, "register_draw_callback: winserv is null (no screens registered)");
        }
    }

    void emulator::on_system_reset(system *the_sys) {
        winserv = reinterpret_cast<eka2l1::window_server *>(the_sys->get_kernel_system()->get_by_name<eka2l1::service::server>(
            eka2l1::get_winserv_name_by_epocver(symsys->get_symbian_version_use())));

        if (stage_two_inited) {
            register_draw_callback();
            the_sys->initialize_user_parties();
        }
    }

    void emulator::stage_one() {
        log::setup_log(nullptr);

        conf.deserialize();
        if (log::filterings) {
            log::filterings->parse_filter_string(conf.log_filter);

            // iOS runs the dyncom interpreter (no JIT enabler). Its VFP unit (cpu/dyncom/vfp/*)
            // emits ~10 trace lines for every single floating-point op; in a float-heavy game
            // that is hundreds of thousands of log lines per second (multi-GB/run), and the
            // synchronous formatting + file writes throttle the emulator to a couple of fps.
            // The default "*:trace" filter never gates it, so force the interpreter's log class
            // to warnings+ here regardless of the configured filter (dynarmic/JIT never hits
            // this code, which is why the recompiler path was unaffected).
            log::filterings->set_minimum_level(CPU_DYNCOM, spdlog::level::warn);
        }

        LOG_INFO(FRONTEND_CMDLINE, "EKA2L1 iOS ({}-{})", GIT_BRANCH, GIT_COMMIT_HASH);

        app_settings = std::make_unique<config::app_settings>(&conf);
        system_create_components comp;
        comp.audio_ = nullptr;
        comp.graphics_ = nullptr;
        comp.conf_ = &conf;
        comp.settings_ = app_settings.get();

        symsys = std::make_unique<eka2l1::system>(comp);

        // CPU backend selection. The iOS port defaults to the jitless dyncom interpreter (set in
        // the system_impl ctor), so it runs on a stock sideloaded app with no "JIT enabler". A
        // user who wants the extra performance can opt into JIT (Settings → CPU Backend / the
        // ios_enable_jit config flag); when that is set we switch to the dynarmic recompiler here,
        // before startup() builds the core. NOTE: dynarmic only actually executes its generated
        // code when the app has JIT permission (launched via AltStore/SideStore/StikJIT or with a
        // debugger attached); without an enabler the recompiler can't map executable memory.
        if (conf.ios_enable_jit) {
            symsys->set_cpu_executor_type(arm_emulator_type::dynarmic);
            LOG_INFO(FRONTEND_CMDLINE, "JIT enabled (dynarmic recompiler) — requires a JIT enabler to execute");
        }

        device_manager *dvcmngr = symsys->get_device_manager();

        if (dvcmngr->total() == 0) {
            // A device may already be extracted on disk (drives/z/<firmware> +
            // roms/<firmware>/SYM.ROM) but missing from devices.yml — e.g. after an
            // interrupted install. Remove any leftover extraction temp directory (which
            // would otherwise confuse the rescan) and rescan so it is picked up.
            common::delete_folder(eka2l1::add_path(conf.storage, "drives/z/temp"));
            common::delete_folder(eka2l1::add_path(conf.storage, "roms/temp"));
            symsys->rescan_devices(drive_z);
        }

        if (dvcmngr->total() > 0) {
            // Per-device language: each installed device remembers its own system language
            // (devices.yml "language"). Resolve the device we're about to boot (clamping an
            // out-of-range index the same way set_device does below) and copy its language into
            // conf.language BEFORE startup(), so setup_outsider()'s set_system_language() boots
            // the guest in that device's language rather than whatever was last globally set.
            int boot_index = conf.device;
            if ((boot_index < 0) || (boot_index >= static_cast<int>(dvcmngr->total()))) {
                boot_index = 0;
            }
            if (device *boot_dvc = dvcmngr->get(static_cast<std::uint8_t>(boot_index))) {
                conf.language = (boot_dvc->language >= 0) ? boot_dvc->language : boot_dvc->default_language_code;
            }

            symsys->startup();

            if (!symsys->set_device(conf.device)) {
                LOG_ERROR(FRONTEND_CMDLINE, "Failed to set device index {}, falling back to first device", conf.device);
                conf.device = 0;
                symsys->rescan_devices(drive_z);
                symsys->set_device(0);
            }

            symsys->mount(drive_c, drive_media::physical, eka2l1::add_path(conf.storage, "/drives/c/"), io_attrib_internal);
            symsys->mount(drive_d, drive_media::physical, eka2l1::add_path(conf.storage, "/drives/d/"), io_attrib_internal);
            symsys->mount(drive_e, drive_media::physical, eka2l1::add_path(conf.storage, "/drives/e/"), io_attrib_removeable);

            on_system_reset(symsys.get());
        }

        system_reset_cbh = symsys->add_system_reset_callback([this](system *the_sys) {
            on_system_reset(the_sys);
        });

        first_time = true;

        launcher_ = std::make_unique<eka2l1::ios::launcher>(symsys.get());
        eka2l1::drivers::ui::launcher_instance = launcher_.get();

        stage_two_inited = false;
    }

    bool emulator::stage_two() {
        if (!stage_two_inited) {
            device_manager *dvcmngr = symsys->get_device_manager();
            device *dvc = dvcmngr->get_current();

            if (!dvc) {
                LOG_ERROR(FRONTEND_CMDLINE, "No current device available; stage two aborted (install a device first)");
                return false;
            }

            LOG_INFO(FRONTEND_CMDLINE, "Device being used: {} ({})", dvc->model, dvc->firmware_code);

            symsys->mount(drive_z, drive_media::rom,
                eka2l1::add_path(conf.storage, "/drives/z/"), io_attrib_internal | io_attrib_write_protected);

            drivers::player_type player_be = drivers::player_type_tsf;
            switch (conf.midi_backend) {
            case config::MIDI_BACKEND_MINIBAE:
                player_be = drivers::player_type_minibae;
                break;
            default:
                player_be = drivers::player_type_tsf;
                break;
            }

            audio_driver = drivers::make_audio_driver(drivers::audio_driver_backend::cubeb, conf.audio_master_volume, player_be);
            if (audio_driver) {
                audio_driver->set_bank_path(drivers::MIDI_BANK_TYPE_HSB, conf.hsb_bank_path);
                audio_driver->set_bank_path(drivers::MIDI_BANK_TYPE_SF2, conf.sf2_bank_path);
            }
            symsys->set_audio_driver(audio_driver.get());

            sensor_driver = drivers::sensor_driver::instantiate();
            if (!sensor_driver) {
                LOG_WARN(FRONTEND_CMDLINE, "Failed to create sensor driver");
            }
            symsys->set_sensor_driver(sensor_driver.get());
            symsys->initialize_user_parties();

            io_system *io = symsys->get_io_system();

            std::string current_dir;
            common::get_current_directory(current_dir);

            if (!conf.svg_icon_cache_reset) {
                common::delete_folder(eka2l1::absolute_path("cache", current_dir));
                conf.svg_icon_cache_reset = true;
                conf.serialize(false);
            }

            std::vector<std::tuple<std::u16string, std::string, epocver>> dlls_need_to_copy = {
                { u"Z:\\sys\\bin\\goommonitor.dll", "patch\\goommonitor_general.dll", epocver::epoc94 },
                { u"Z:\\sys\\bin\\avkonfep.dll", "patch\\avkonfep_general.dll", epocver::epoc93fp1 }
            };

            for (std::size_t i = 0; i < dlls_need_to_copy.size(); i++) {
                epocver ver_required = std::get<2>(dlls_need_to_copy[i]);
                if (symsys->get_symbian_version_use() < ver_required) {
                    continue;
                }

                std::u16string org_file_path = std::get<0>(dlls_need_to_copy[i]);
                auto where_to_copy = io->get_raw_path(org_file_path);

                if (where_to_copy.has_value()) {
                    std::string where_to_copy_u8 = common::ucs2_to_utf8(where_to_copy.value());
                    std::string where_to_backup_u8 = where_to_copy_u8 + ".bak";
                    if (common::exists(where_to_copy_u8) && !common::exists(where_to_backup_u8)) {
                        common::move_file(where_to_copy_u8, where_to_copy_u8 + ".bak");
                    }
                    std::string source_copy = std::get<1>(dlls_need_to_copy[i]);
                    source_copy = eka2l1::absolute_path(source_copy, current_dir);
                    common::copy_file(source_copy, where_to_copy_u8, true);
                }
            }

            manager::packages *pkgmngr = symsys->get_packages();
            pkgmngr->load_registries();
            pkgmngr->migrate_legacy_registries();

            register_draw_callback();

            stage_two_inited = true;
        }

        return true;
    }
}
