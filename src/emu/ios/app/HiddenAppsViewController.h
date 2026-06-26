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
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Lists the apps the user has hidden from the homescreen apps list for the *current*
// device, and lets them unhide one (tap a row, or swipe → Unhide). Hiding is a purely
// front-end filter (the core still knows about the app); the hidden set is stored in
// NSUserDefaults keyed by the device's firmware code, so it is independent per device.
@interface HiddenAppsViewController : UITableViewController

// Called on the main thread after an app was unhidden, so the presenter can refresh its
// homescreen apps list.
@property (nonatomic, copy, nullable) void (^onChanged)(void);

// ---- Per-device hidden-app store (used by the homescreen as well) ----------
// The firmware code of the currently booted device (the key the hidden set is stored
// under), or @"" when no device is installed.
+ (NSString *)currentDeviceKey;
// The set of hidden app UIDs (NSNumber, uint32) for the current device, for fast lookup
// while building the homescreen list.
+ (NSSet<NSNumber *> *)hiddenUidsForCurrentDevice;
// How many apps are currently hidden for the current device (for the menu badge).
+ (NSUInteger)hiddenCountForCurrentDevice;
+ (BOOL)isUidHidden:(uint32_t)uid;
+ (void)setUid:(uint32_t)uid hidden:(BOOL)hidden;

@end

NS_ASSUME_NONNULL_END
