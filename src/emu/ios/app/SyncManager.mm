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
#import "SyncManager.h"

#include <ios/emu_bridge.h>

static NSString *const kICloudEnabled = @"EKAiCloudSyncEnabled";
static NSString *const kSyncGameProgress = @"EKASyncGameProgress";
static NSString *const kSyncDevices = @"EKASyncDevices";
static NSString *const kBackupName = @"eka2l1_backup.zip";

@implementation EKASyncManager {
    EKASyncStatus _status;
    dispatch_queue_t _q;
}

+ (instancetype)shared {
    static EKASyncManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[EKASyncManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.eka2l1.sync", DISPATCH_QUEUE_SERIAL);
        _status = self.iCloudEnabled ? EKASyncStatusSynced : EKASyncStatusIdle;
    }
    return self;
}

// ---- Persisted flags ------------------------------------------------------

- (NSUserDefaults *)defs { return [NSUserDefaults standardUserDefaults]; }

- (BOOL)iCloudEnabled { return [self.defs boolForKey:kICloudEnabled]; }
- (void)setICloudEnabled:(BOOL)on {
    [self.defs setBool:on forKey:kICloudEnabled];
    if (on) {
        // Game progress is implied by enabling iCloud sync.
        [self.defs setBool:YES forKey:kSyncGameProgress];
        [self setStatus:([self iCloudAvailable] ? EKASyncStatusSynced : EKASyncStatusUnavailable)];
    } else {
        [self setStatus:EKASyncStatusIdle];
    }
}

- (BOOL)syncGameProgress {
    return self.iCloudEnabled ? YES : [self.defs boolForKey:kSyncGameProgress];
}
- (void)setSyncGameProgress:(BOOL)on { [self.defs setBool:on forKey:kSyncGameProgress]; }

- (BOOL)syncDevices { return [self.defs boolForKey:kSyncDevices]; }
- (void)setSyncDevices:(BOOL)on { [self.defs setBool:on forKey:kSyncDevices]; }

- (EKASyncStatus)status { return _status; }
- (void)setStatus:(EKASyncStatus)status {
    _status = status;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStatusChange) self.onStatusChange(); });
}

// ---- iCloud container -----------------------------------------------------

- (NSURL *)iCloudBackupURL {
    NSURL *container = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:nil];
    if (!container) return nil;
    NSURL *docs = [container URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:docs withIntermediateDirectories:YES attributes:nil error:nil];
    return [docs URLByAppendingPathComponent:kBackupName];
}

- (BOOL)iCloudAvailable {
    return [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:nil] != nil;
}

// ---- Local backup ---------------------------------------------------------

- (unsigned long long)currentBackupSize {
    return [self backupSizeForDevices:self.syncDevices];
}

- (unsigned long long)backupSizeForDevices:(BOOL)devices {
    return eka2l1::ios::bridge::backup_size(devices);
}

- (NSString *)tempZipPath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kBackupName];
}

- (void)exportBackup:(void (^)(NSURL * _Nullable))done {
    BOOL devices = self.syncDevices;
    NSString *tmp = [self tempZipPath];
    dispatch_async(_q, ^{
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        bool ok = eka2l1::ios::bridge::export_backup(std::string(tmp.UTF8String), devices);
        dispatch_async(dispatch_get_main_queue(), ^{
            done(ok ? [NSURL fileURLWithPath:tmp] : nil);
        });
    });
}

- (void)importBackupFromURL:(NSURL *)url done:(void (^)(BOOL))done {
    dispatch_async(_q, ^{
        // Security-scoped access for files picked outside the app sandbox.
        BOOL scoped = [url startAccessingSecurityScopedResource];
        // Copy to a temp path first (the picked URL may be a transient promise).
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eka2l1_import.zip"];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:nil];
        if (scoped) [url stopAccessingSecurityScopedResource];
        bool ok = eka2l1::ios::bridge::import_backup(std::string(tmp.UTF8String));
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}

// ---- iCloud flows ---------------------------------------------------------

- (void)saveUpOnGameClose {
    if (!self.iCloudEnabled) return;
    BOOL devices = self.syncDevices;
    NSString *tmp = [self tempZipPath];
    [self setStatus:EKASyncStatusSyncing];
    dispatch_async(_q, ^{
        NSURL *dest = [self iCloudBackupURL];
        if (!dest) { [self setStatus:EKASyncStatusUnavailable]; return; }
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        if (!eka2l1::ios::bridge::export_backup(std::string(tmp.UTF8String), devices)) {
            [self setStatus:EKASyncStatusError];
            return;
        }
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
        BOOL ok = [[NSFileManager defaultManager] setUbiquitous:YES
                                                      itemAtURL:[NSURL fileURLWithPath:tmp]
                                                 destinationURL:dest error:&err];
        [self setStatus:ok ? EKASyncStatusSynced : EKASyncStatusError];
    });
}

- (void)syncNow:(void (^)(BOOL))done {
    if (!self.iCloudEnabled) { if (done) done(NO); return; }
    [self saveUpOnGameClose];
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done([self iCloudAvailable]); });
}

- (void)syncDownOnLaunch {
    if (!self.iCloudEnabled) return;
    [self setStatus:EKASyncStatusSyncing];
    dispatch_async(_q, ^{
        NSURL *src = [self iCloudBackupURL];
        if (!src) { [self setStatus:EKASyncStatusUnavailable]; return; }
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:src.path]) {
            // Not yet materialised locally — ask iCloud to download it, then bail (next launch picks it up).
            [fm startDownloadingUbiquitousItemAtURL:src error:nil];
            [self setStatus:EKASyncStatusSynced];
            return;
        }
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eka2l1_cloud.zip"];
        [fm removeItemAtPath:tmp error:nil];
        if ([fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:tmp] error:nil]) {
            eka2l1::ios::bridge::import_backup(std::string(tmp.UTF8String));
            [fm removeItemAtPath:tmp error:nil];
        }
        [self setStatus:EKASyncStatusSynced];
    });
}

- (void)deleteICloudBackup:(void (^)(BOOL))done {
    dispatch_async(_q, ^{
        NSURL *url = [self iCloudBackupURL];
        BOOL ok = url ? [[NSFileManager defaultManager] removeItemAtURL:url error:nil] : NO;
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok); });
    });
}

@end
