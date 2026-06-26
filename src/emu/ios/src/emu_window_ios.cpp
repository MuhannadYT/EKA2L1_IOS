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
#include <ios/emu_window_ios.h>
#include <drivers/graphics/common.h>

namespace eka2l1::drivers {
    emu_window_ios::emu_window_ios()
        : fb_size(0, 0)
        , surface_(nullptr)
        , userdata(nullptr) {
    }

    void emu_window_ios::surface_changed(void *surface, int width, int height) {
        surface_ = surface;

        if ((width > 0) && (height > 0)) {
            fb_size.x = width;
            fb_size.y = height;
        }

        if (surface_change_hook) {
            surface_change_hook(surface);
        }
    }

    window_system_info emu_window_ios::get_window_system_info() {
        window_system_info info;
        info.type = window_system_type::headless;
        info.render_surface = surface_;
        info.render_window = surface_;
        info.surface_width = static_cast<std::uint32_t>(fb_size.x);
        info.surface_height = static_cast<std::uint32_t>(fb_size.y);
        return info;
    }

    bool emu_window_ios::get_mouse_button_hold(const int mouse_btt) {
        return false;
    }

    vec2 emu_window_ios::window_size() {
        return fb_size;
    }

    vec2 emu_window_ios::window_fb_size() {
        return fb_size;
    }

    vec2d emu_window_ios::get_mouse_pos() {
        return eka2l1::vec2d{ 0.0, 0.0 };
    }

    bool emu_window_ios::set_cursor(cursor *cur) {
        return false;
    }

    void emu_window_ios::cursor_visiblity(const bool visi) {
    }

    bool emu_window_ios::cursor_visiblity() {
        return false;
    }

    bool emu_window_ios::should_quit() {
        return false;
    }

    void emu_window_ios::init(std::string title, vec2 size, const std::uint32_t flags) {
        if ((size.x > 0) && (size.y > 0)) {
            fb_size = size;
        }
    }

    void emu_window_ios::set_fullscreen(const bool is_fullscreen) {
    }

    void emu_window_ios::change_title(std::string new_title) {
    }

    void emu_window_ios::make_current() {
    }

    void emu_window_ios::done_current() {
    }

    void emu_window_ios::swap_buffer() {
    }

    void emu_window_ios::shutdown() {
    }

    void emu_window_ios::poll_events() {
    }

    void emu_window_ios::set_userdata(void *new_userdata) {
        userdata = new_userdata;
    }

    void *emu_window_ios::get_userdata() {
        return userdata;
    }
}
