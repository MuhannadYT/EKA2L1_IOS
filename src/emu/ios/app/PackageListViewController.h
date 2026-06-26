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

// Lists the installed removable packages (user-installed SIS apps). Long-press a row
// (or swipe) to delete a package, mirroring the Android frontend's package manager.
// Deleting reboots the guest in place, so the host should refresh its apps list after.
@interface PackageListViewController : UITableViewController

// Called on the main thread after one or more packages were uninstalled (the guest
// rebooted), so the presenter can refresh its apps list / icon cache.
@property (nonatomic, copy, nullable) void (^onChanged)(void);

@end

NS_ASSUME_NONNULL_END
