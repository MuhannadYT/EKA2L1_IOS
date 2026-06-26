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
#include <ios/thread.h>

#include <common/log.h>
#include <common/thread.h>

#include <drivers/audio/audio.h>
#include <drivers/graphics/graphics.h>

#include <system/epoc.h>
#include <kernel/kernel.h>

#include <services/window/window.h>

#include <functional>
#include <memory>
#include <pthread.h>

namespace eka2l1::ios {
    // The Symbian ROM loader (loader::read_rom_dir / read_rom_entry) recurses through
    // the ROM directory tree, which easily exceeds the 512 KB default stack of GCD
    // worker threads and std::thread. All emulator work therefore runs on threads with
    // a generous stack.
    static constexpr std::size_t LARGE_STACK_SIZE = 32 * 1024 * 1024; // 32 MB

    static pthread_t os_thread_handle{};
    static pthread_t gr_thread_handle{};
    static bool os_thread_started = false;
    static bool gr_thread_started = false;

    static constexpr const char *os_thread_name = "Symbian OS thread";
    static constexpr const char *graphics_driver_thread_name = "Graphics thread";

    static void *large_stack_trampoline(void *arg) {
        auto *fn = reinterpret_cast<std::function<void()> *>(arg);
        (*fn)();
        delete fn;
        return nullptr;
    }

