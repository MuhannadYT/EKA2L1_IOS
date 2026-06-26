/*
 * Copyright (c) 2026 EKA2L1 Team.
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

#include <drivers/hwrm/backend/ios/vibration_ios.h>

#include <common/log.h>

#include <algorithm>
#include <cmath>

#import <AudioToolbox/AudioToolbox.h>
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>

namespace eka2l1::drivers::hwrm {
    vibrator_ios::vibrator_ios() {
        if (@available(iOS 13.0, *)) {
            if (CHHapticEngine.capabilitiesForHardware.supportsHaptics) {
                NSError *err = nil;
                CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&err];
                if (engine && !err) {
                    // Let the engine sleep when idle and spin back up on the next play() — we always
                    // call startAndReturnError: before playing, so it recovers from system resets too.
                    engine.autoShutdownEnabled = YES;
                    supports_haptics_ = true;
                    engine_ = (void *)CFBridgingRetain(engine);
                } else {
                    LOG_WARN(SERVICE_HWRM, "CoreHaptics engine init failed; falling back to system vibrate");
                }
            }
        }
    }

    vibrator_ios::~vibrator_ios() {
        const std::lock_guard<std::mutex> guard(lock_);
        stop_player_locked();
        if (engine_) {
            if (@available(iOS 13.0, *)) {
                CHHapticEngine *engine = (CHHapticEngine *)CFBridgingRelease(engine_);
                [engine stopWithCompletionHandler:nil];
            } else {
                CFRelease(engine_);
            }
            engine_ = nullptr;
        }
    }

    void vibrator_ios::stop_player_locked() {
        if (!player_) {
            return;
        }
        if (@available(iOS 13.0, *)) {
            id<CHHapticPatternPlayer> player = CFBridgingRelease(player_);
            NSError *err = nil;
            [player stopAtTime:0 error:&err];
        } else {
            CFRelease(player_);
        }
        player_ = nullptr;
    }

    void vibrator_ios::vibrate(const std::uint32_t millisecs, const std::int16_t intensity) {
        // "Haptic passthrough" off → behave exactly like the null stub: never buzz the device.
        if (!haptic_passthrough_enabled() || millisecs == 0) {
            return;
        }

        if (@available(iOS 13.0, *)) {
            if (supports_haptics_ && engine_) {
                @autoreleasepool {
                    const std::lock_guard<std::mutex> guard(lock_);
                    CHHapticEngine *engine = (__bridge CHHapticEngine *)engine_;
                    NSError *err = nil;
                    [engine startAndReturnError:&err];   // no-op if already running
                    if (!err) {
                        // Map the Symbian intensity [-100, 100] to a haptic amplitude [0, 1]. 0 means
                        // "default intensity" (the no-intensity vibrate command), so use a firm buzz.
                        float amplitude = (intensity == 0) ? 0.8f : std::abs((float)intensity) / 100.0f;
                        amplitude = std::min(1.0f, std::max(0.05f, amplitude));

                        CHHapticEventParameter *ip = [[CHHapticEventParameter alloc]
                            initWithParameterID:CHHapticEventParameterIDHapticIntensity value:amplitude];
                        CHHapticEventParameter *sp = [[CHHapticEventParameter alloc]
                            initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f];
                        CHHapticEvent *event = [[CHHapticEvent alloc]
                            initWithEventType:CHHapticEventTypeHapticContinuous
                                   parameters:@[ ip, sp ]
                                 relativeTime:0
                                     duration:(double)millisecs / 1000.0];

                        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                                               parameters:@[]
                                                                                    error:&err];
                        if (pattern && !err) {
                            id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pattern error:&err];
                            if (player && !err) {
                                stop_player_locked();   // replace any in-flight buzz
                                [player startAtTime:0 error:&err];
                                if (!err) {
                                    player_ = (void *)CFBridgingRetain(player);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }

        // No CoreHaptics (older device / engine error): a single fixed-length system buzz. Ignores
        // duration and intensity, but it's better than silence.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }

    void vibrator_ios::stop_vibrate() {
        const std::lock_guard<std::mutex> guard(lock_);
        stop_player_locked();
    }
}
