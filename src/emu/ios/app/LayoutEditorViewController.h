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

// Touch-layout editor for one game and one orientation. Shows the on-screen controls over a
// preview area matching the target orientation's aspect; drag to move, pinch (or −/+) to
// resize, Add to insert a button/D-pad, Delete to remove, Reset to restore the default.
// Saves the arranged layout to the game's per-game settings (portrait or landscape) on Save.
@interface LayoutEditorViewController : UIViewController
- (instancetype)initWithUid:(uint32_t)uid name:(NSString *)name portrait:(BOOL)portrait
                    onChange:(void (^_Nullable)(void))onChange;
@end

NS_ASSUME_NONNULL_END
