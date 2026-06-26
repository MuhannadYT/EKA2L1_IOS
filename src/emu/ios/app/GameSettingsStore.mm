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
#import "GameSettingsStore.h"

@implementation EKAGameSettings
- (instancetype)init {
    self = [super init];
    if (self) {
        // Defaults reproduce the previous fixed behaviour (60 fps, fully opaque overlay,
        // no on-screen layout) while giving the screen room for the keypad in portrait.
        _refreshRate = 60;
        _gravityPortrait = EKAScreenGravityTop;
        _gravityLandscape = EKAScreenGravityCenter;
        _hideDynamicIsland = YES;
        _showStatus = NO;
        _autoScalePortrait = YES;
        _autoScaleLandscape = YES;
        _controlsOpacity = 1.0;
        _keyLayout = 0;
        _hapticFeedback = YES;   // on by default; disable per-game under Key Layout
        _gyroPassthrough = YES;  // on by default; feed device tilt to the guest accelerometer
        _hapticPassthrough = YES; // on by default; pass the guest's vibration requests to the Taptic Engine
        _renderScale = 0.0;   // 0 = Native (the screen's own scale)
        _filterShader = @"";  // empty = upscale shader OFF
    }
    return self;
}
@end

@implementation GameSettingsStore

+ (NSString *)settingsDir {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"game_settings"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)pathForUid:(uint32_t)uid {
    return [[self settingsDir] stringByAppendingPathComponent:[NSString stringWithFormat:@"%08X.json", uid]];
}

+ (BOOL)hasSettingsForUid:(uint32_t)uid {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self pathForUid:uid]];
}

+ (NSInteger)clampGravity:(NSInteger)g fallback:(NSInteger)fallback {
    return (g >= EKAScreenGravityLeft && g <= EKAScreenGravityBottom) ? g : fallback;
}

+ (EKAGameSettings *)settingsForUid:(uint32_t)uid {
    EKAGameSettings *s = [[EKAGameSettings alloc] init];

    NSData *data = [NSData dataWithContentsOfFile:[self pathForUid:uid]];
    if (!data) {
        return s;
    }
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return s;
    }

    if (dict[@"refreshRate"]) {
        s.refreshRate = MAX(1, MIN(120, [dict[@"refreshRate"] integerValue]));
    }
    if (dict[@"gravityPortrait"]) {
        s.gravityPortrait = (EKAScreenGravity)[self clampGravity:[dict[@"gravityPortrait"] integerValue]
                                                        fallback:EKAScreenGravityTop];
    }
    if (dict[@"gravityLandscape"]) {
        s.gravityLandscape = (EKAScreenGravity)[self clampGravity:[dict[@"gravityLandscape"] integerValue]
                                                         fallback:EKAScreenGravityCenter];
    }
    if (dict[@"hideDynamicIsland"] != nil) {
        s.hideDynamicIsland = [dict[@"hideDynamicIsland"] boolValue];
    }
    if (dict[@"showStatus"] != nil) {
        s.showStatus = [dict[@"showStatus"] boolValue];
    }
    if (dict[@"autoScalePortrait"] != nil) {
        s.autoScalePortrait = [dict[@"autoScalePortrait"] boolValue];
    }
    if (dict[@"autoScaleLandscape"] != nil) {
        s.autoScaleLandscape = [dict[@"autoScaleLandscape"] boolValue];
    }
    if (dict[@"controlsOpacity"]) {
        s.controlsOpacity = MAX(0.2, MIN(1.0, [dict[@"controlsOpacity"] doubleValue]));
    }
    if (dict[@"keyLayout"]) {
        // 0=None, 1..4 built-in, 5 = "Layout 1.5 (#/*)", 6 = "Joystick".
        s.keyLayout = MAX(0, MIN(6, [dict[@"keyLayout"] integerValue]));
    }
    if (dict[@"hapticFeedback"] != nil) {
        s.hapticFeedback = [dict[@"hapticFeedback"] boolValue];
    }
    if (dict[@"gyroPassthrough"] != nil) {
        s.gyroPassthrough = [dict[@"gyroPassthrough"] boolValue];
    }
    if (dict[@"hapticPassthrough"] != nil) {
        s.hapticPassthrough = [dict[@"hapticPassthrough"] boolValue];
    }
    if (dict[@"renderScale"]) {
        const double v = [dict[@"renderScale"] doubleValue];
        s.renderScale = (v <= 0.0) ? 0.0 : MAX(0.5, MIN(3.0, v));   // 0 = Native
    }
    if ([dict[@"filterShader"] isKindOfClass:[NSString class]]) {
        s.filterShader = dict[@"filterShader"];
    }
    if ([dict[@"customLayoutPortrait"] isKindOfClass:[NSArray class]]) {
        s.customLayoutPortrait = dict[@"customLayoutPortrait"];
    }
    if ([dict[@"customLayoutLandscape"] isKindOfClass:[NSArray class]]) {
        s.customLayoutLandscape = dict[@"customLayoutLandscape"];
    }
    return s;
}

+ (void)saveSettings:(EKAGameSettings *)settings forUid:(uint32_t)uid {
    NSMutableDictionary *dict = [@{
        @"refreshRate": @(settings.refreshRate),
        @"gravityPortrait": @(settings.gravityPortrait),
        @"gravityLandscape": @(settings.gravityLandscape),
        @"hideDynamicIsland": @(settings.hideDynamicIsland),
        @"showStatus": @(settings.showStatus),
        @"autoScalePortrait": @(settings.autoScalePortrait),
        @"autoScaleLandscape": @(settings.autoScaleLandscape),
        @"controlsOpacity": @(settings.controlsOpacity),
        @"keyLayout": @(settings.keyLayout),
        @"hapticFeedback": @(settings.hapticFeedback),
        @"gyroPassthrough": @(settings.gyroPassthrough),
        @"hapticPassthrough": @(settings.hapticPassthrough),
        @"renderScale": @(settings.renderScale),
        @"filterShader": (settings.filterShader ?: @"")
    } mutableCopy];
    if (settings.customLayoutPortrait) dict[@"customLayoutPortrait"] = settings.customLayoutPortrait;
    if (settings.customLayoutLandscape) dict[@"customLayoutLandscape"] = settings.customLayoutLandscape;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self pathForUid:uid] atomically:YES];
}

@end
