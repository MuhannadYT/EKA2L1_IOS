/*
 * Copyright (c) 2021 EKA2L1 Team.
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

#include <common/platform.h>
#include <drivers/hwrm/backend/vibration_null.h>
#ifdef EKA2L1_PLATFORM_ANDROID
#include <drivers/hwrm/backend/vibration_jdk.h>
#elif defined(EKA2L1_PLATFORM_IOS)
#include <drivers/hwrm/backend/ios/vibration_ios.h>
#else
#include <drivers/hwrm/backend/vibration_sdl2.h>
#endif

#include <atomic>

namespace eka2l1::drivers::hwrm {
    // On by default: the guest's vibration requests pass through to the device's haptics until
    // the frontend disables it (per-game). Only the iOS CoreHaptics backend consults this.
    static std::atomic<bool> g_haptic_passthrough_enabled{ true };

    void set_haptic_passthrough_enabled(bool enabled) {
        g_haptic_passthrough_enabled.store(enabled, std::memory_order_relaxed);
    }

    bool haptic_passthrough_enabled() {
        return g_haptic_passthrough_enabled.load(std::memory_order_relaxed);
    }

    std::unique_ptr<vibrator> make_suitable_vibrator() {
#ifdef EKA2L1_PLATFORM_ANDROID
        return std::make_unique<vibrator_jdk>();
#elif defined(EKA2L1_PLATFORM_IOS)
        // Pass the guest's vibration requests through to the device's Taptic Engine (CoreHaptics).
        return std::make_unique<vibrator_ios>();
#else
        return std::make_unique<vibrator_sdl2>();
#endif
    }
}