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
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Screen gravity values, matching launcher::draw (src/emu/ios/src/launcher.cpp):
// 0 = Left, 1 = Top, 2 = Center, 3 = Right, 4 = Bottom.
typedef NS_ENUM(NSInteger, EKAScreenGravity) {
    EKAScreenGravityLeft = 0,
    EKAScreenGravityTop = 1,
    EKAScreenGravityCenter = 2,
    EKAScreenGravityRight = 3,
    EKAScreenGravityBottom = 4
};

// Per-game settings for the iOS frontend. One JSON file per app UID under
// <Documents>/game_settings/<UID_HEX>.json. This is the single source of truth for the
// iOS-specific per-game preferences; the refresh rate is additionally pushed into the
// emulator core's app-settings (compat/<UID>.yml) so the guest actually throttles to it.
//
// Later phases add customLayoutsPortrait/Landscape and keybindOverrides to the same store.
@interface EKAGameSettings : NSObject
@property (nonatomic, assign) NSInteger refreshRate;        // 1..120, default 60
@property (nonatomic, assign) EKAScreenGravity gravityPortrait;   // default Top
@property (nonatomic, assign) EKAScreenGravity gravityLandscape;  // default Center
@property (nonatomic, assign) BOOL hideDynamicIsland;       // default YES (keep guest out of safe-area/island)
@property (nonatomic, assign) BOOL showStatus;             // default NO (FPS + speed% overlay on top)
@property (nonatomic, assign) BOOL autoScalePortrait;      // default YES (shrink controls to fit, portrait)
@property (nonatomic, assign) BOOL autoScaleLandscape;     // default YES (shrink controls to fit, landscape)
@property (nonatomic, assign) CGFloat controlsOpacity;      // 0.2..1.0, default 1.0
@property (nonatomic, assign) NSInteger keyLayout;          // 0 = None, 1..4
@property (nonatomic, assign) BOOL hapticFeedback;         // default YES (vibrate on on-screen button press; disable per-game)
@property (nonatomic, assign) BOOL gyroPassthrough;        // default YES (feed device tilt to the guest accelerometer)
@property (nonatomic, assign) BOOL hapticPassthrough;      // default YES (pass the guest's vibration requests through to the Taptic Engine)
// Render scale = drawable pixels per point (the EAGL contentsScale). 0 = Native (the screen's own
// scale — the DEFAULT, 3x on this device); otherwise an explicit 1.0..3.0. Lower fills fewer pixels
// (a big win on the iOS Simulator's software GL); the low-res Symbian guest is upscaled either way,
// so it trades performance more than sharpness.
@property (nonatomic, assign) CGFloat renderScale;
// Upscale/filter shader name (e.g. "natural"); empty string = OFF (the default). Maps to a bundled
// resources/upscale/<name>.frag and is applied via the core's per-app filter_shader_path.
@property (nonatomic, copy) NSString *filterShader;
// Custom touch layouts (arrays of element dicts, see GameControlsView). nil = use keyLayout.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *customLayoutPortrait;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *customLayoutLandscape;
@end

@interface GameSettingsStore : NSObject

// Load (or default-construct) the settings for an app UID. Never returns nil.
+ (EKAGameSettings *)settingsForUid:(uint32_t)uid;

// Persist the settings for an app UID.
+ (void)saveSettings:(EKAGameSettings *)settings forUid:(uint32_t)uid;

// True if a settings file already exists on disk for this UID.
+ (BOOL)hasSettingsForUid:(uint32_t)uid;

@end

NS_ASSUME_NONNULL_END
