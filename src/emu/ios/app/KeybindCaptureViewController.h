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

// Modal "press a key / button to bind" capture. Records the set of keys/buttons held together
// (so combos like Shift+Enter or X+Start are captured), committing when they are released.
// completion is called with the captured combo — NSArray<NSNumber*> (keyboard HID codes) or
// NSArray<NSString*> (controller tokens) — or nil if cancelled.
@interface KeybindCaptureViewController : UIViewController
- (instancetype)initForController:(BOOL)isController completion:(void (^)(NSArray * _Nullable combo))completion;
@end

NS_ASSUME_NONNULL_END
