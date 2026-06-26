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

// A simple modal menu that works with touch AND game-controller/keyboard navigation (unlike
// UIAlertController, which can't be driven by a controller). Shows a titled list of options;
// one row is highlighted and can be moved with navigate: and chosen with confirm. Used for the
// in-game menu and the layout chooser so they are reachable without touching the screen.
@interface GameMenuView : UIView

- (instancetype)initWithTitle:(NSString *)title;

// Add a selectable option. `destructive` tints it red. The handler runs after the menu hides.
- (void)addOption:(NSString *)title destructive:(BOOL)destructive handler:(void (^_Nullable)(void))handler;

// Show centered over `parent`; `onDismiss` runs whenever the menu goes away (any reason).
- (void)showInView:(UIView *)parent onDismiss:(void (^_Nullable)(void))onDismiss;
- (void)dismiss;

// Controller / keyboard navigation. dir: -1 = previous, +1 = next, 0 = confirm highlighted.
- (void)navigate:(NSInteger)dir;

@end

NS_ASSUME_NONNULL_END
