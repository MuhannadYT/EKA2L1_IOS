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

typedef NS_ENUM(NSInteger, EKASyncStatus) {
    EKASyncStatusIdle = 0,    // iCloud off
    EKASyncStatusSyncing,     // upload/download in flight
    EKASyncStatusSynced,      // up to date
    EKASyncStatusUnavailable, // iCloud on but no account/entitlement
    EKASyncStatusError
};

// "Progress Sync": optional iCloud backup of the user's progress, plus local zip export/import.
// One backup .zip captures either just game progress (the C/D/E drives + the iOS frontend's
// per-game settings/keybinds) or, additionally, the installed Symbian devices + ROMs.
@interface EKASyncManager : NSObject

+ (instancetype)shared;

// Persisted preferences (NSUserDefaults).
@property (nonatomic, assign) BOOL iCloudEnabled;
@property (nonatomic, assign) BOOL syncGameProgress;   // always on while iCloud is on
@property (nonatomic, assign) BOOL syncDevices;        // experimental: also back up devices/ROMs

@property (nonatomic, readonly) EKASyncStatus status;
@property (nonatomic, copy, nullable) void (^onStatusChange)(void);   // called on the main thread

// True when an iCloud ubiquity container is reachable (needs real code signing + a signed-in
// iCloud account; always NO on an ad-hoc-signed simulator build).
- (BOOL)iCloudAvailable;

// Uncompressed size (bytes) a backup would occupy. Walks the whole data tree — with devices
// included this covers the ROMs/Z drive (tens of thousands of files), so it is slow: never
// call it on the main thread. `currentBackupSize` uses the current `syncDevices` scope.
- (unsigned long long)currentBackupSize;
- (unsigned long long)backupSizeForDevices:(BOOL)devices;

// Create a temporary .zip of the current scope for sharing (export). Calls back on the main
// thread with the file URL (nil on failure).
- (void)exportBackup:(void (^)(NSURL * _Nullable zipURL))done;

// Restore from a user-picked .zip (reboots the emulator). Calls back on the main thread.
- (void)importBackupFromURL:(NSURL *)url done:(void (^)(BOOL ok))done;

// iCloud flows — no-ops unless iCloudEnabled and a container is available.
- (void)syncDownOnLaunch;     // pull the newest backup when the app opens
- (void)saveUpOnGameClose;    // push a backup right after a game exits
- (void)syncNow:(nullable void (^)(BOOL ok))done;   // manual refresh (push)
- (void)deleteICloudBackup:(void (^)(BOOL ok))done;

@end

NS_ASSUME_NONNULL_END
