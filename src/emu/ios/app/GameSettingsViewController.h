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

@class GameSettingsViewController;

@protocol GameSettingsViewControllerDelegate <NSObject>
// Fired whenever any per-game setting is saved (so the running game can apply it live).
- (void)gameSettingsDidChangeForUid:(uint32_t)uid;
@end

// Per-game ("this game only") settings screen: refresh rate, screen gravity for portrait and
// landscape, on-screen-controls opacity and active layout. Reachable by long-pressing a game
// in the apps list. Persisted via GameSettingsStore.
@interface GameSettingsViewController : UITableViewController
- (instancetype)initWithUid:(uint32_t)uid name:(NSString *)name;
@property (nonatomic, weak) id<GameSettingsViewControllerDelegate> settingsDelegate;
@end

NS_ASSUME_NONNULL_END
