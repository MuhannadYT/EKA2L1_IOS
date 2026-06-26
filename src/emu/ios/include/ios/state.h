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

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

#include <common/sync.h>
#include <config/app_settings.h>
#include <config/config.h>
#include <system/epoc.h>

#include <ios/emu_window_ios.h>
#include <ios/launcher.h>

#include <drivers/sensor/sensor.h>

namespace eka2l1 {
    namespace drivers {
        class graphics_driver;
        class audio_driver;
    }

    class window_server;
}

namespace eka2l1::ios {
    // iOS emulator runtime state (mirrors eka2l1::android::emulator).
    struct emulator {
        std::unique_ptr<system> symsys;
        std::unique_ptr<drivers::graphics_driver> graphics_driver;
        std::unique_ptr<drivers::audio_driver> audio_driver;
        std::unique_ptr<drivers::sensor_driver> sensor_driver;
        std::unique_ptr<launcher> launcher_;

        std::shared_ptr<base_logger> logger;
        std::unique_ptr<config::app_settings> app_settings;
        std::unique_ptr<drivers::emu_window_ios> window;

        std::atomic<bool> should_emu_quit;
        std::atomic<bool> should_emu_pause;
        std::atomic<bool> should_graphics_pause;
        std::atomic<bool> surface_inited;
        std::atomic<bool> stage_two_inited;

        std::vector<std::size_t> screen_change_handles;
        std::size_t system_reset_cbh;

        bool first_time;

        common::semaphore graphics_sema;
        common::semaphore pause_sema;
        common::semaphore pause_graphics_sema;
        common::event graphics_init_done;

        config::state conf;
        window_server *winserv;
        int present_status;

        // Incremented on every swapchain present (graphics thread). The frontend samples it to
        // show a frames-per-second figure in the status overlay.
        std::atomic<std::uint64_t> present_count{0};

        std::mutex input_mutex;

        explicit emulator();
        ~emulator();

        void stage_one();
        bool stage_two();

        void on_system_reset(system *the_sys);
        void register_draw_callback();
    };
}
