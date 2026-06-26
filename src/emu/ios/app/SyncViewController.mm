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
#import "SyncViewController.h"
#import "SyncManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, EKASyncSection) {
    EKASyncSectionICloud = 0,   // Enable iCloud sync
    EKASyncSectionScope,        // Game progress / devices
    EKASyncSectionBackup,       // size / download / import / delete
    EKASyncSectionCount
};

@interface SyncViewController () <UIDocumentPickerDelegate>
@end

@implementation SyncViewController {
    EKASyncManager *_sync;
    NSNumber *_cachedBackupSize;    // nil → not computed yet (cell shows "Calculating…")
    BOOL _cachedScopeDevices;       // scope (syncDevices) the cached size was computed for
    BOOL _computingBackupSize;      // a background size walk is in flight
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _sync = [EKASyncManager shared];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Progress Sync";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(onDone)];
    __weak SyncViewController *weakSelf = self;
    _sync.onStatusChange = ^{ [weakSelf.tableView reloadData]; };
}

- (void)onDone { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSString *)humanSize:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

// Computing the backup size walks the entire data tree (with devices included that means the
// ROMs / Z drive — tens of thousands of files), so it must run off the main thread or it freezes
// the UI. The result is cached per scope; the cell shows "Calculating…" until it lands.
- (void)refreshBackupSize {
    BOOL devices = _sync.syncDevices;
    if (_computingBackupSize) return;                                   // already in flight
    if (_cachedBackupSize && _cachedScopeDevices == devices) return;    // cache is up to date
    _computingBackupSize = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long sz = [self->_sync backupSizeForDevices:devices];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_computingBackupSize = NO;
            self->_cachedBackupSize = @(sz);
            self->_cachedScopeDevices = devices;
            [self reloadBackupSizeRow];
            // Scope was flipped while we were walking — redo it for the new scope.
            if (self->_sync.syncDevices != devices) [self refreshBackupSize];
        });
    });
}

- (void)reloadBackupSizeRow {
    if (self.tableView.numberOfSections <= EKASyncSectionBackup) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:EKASyncSectionBackup];
    [self.tableView reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationNone];
}

// ---- Table structure ------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return EKASyncSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case EKASyncSectionICloud: return 1;
        case EKASyncSectionScope:  return 2;   // game progress, devices
        case EKASyncSectionBackup: return 4;   // size, download, import, delete
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case EKASyncSectionICloud: return @"iCloud Sync";
        case EKASyncSectionScope:  return @"What to Sync";
        case EKASyncSectionBackup: return @"Backup";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == EKASyncSectionICloud) {
        NSString *base = @"Saves your progress right after a game closes, and downloads the latest "
                          "backup right when EKA2L1 is opened.";
        if (_sync.iCloudEnabled && ![_sync iCloudAvailable]) {
            return [base stringByAppendingString:@"\n\niCloud isn't available — sign in to iCloud and "
                    "build with an iCloud-enabled provisioning profile to activate it."];
        }
        return base;
    }
    if (section == EKASyncSectionBackup) {
        return @"Download and Import work without turning on iCloud sync.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == EKASyncSectionICloud) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Enable iCloud Sync";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = _sync.iCloudEnabled;
        [sw addTarget:self action:@selector(onICloudToggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (indexPath.section == EKASyncSectionScope) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        UISwitch *sw = [[UISwitch alloc] init];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Game progress";
            cell.detailTextLabel.text = @"Requires the same game to be installed on both devices.";
            sw.on = YES;
            // Game progress is the base of every backup — locked on while iCloud sync is enabled.
            sw.enabled = NO;
        } else {
            cell.textLabel.text = @"Installed devices & app data (Experimental)";
            cell.detailTextLabel.text = @"Copies all installed devices and app data.";
            sw.on = _sync.syncDevices;
            [sw addTarget:self action:@selector(onDevicesToggle:) forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = sw;
        return cell;
    }
    // Backup section.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    switch (indexPath.row) {
        case 0:
            cell.textLabel.text = @"Current backup size";
            cell.detailTextLabel.text = _cachedBackupSize
                ? [self humanSize:_cachedBackupSize.unsignedLongLongValue]
                : @"Calculating…";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            [self refreshBackupSize];   // idempotent: no-op if cached/in-flight
            break;
        case 1:
            cell.textLabel.text = @"Download Backup (.zip)";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            break;
        case 2:
            cell.textLabel.text = @"Import Backup (.zip)";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            break;
        default:
            cell.textLabel.text = @"Delete iCloud Backup";
            cell.textLabel.textColor = [UIColor systemRedColor];
            break;
    }
    return cell;
}

// ---- Actions --------------------------------------------------------------

- (void)onICloudToggle:(UISwitch *)sw {
    _sync.iCloudEnabled = sw.on;
    [self.tableView reloadData];
}

- (void)onDevicesToggle:(UISwitch *)sw {
    _sync.syncDevices = sw.on;
    // Backup size depends on scope — drop the stale value (cell falls back to "Calculating…")
    // and let cellForRow kick off the recompute off the main thread.
    _cachedBackupSize = nil;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:EKASyncSectionBackup]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != EKASyncSectionBackup) return;
    if (indexPath.row == 1)      [self downloadBackup];
    else if (indexPath.row == 2) [self importBackup];
    else if (indexPath.row == 3) [self deleteBackup];
}

- (UIAlertController *)spinnerAlert:(NSString *)title {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:@"\n"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    [a.view addSubview:spin];
    [spin startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spin.centerXAnchor constraintEqualToAnchor:a.view.centerXAnchor],
        [spin.bottomAnchor constraintEqualToAnchor:a.view.bottomAnchor constant:-20]
    ]];
    return a;
}

- (void)downloadBackup {
    UIAlertController *spin = [self spinnerAlert:@"Preparing backup…"];
    [self presentViewController:spin animated:YES completion:nil];
    [_sync exportBackup:^(NSURL *zipURL) {
        [spin dismissViewControllerAnimated:YES completion:^{
            if (!zipURL) { [self alert:@"Backup failed" message:@"Could not create the backup."]; return; }
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL]
                                                                              applicationActivities:nil];
            share.popoverPresentationController.sourceView = self.view;
            share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
            [self presentViewController:share animated:YES completion:nil];
        }];
    }];
}

- (void)importBackup {
    UTType *zip = [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeZIP;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[zip]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Import Backup"
        message:@"This overwrites matching files and restarts the emulator. Continue?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            UIAlertController *spin = [self spinnerAlert:@"Importing…"];
            [self presentViewController:spin animated:YES completion:nil];
            [self->_sync importBackupFromURL:url done:^(BOOL ok) {
                [spin dismissViewControllerAnimated:YES completion:^{
                    self->_cachedBackupSize = nil;   // data changed → recompute the size
                    [self.tableView reloadData];
                    if (self.onDataImported) self.onDataImported();
                    [self alert:(ok ? @"Backup imported" : @"Import failed")
                        message:(ok ? @"Your data was restored." : @"Could not read the backup.")];
                }];
            }];
        }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)deleteBackup {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete iCloud Backup"
        message:@"Remove the backup stored in iCloud? Your local data is not affected."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            [self->_sync deleteICloudBackup:^(BOOL ok) {
                [self alert:(ok ? @"Deleted" : @"Nothing to delete")
                    message:(ok ? @"The iCloud backup was removed." : @"No iCloud backup was found.")];
            }];
        }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
