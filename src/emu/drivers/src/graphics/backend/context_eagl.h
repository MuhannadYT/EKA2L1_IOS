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

#include <drivers/graphics/context.h>
#include <cstdint>

#if defined(__OBJC__)
@class EAGLContext;
@class CAEAGLLayer;
#else
typedef void EAGLContext;
typedef void CAEAGLLayer;
#endif

namespace eka2l1::drivers::graphics {
    // OpenGL ES context backed by a CAEAGLLayer (iOS / iOS Simulator).
    //
    // Unlike desktop GL / EGL there is no window-backed default framebuffer, so the
    // context owns a framebuffer object whose colour renderbuffer storage is bound to
    // the layer's drawable. swapchain_framebuffer() exposes that FBO to the OGL driver.
    class gl_context_eagl final : public gl_context {
    public:
        explicit gl_context_eagl() = default;
        explicit gl_context_eagl(const window_system_info &wsi, bool stereo, bool core);

        ~gl_context_eagl() override;

        bool is_headless() const override;

        std::unique_ptr<gl_context> create_shared_context() override;

        bool make_current() override;
        bool clear_current() override;

        void update(const std::uint32_t new_width, const std::uint32_t new_height) override;
        void update_surface(void *new_surface) override;

        void swap_buffers() override;
        void set_swap_interval(const std::int32_t interval) override;

        std::uint32_t swapchain_framebuffer() const override {
            return framebuffer_;
        }

        bool present_blocks_until_vsync() const override {
            return true;
        }

    protected:
        // Allocate / re-allocate the colour (and depth) renderbuffer storage from the
        // current layer's drawable. Requires the context to be current.
        void create_storage();
        void destroy_storage();

        EAGLContext *context_ = nullptr;
        CAEAGLLayer *layer_ = nullptr;

        std::uint32_t framebuffer_ = 0;
        std::uint32_t colour_renderbuffer_ = 0;
        std::uint32_t depth_renderbuffer_ = 0;
    };
}
