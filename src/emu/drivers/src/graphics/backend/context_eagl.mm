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

#include "context_eagl.h"
#include <common/log.h>

#import <Foundation/Foundation.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

namespace eka2l1::drivers::graphics {
    gl_context_eagl::gl_context_eagl(const window_system_info &wsi, bool stereo, bool core) {
        m_opengl_mode = mode::opengl_es;

        // The CAEAGLLayer (opaque/contentsScale/drawableProperties) is configured on the
        // main thread by the UIKit view; here we only bind a renderbuffer to its drawable.
        layer_ = (__bridge CAEAGLLayer *)(wsi.render_surface);

        // Prefer OpenGL ES 3.0 (matches the glad gles2=3.0 generated loader); fall back to ES 2.
        context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (context_ == nullptr) {
            context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        }

        if (context_ == nullptr) {
            LOG_CRITICAL(DRIVER_GRAPHICS, "Failed to create an EAGL OpenGL ES context!");
            return;
        }

        [EAGLContext setCurrentContext:context_];

        glGenFramebuffers(1, &framebuffer_);
        glGenRenderbuffers(1, &colour_renderbuffer_);
        glGenRenderbuffers(1, &depth_renderbuffer_);

        create_storage();

        // Present an initial black frame; until the guest draws, a fresh CAEAGLLayer
        // renderbuffer otherwise shows undefined (often white) contents.
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBindRenderbuffer(GL_RENDERBUFFER, colour_renderbuffer_);
        [context_ presentRenderbuffer:GL_RENDERBUFFER];
    }

    gl_context_eagl::~gl_context_eagl() {
        if (context_ == nullptr) {
            return;
        }

        if ([EAGLContext currentContext] == context_) {
            destroy_storage();

            if (framebuffer_) {
                glDeleteFramebuffers(1, &framebuffer_);
                framebuffer_ = 0;
            }
        }

        if ([EAGLContext currentContext] == context_) {
            [EAGLContext setCurrentContext:nil];
        }

        context_ = nullptr;
        layer_ = nullptr;
    }

    void gl_context_eagl::destroy_storage() {
        if (colour_renderbuffer_) {
            glDeleteRenderbuffers(1, &colour_renderbuffer_);
            colour_renderbuffer_ = 0;
        }
        if (depth_renderbuffer_) {
            glDeleteRenderbuffers(1, &depth_renderbuffer_);
            depth_renderbuffer_ = 0;
        }
    }

    void gl_context_eagl::create_storage() {
        if ((context_ == nullptr) || (layer_ == nullptr)) {
            return;
        }

        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);

        // Colour renderbuffer backed by the layer's drawable.
        if (colour_renderbuffer_ == 0) {
            glGenRenderbuffers(1, &colour_renderbuffer_);
        }
        glBindRenderbuffer(GL_RENDERBUFFER, colour_renderbuffer_);
        [context_ renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer_];
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colour_renderbuffer_);

        GLint width = 0;
        GLint height = 0;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);

        m_backbuffer_width = static_cast<std::uint32_t>(width);
        m_backbuffer_height = static_cast<std::uint32_t>(height);

        LOG_INFO(DRIVER_GRAPHICS, "EAGL renderbuffer storage: {}x{} (layer {})",
            width, height, (void *)layer_);

        // Matching depth + stencil buffer.
        if (depth_renderbuffer_ == 0) {
            glGenRenderbuffers(1, &depth_renderbuffer_);
        }
        glBindRenderbuffer(GL_RENDERBUFFER, depth_renderbuffer_);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth_renderbuffer_);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depth_renderbuffer_);

        const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            LOG_ERROR(DRIVER_GRAPHICS, "EAGL swapchain framebuffer incomplete (status 0x{:X})", status);
        }

        glBindRenderbuffer(GL_RENDERBUFFER, colour_renderbuffer_);
    }

    bool gl_context_eagl::is_headless() const {
        return layer_ == nullptr;
    }

    std::unique_ptr<gl_context> gl_context_eagl::create_shared_context() {
        // The OGL driver runs single-context; no shared resource-loading context is needed.
        return nullptr;
    }

    bool gl_context_eagl::make_current() {
        if (context_ == nullptr) {
            return false;
        }
        return [EAGLContext setCurrentContext:context_] == YES;
    }

    bool gl_context_eagl::clear_current() {
        return [EAGLContext setCurrentContext:nil] == YES;
    }

    void gl_context_eagl::update(const std::uint32_t new_width, const std::uint32_t new_height) {
        if (context_ == nullptr) {
            return;
        }

        [EAGLContext setCurrentContext:context_];

        // Re-acquire the drawable's storage; the layer may have changed size.
        create_storage();
    }

    void gl_context_eagl::update_surface(void *new_surface) {
        layer_ = (__bridge CAEAGLLayer *)(new_surface);

        if (context_) {
            [EAGLContext setCurrentContext:context_];
            create_storage();
        }
    }

    void gl_context_eagl::swap_buffers() {
        if (context_ == nullptr) {
            return;
        }

        glBindRenderbuffer(GL_RENDERBUFFER, colour_renderbuffer_);
        [context_ presentRenderbuffer:GL_RENDERBUFFER];
    }

    void gl_context_eagl::set_swap_interval(const std::int32_t interval) {
        // iOS presents in lock-step with CADisplayLink; there is no equivalent of an
        // explicit swap interval, so this is a no-op.
        (void)interval;
    }
}
