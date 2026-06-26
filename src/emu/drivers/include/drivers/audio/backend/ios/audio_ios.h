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

#include <drivers/audio/stream.h>

#include <cstdint>
#include <memory>

namespace eka2l1::drivers {
    class audio_driver;

    // Native iOS audio output stream backed by a RemoteIO AudioUnit (the bundled cubeb
    // AudioUnit backend is macOS-only). Plays signed-16-bit interleaved PCM pulled from
    // the supplied data callback.
    std::unique_ptr<audio_output_stream> make_ios_audio_output_stream(audio_driver *driver,
        const std::uint32_t sample_rate, const std::uint8_t channels, data_callback callback);
}
