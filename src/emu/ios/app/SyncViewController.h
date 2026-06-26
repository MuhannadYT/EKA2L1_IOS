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

// "Progress Sync" page: enable iCloud sync, choose what to sync, and manage the backup
// (size / delete / download .zip / import .zip).
@interface SyncViewController : UITableViewController
// Called on the main thread after a backup is imported (data + emulator state changed), so the
// host can refresh its device/apps UI.
@property (nonatomic, copy, nullable) void (^onDataImported)(void);
@end

NS_ASSUME_NONNULL_END
