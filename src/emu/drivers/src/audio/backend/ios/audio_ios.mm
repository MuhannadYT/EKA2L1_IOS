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
#include <drivers/audio/backend/ios/audio_ios.h>
#include <common/log.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <cstring>

namespace eka2l1::drivers {
    static void ensure_audio_session() {
        static bool configured = false;
        if (configured) {
            return;
        }
        configured = true;

        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err];
        if (err) {
            LOG_WARN(DRIVER_AUD, "AVAudioSession setCategory failed: {}", [[err localizedDescription] UTF8String]);
            err = nil;
        }

        // Prefer a hardware rate matching our streams (avoids extra resampling) and a
        // generous IO buffer so the emulator has time to refill between callbacks —
        // a too-small buffer causes underruns heard as crackling/scratching.
        [session setPreferredSampleRate:44100.0 error:&err]; err = nil;
        [session setPreferredIOBufferDuration:0.023 error:&err]; err = nil; // ~1024 frames @ 44.1k

        [session setActive:YES error:&err];
        if (err) {
            LOG_WARN(DRIVER_AUD, "AVAudioSession setActive failed: {}", [[err localizedDescription] UTF8String]);
        }
    }

    class ios_audio_output_stream : public audio_output_stream {
        AudioComponentInstance unit_;
        data_callback callback_;
        std::uint32_t rate_;
        std::uint8_t chans_;

        std::atomic<float> volume_;
        std::atomic<bool> playing_;
        std::atomic<std::uint64_t> frames_rendered_;

        bool valid_;

    public:
        ios_audio_output_stream(audio_driver *driver, const std::uint32_t sample_rate,
            const std::uint8_t channels, data_callback callback)
            : audio_output_stream(driver, sample_rate, channels)
            , unit_(nullptr)
            , callback_(std::move(callback))
            , rate_(sample_rate)
            , chans_(channels ? channels : 1)
            , volume_(1.0f)
            , playing_(false)
            , frames_rendered_(0)
            , valid_(false) {
            ensure_audio_session();
            valid_ = setup_unit();
        }

        ~ios_audio_output_stream() override {
            if (unit_) {
                AudioOutputUnitStop(unit_);
                AudioUnitUninitialize(unit_);
                AudioComponentInstanceDispose(unit_);
                unit_ = nullptr;
            }
        }

        bool start() override {
            if (!valid_) {
                return false;
            }
            if (playing_.exchange(true)) {
                return true;
            }
            return AudioOutputUnitStart(unit_) == noErr;
        }

        bool stop() override {
            if (!valid_) {
                return false;
            }
            if (!playing_.exchange(false)) {
                return true;
            }
            return AudioOutputUnitStop(unit_) == noErr;
        }

        void pause() override {
            stop();
        }

        bool is_playing() override {
            return playing_.load();
        }

        bool is_pausing() override {
            return !playing_.load();
        }

        bool set_volume(const float volume) override {
            volume_.store(volume < 0.0f ? 0.0f : (volume > 1.0f ? 1.0f : volume));
            return true;
        }

        float get_volume() const override {
            return volume_.load();
        }

        bool current_frame_position(std::uint64_t *pos) override {
            if (pos) {
                *pos = frames_rendered_.load();
            }
            return true;
        }

    private:
        bool setup_unit() {
            AudioComponentDescription desc = {};
            desc.componentType = kAudioUnitType_Output;
            desc.componentSubType = kAudioUnitSubType_RemoteIO;
            desc.componentManufacturer = kAudioUnitManufacturer_Apple;

            AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
            if (!comp) {
                LOG_ERROR(DRIVER_AUD, "iOS audio: RemoteIO component not found");
                return false;
            }

            if (AudioComponentInstanceNew(comp, &unit_) != noErr) {
                LOG_ERROR(DRIVER_AUD, "iOS audio: failed to create RemoteIO instance");
                return false;
            }

            // Enable output on the output bus (element 0).
            const UInt32 enable = 1;
            AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                0, &enable, sizeof(enable));

            AudioStreamBasicDescription fmt = {};
            fmt.mSampleRate = static_cast<Float64>(rate_);
            fmt.mFormatID = kAudioFormatLinearPCM;
            fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            fmt.mFramesPerPacket = 1;
            fmt.mChannelsPerFrame = chans_;
            fmt.mBitsPerChannel = 16;
            fmt.mBytesPerFrame = chans_ * sizeof(std::int16_t);
            fmt.mBytesPerPacket = fmt.mBytesPerFrame;

            if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                    0, &fmt, sizeof(fmt)) != noErr) {
                LOG_ERROR(DRIVER_AUD, "iOS audio: failed to set stream format ({} Hz, {} ch)", rate_, chans_);
                return false;
            }

            AURenderCallbackStruct cb = {};
            cb.inputProc = &ios_audio_output_stream::render_cb;
            cb.inputProcRefCon = this;
            AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                0, &cb, sizeof(cb));

            if (AudioUnitInitialize(unit_) != noErr) {
                LOG_ERROR(DRIVER_AUD, "iOS audio: failed to initialise RemoteIO unit");
                return false;
            }

            LOG_INFO(DRIVER_AUD, "iOS RemoteIO audio output ready ({} Hz, {} ch)", rate_, chans_);
            return true;
        }

        static OSStatus render_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
            UInt32 bus, UInt32 num_frames, AudioBufferList *data) {
            ios_audio_output_stream *self = reinterpret_cast<ios_audio_output_stream *>(ref);

            for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
                std::int16_t *out = reinterpret_cast<std::int16_t *>(data->mBuffers[b].mData);
                const std::size_t total_samples = data->mBuffers[b].mDataByteSize / sizeof(std::int16_t);

                std::size_t produced_frames = 0;
                if (self->callback_) {
                    produced_frames = self->callback_(out, static_cast<std::size_t>(num_frames));
                }

                std::size_t produced_samples = produced_frames * self->chans_;
                if (produced_samples > total_samples) {
                    produced_samples = total_samples;
                }
                if (produced_samples < total_samples) {
                    std::memset(out + produced_samples, 0, (total_samples - produced_samples) * sizeof(std::int16_t));
                }

                const float vol = self->volume_.load();
                if (vol < 0.999f) {
                    for (std::size_t i = 0; i < produced_samples; i++) {
                        out[i] = static_cast<std::int16_t>(out[i] * vol);
                    }
                }
            }

            self->frames_rendered_.fetch_add(num_frames);
            return noErr;
        }
    };

    std::unique_ptr<audio_output_stream> make_ios_audio_output_stream(audio_driver *driver,
        const std::uint32_t sample_rate, const std::uint8_t channels, data_callback callback) {
        return std::make_unique<ios_audio_output_stream>(driver, sample_rate, channels, std::move(callback));
    }
}
