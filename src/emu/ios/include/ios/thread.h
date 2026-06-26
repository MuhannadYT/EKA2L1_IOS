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

#include <ios/state.h>

#include <functional>

namespace eka2l1::ios {
    struct emulator;

    // Runs `fn` synchronously on a thread with a large stack (the Symbian ROM loader
    // recurses deeply and overflows the small default stacks of the main / GCD threads).
    void run_with_large_stack(const std::function<void()> &fn);

    void graphics_driver_thread(emulator &state);
    void os_thread(emulator &state);

    // Starts the OS + graphics threads. `surface` is the CAEAGLLayer the GL ES context
    // renders into; width/height are its drawable size in pixels.
    bool emulator_entry(emulator &state, void *surface, int width, int height);

    void init_threads(emulator &state);
    void start_threads(emulator &state);
    void pause_threads(emulator &state);
    void shutdown_threads(emulator &state);

    void press_key(emulator &state, int key, int key_state);
    void touch_screen(emulator &state, int x, int y, int z, int action, int pointer_id);
}
