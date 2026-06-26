/*
 * Copyright (c) 2020 EKA2L1 Team.
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

#include <common/log.h>
#include <common/platform.h>
#include <drivers/audio/backend/cubeb/audio_cubeb.h>
#include <drivers/audio/backend/cubeb/stream_cubeb.h>
#include <drivers/audio/backend/baeplat_impl.h>

#if EKA2L1_PLATFORM(WIN32)
#include <objbase.h>
#elif EKA2L1_PLATFORM(ANDROID)
#include <common/android/audio.h>
#elif EKA2L1_PLATFORM(IOS)
#include <drivers/audio/backend/ios/audio_ios.h>
#endif

namespace eka2l1::drivers {
    cubeb_audio_driver::cubeb_audio_driver(const std::uint32_t initial_master_volume, const player_type preferred_midi_backend)
        : audio_driver(initial_master_volume, preferred_midi_backend)
        , context_(nullptr)
        , init_(false) {
        if (cubeb_init(&context_, "EKA2L1 Audio Driver", nullptr) != CUBEB_OK) {
            LOG_CRITICAL(DRIVER_AUD, "Can't initialize Cubeb audio driver!");
            return;
        }

        init_ = true;
    }

    cubeb_audio_driver::~cubeb_audio_driver() {
        BAE_DriverDeactivated(this);
        
        if (context_) {
            cubeb_destroy(context_);
        }
    }

    std::uint32_t cubeb_audio_driver::native_sample_rate() {
        std::uint32_t preferred_rate = 0;

#ifdef EKA2L1_PLATFORM_ANDROID
        preferred_rate = 48000;
#elif defined(EKA2L1_PLATFORM_IOS)
        // No cubeb context on iOS (RemoteIO backend); RemoteIO resamples internally.
        preferred_rate = 44100;
#else
        const auto result = cubeb_get_preferred_sample_rate(context_, &preferred_rate);

        if (result != CUBEB_OK) {
            return 0;
        }
#endif

        return preferred_rate;
    }

    // Silent fallback streams used when no audio backend could be initialised (e.g. on
    // iOS where the bundled cubeb AudioUnit backend is unavailable). They satisfy the
    // guest audio API as no-ops instead of leaving a null stream that callers deref.
    namespace {
        struct null_audio_output_stream : public audio_output_stream {
            explicit null_audio_output_stream(audio_driver *driver, const std::uint32_t sr, const std::uint8_t ch)
                : audio_output_stream(driver, sr, ch) {}
            bool start() override { return true; }
            bool stop() override { return true; }
            void pause() override {}
            bool is_playing() override { return false; }
            bool is_pausing() override { return false; }
            bool set_volume(const float) override { return true; }
            float get_volume() const override { return 0.0f; }
            bool current_frame_position(std::uint64_t *pos) override { if (pos) { *pos = 0; } return true; }
        };

        struct null_audio_input_stream : public audio_input_stream {
            explicit null_audio_input_stream(audio_driver *driver, const std::uint32_t sr, const std::uint8_t ch)
                : audio_input_stream(driver, sr, ch) {}
            bool start() override { return true; }
            bool stop() override { return true; }
            bool is_recording() override { return false; }
            bool current_frame_position(std::uint64_t *pos) override { if (pos) { *pos = 0; } return true; }
        };
    }

    std::unique_ptr<audio_output_stream> cubeb_audio_driver::new_output_stream(const std::uint32_t sample_rate,
        const std::uint8_t channels, data_callback callback) {
#if EKA2L1_PLATFORM(IOS)
        // iOS has no working cubeb backend; use the native RemoteIO AudioUnit stream.
        return make_ios_audio_output_stream(this, sample_rate, channels, std::move(callback));
#else
        if (!init_) {
            return std::make_unique<null_audio_output_stream>(this, sample_rate, channels);
        }

        return std::make_unique<cubeb_audio_output_stream>(this, context_, sample_rate, channels, callback);
#endif
    }

    std::unique_ptr<audio_input_stream> cubeb_audio_driver::new_input_stream(const std::uint32_t sample_rate,
        const std::uint8_t channels, data_callback callback) {
        if (!init_) {
            return std::make_unique<null_audio_input_stream>(this, sample_rate, channels);
        }

#if EKA2L1_PLATFORM(ANDROID)
        // If it does not work, just try our luck... ;D
        common::android::prepare_audio_record();
#endif

        return std::make_unique<cubeb_audio_input_stream>(this, context_, sample_rate, channels, callback);
    }
};
