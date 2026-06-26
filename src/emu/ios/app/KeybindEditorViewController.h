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

// Keybind editor: lists every emulator action; each opens a per-action screen with up to 2
// keyboard slots and 3 controller slots (each settable by pressing a key/button or a combo).
// uid 0 edits the GLOBAL bindings; a non-zero uid edits that game's per-game override (which
// fully supersedes the global set for the game). onChange fires after any save so the live
// InputManager bindings can be reloaded.
@interface KeybindEditorViewController : UITableViewController
- (instancetype)initWithUid:(uint32_t)uid scopeName:(NSString *)scopeName onChange:(void (^_Nullable)(void))onChange;
@end

NS_ASSUME_NONNULL_END
