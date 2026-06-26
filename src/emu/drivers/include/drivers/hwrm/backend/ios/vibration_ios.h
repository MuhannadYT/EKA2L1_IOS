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

#pragma once

#include <drivers/hwrm/vibration.h>

#include <mutex>

namespace eka2l1::drivers::hwrm {
    // Passes the guest's vibration requests through to the device. Uses CoreHaptics (the Taptic
    // Engine) for variable duration/intensity on capable devices, and falls back to the fixed
    // system "vibrate" buzz otherwise. Gated by haptic_passthrough_enabled() so the frontend can
    // turn it off per-game. The ObjC objects are held as CF-bridged void * (this backend is built
    // without ARC, like the rest of the drivers layer).
    class vibrator_ios : public vibrator {
    public:
        vibrator_ios();
        ~vibrator_ios() override;

        void vibrate(const std::uint32_t millisecs, const std::int16_t intensity = 0) override;
        void stop_vibrate() override;

    private:
        // Stop + release the currently playing pattern (caller holds lock_).
        void stop_player_locked();

        std::mutex lock_;
        void *engine_ = nullptr;   // CHHapticEngine * (retained), or null when haptics unsupported
        void *player_ = nullptr;   // id<CHHapticPatternPlayer> currently playing (retained), or null
        bool supports_haptics_ = false;
    };
}