    static bool spawn_large_stack_thread(pthread_t &out, std::function<void()> body) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, LARGE_STACK_SIZE);

        auto *heap_fn = new std::function<void()>(std::move(body));
        const int rc = pthread_create(&out, &attr, large_stack_trampoline, heap_fn);
        pthread_attr_destroy(&attr);

        if (rc != 0) {
            delete heap_fn;
            return false;
        }
        return true;
    }

    void run_with_large_stack(const std::function<void()> &fn) {
        pthread_t handle{};
        if (!spawn_large_stack_thread(handle, fn)) {
            // Could not create the worker; fall back to running inline.
            fn();
            return;
        }
        pthread_join(handle, nullptr);
    }

    static int graphics_driver_thread_initialization(emulator &state, void *surface, int width, int height) {
        eka2l1::common::set_thread_name(graphics_driver_thread_name);
        eka2l1::common::set_thread_priority(eka2l1::common::thread_priority_high);

        state.window = std::make_unique<drivers::emu_window_ios>();
        state.window->init("EKA2L1", eka2l1::vec2(width, height), drivers::emu_window_flag_maximum_size);
        state.window->surface_changed(surface, width, height);
        state.window->set_userdata(&state);

        state.graphics_driver = drivers::create_graphics_driver(drivers::graphic_api::opengl,
            state.window->get_window_system_info());
        state.symsys->set_graphics_driver(state.graphics_driver.get());

        drivers::emu_window_ios *window = state.window.get();

        window->surface_change_hook = [&state](void *new_surface) {
            state.graphics_driver->update_surface(new_surface);
        };

        // The initial surface is already known; make sure the driver picks it up.
        state.graphics_driver->update_surface(surface);

        state.graphics_driver->set_display_hook([window, &state]() {
            window->swap_buffer();
            window->poll_events();
            state.present_count.fetch_add(1, std::memory_order_relaxed);

            if (state.should_graphics_pause) {
                state.pause_graphics_sema.wait();
            }
        });

        state.surface_inited = true;
        state.graphics_init_done.set();
        return 0;
    }

    void graphics_driver_thread(emulator &state) {
        // The surface/dimensions are stashed on the window before this runs (see
        // emulator_entry); re-read them so the driver is built on this thread.
        // run() blocks processing command lists until the driver is told to stop.
        state.graphics_driver->run();
        state.graphics_driver.reset();
    }

    void os_thread(emulator &state) {
        eka2l1::common::set_thread_name(os_thread_name);
        eka2l1::common::set_thread_priority(eka2l1::common::thread_priority_high);

        while (!state.should_emu_quit) {
            try {
                state.symsys->loop();
            } catch (std::exception &exc) {
                LOG_ERROR(FRONTEND_CMDLINE, "Main loop exited with exception: {}", exc.what());
                state.should_emu_quit = true;
                break;
            }

            if (state.should_emu_pause) {
                state.symsys->pause();
                state.pause_sema.wait();
                state.symsys->unpause();
            }
        }

        state.symsys.reset();
    }

    bool emulator_entry(emulator &state, void *surface, int width, int height) {
        state.stage_one();
        const bool result = state.stage_two();

        // Build the graphics driver + context on the dedicated graphics thread.
        state.graphics_init_done.reset();
        gr_thread_started = spawn_large_stack_thread(gr_thread_handle, [&state, surface, width, height]() {
            if (graphics_driver_thread_initialization(state, surface, width, height) != 0) {
                LOG_ERROR(FRONTEND_CMDLINE, "Graphics driver initialization failed");
                state.graphics_init_done.set();
                return;
            }
            graphics_driver_thread(state);
        });
        state.graphics_init_done.wait();

        if (result) {
            os_thread_started = spawn_large_stack_thread(os_thread_handle, [&state]() {
                os_thread(state);
            });
        }

        return result;
    }

    void init_threads(emulator &state) {
        state.graphics_sema.notify();
    }

    void start_threads(emulator &state) {
        state.should_emu_pause = false;
        state.should_graphics_pause = false;
        state.pause_graphics_sema.notify();
        state.pause_sema.notify();

        if (state.sensor_driver) {
            state.sensor_driver->resume();
        }
        if (state.audio_driver) {
            state.audio_driver->resume();
        }
    }

    void pause_threads(emulator &state) {
        state.should_emu_pause = true;
        state.should_graphics_pause = true;

        if (state.sensor_driver) {
            state.sensor_driver->pause();
        }
        if (state.audio_driver) {
            state.audio_driver->suspend();
        }
    }

    void shutdown_threads(emulator &state) {
        state.should_emu_quit = true;
        state.should_emu_pause = false;
        state.should_graphics_pause = false;

        // Wake the guest's idle scheduler so the OS-thread loop returns promptly and sees
        // should_emu_quit. When shutting down from the idle booted menu (e.g. switching
        // device from the app list, no game running), the CPU cores are parked in the idle
        // wait and symsys->loop() never returns — so pthread_join below would block forever
        // (the symptom: "Switching device…" hangs until the app is relaunched). A running
        // game keeps the loop busy, which is why Exit Game didn't hit this. Mirrors the Qt
        // frontend's kill_emulator (request_exit + stop_cores_idling).
        //
        // ONLY when the OS thread actually started: a no-device boot leaves symsys alive
        // but never calls startup(), so its CPU is null — request_exit()/cpu->stop() would
        // crash. os_thread_started implies a booted device (startup ran, CPU exists), and is
        // also the only case where there's an idle loop to wake.
        if (os_thread_started && state.symsys) {
            state.symsys->request_exit();
            if (auto *kern = state.symsys->get_kernel_system()) {
                kern->stop_cores_idling();
            }
        }

        // Join the OS thread FIRST: its symsys.reset() tears down the system, whose
        // dispatcher destructor cleans up GL resources (egl_controller / shader manager)
        // by submitting commands to the graphics driver. The graphics driver must still
        // be alive and pumping its run() loop while that happens, otherwise the GL
        // teardown dereferences a freed driver (crash on Exit Game). So we only stop the
        // graphics thread *after* the system is fully destroyed.
        state.pause_sema.notify();
        if (os_thread_started) {
            pthread_join(os_thread_handle, nullptr);
            os_thread_started = false;
        }

        // System is gone now; stop the graphics thread (it resets the driver on exit).
        state.pause_graphics_sema.notify();
        if (state.graphics_driver) {
            state.graphics_driver->abort();
        }
        if (gr_thread_started) {
            pthread_join(gr_thread_handle, nullptr);
            gr_thread_started = false;
        }
    }

    void press_key(emulator &state, int key, int key_state) {
        if (!state.winserv) {
            return;
        }
        eka2l1::drivers::input_event evt;
        evt.type_ = eka2l1::drivers::input_event_type::key_raw;
        evt.key_.state_ = static_cast<eka2l1::drivers::key_state>(key_state);
        evt.key_.code_ = key;
        state.winserv->queue_input_from_driver(evt);
    }

    void touch_screen(emulator &state, int x, int y, int z, int action, int pointer_id) {
        if (!state.winserv) {
            return;
        }
        eka2l1::drivers::input_event evt;
        evt.type_ = eka2l1::drivers::input_event_type::touch;
        evt.mouse_.pos_x_ = static_cast<int>(x);
        evt.mouse_.pos_y_ = static_cast<int>(y);
        evt.mouse_.pos_z_ = static_cast<int>(z);
        evt.mouse_.mouse_id = static_cast<std::uint32_t>(pointer_id);
        evt.mouse_.button_ = eka2l1::drivers::mouse_button::mouse_button_left;
        evt.mouse_.action_ = static_cast<eka2l1::drivers::mouse_action>(action);
        evt.mouse_.raw_screen_pos_ = false;
        state.winserv->queue_input_from_driver(evt);
    }
}
