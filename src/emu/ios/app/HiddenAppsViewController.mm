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
#import "HiddenAppsViewController.h"

#include <ios/emu_bridge.h>

#include <cstdint>
#include <vector>

// NSUserDefaults key: a dictionary mapping a device's firmware code (NSString) to an
// array of hidden app UIDs (NSNumber, uint32).
static NSString *const kHiddenAppsDefaultsKey = @"EKAHiddenApps";

// Each icon is rendered in a fixed square box (aspect-fit), matching the apps list.
static const CGFloat kHiddenIconSize = 40.0;

// Cell laying the icon + label out like the apps list / Packages page.
@interface EKAHiddenAppCell : UITableViewCell
@end

@implementation EKAHiddenAppCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat x = 14;
    self.imageView.frame = CGRectMake(x, (h - kHiddenIconSize) / 2.0, kHiddenIconSize, kHiddenIconSize);
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.clipsToBounds = YES;
    CGFloat textX = x + kHiddenIconSize + 14;
    CGFloat textW = w - textX - 12;
    self.textLabel.frame = CGRectMake(textX, h / 2.0 - 20, textW, 22);
    self.detailTextLabel.frame = CGRectMake(textX, h / 2.0 + 2, textW, 18);
}
@end

@interface HiddenAppsViewController ()
// Each entry: @{ @"uid": NSNumber(uint32), @"name": NSString }.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *iconCache;
@end

@implementation HiddenAppsViewController

#pragma mark - Per-device hidden-app store

+ (NSString *)currentDeviceKey {
    std::vector<eka2l1::ios::bridge::device_entry> devices = eka2l1::ios::bridge::get_devices();
    int current = eka2l1::ios::bridge::get_current_device();
    if (current < 0 || current >= (int)devices.size()) {
        return @"";
    }
    return [NSString stringWithUTF8String:devices[current].firmware.c_str()];
}

+ (NSArray<NSNumber *> *)hiddenUidsForDeviceKey:(NSString *)key {
    if (key.length == 0) {
        return @[];
    }
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kHiddenAppsDefaultsKey];
    NSArray *arr = all[key];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

+ (void)setHiddenUids:(NSArray<NSNumber *> *)uids forDeviceKey:(NSString *)key {
    if (key.length == 0) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *all = [([defaults dictionaryForKey:kHiddenAppsDefaultsKey] ?: @{}) mutableCopy];
    if (uids.count == 0) {
        [all removeObjectForKey:key];
    } else {
        all[key] = uids;
    }
    [defaults setObject:all forKey:kHiddenAppsDefaultsKey];
}

+ (NSSet<NSNumber *> *)hiddenUidsForCurrentDevice {
    return [NSSet setWithArray:[self hiddenUidsForDeviceKey:[self currentDeviceKey]]];
}

+ (NSUInteger)hiddenCountForCurrentDevice {
    return [self hiddenUidsForDeviceKey:[self currentDeviceKey]].count;
}

+ (BOOL)isUidHidden:(uint32_t)uid {
    return [[self hiddenUidsForDeviceKey:[self currentDeviceKey]] containsObject:@(uid)];
}

+ (void)setUid:(uint32_t)uid hidden:(BOOL)hidden {
    NSString *key = [self currentDeviceKey];
    NSMutableArray<NSNumber *> *uids = [[self hiddenUidsForDeviceKey:key] mutableCopy];
    if (hidden) {
        if (![uids containsObject:@(uid)]) {
            [uids addObject:@(uid)];
        }
    } else {
        [uids removeObject:@(uid)];
    }
    [self setHiddenUids:uids forDeviceKey:key];
}

#pragma mark - Lifecycle

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden Apps";
    self.apps = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(onDone)];

    self.tableView.rowHeight = 64;
    [self.tableView registerClass:[EKAHiddenAppCell class] forCellReuseIdentifier:@"hidden"];

    // Hold a row to bring up Unhide (mirrors the homescreen long-press menu).
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.tableView addGestureRecognizer:lp];

    [self reloadApps];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadApps {
    [self.apps removeAllObjects];
    NSSet<NSNumber *> *hidden = [HiddenAppsViewController hiddenUidsForCurrentDevice];
    // The core still lists every app; show only the ones the user hid (intersect with the
    // live list so a hidden app that was later uninstalled simply drops off here).
    std::vector<eka2l1::ios::bridge::app_entry> apps = eka2l1::ios::bridge::get_apps();
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (const auto &a : apps) {
        NSNumber *uidNum = @(a.uid);
        // De-duplicate UID-duplicate registrations, matching the home screen.
        if ([seen containsObject:uidNum]) {
            continue;
        }
        [seen addObject:uidNum];
        if (![hidden containsObject:uidNum]) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:a.name.c_str()];
        if (name.length == 0) {
            name = @"(Unnamed app)";
        }
        [self.apps addObject:@{ @"uid": uidNum, @"name": name }];
    }
    [self updateEmptyState];
    [self.tableView reloadData];
    [self loadIcons];
}

- (void)updateEmptyState {
    if (self.apps.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No hidden apps.\n\nHold an app on the home screen, then “Hide App”, to hide it.";
        empty.textColor = [UIColor secondaryLabelColor];
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        self.tableView.backgroundView = empty;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (void)loadIcons {
    NSArray<NSDictionary *> *snapshot = [self.apps copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSUInteger row = 0; row < snapshot.count; row++) {
            NSNumber *uidNum = snapshot[row][@"uid"];
            if (self.iconCache[uidNum]) continue;
            eka2l1::ios::bridge::icon_image icon =
                eka2l1::ios::bridge::get_app_icon((std::uint32_t)uidNum.unsignedLongValue);
            UIImage *img = [self imageFromRGBA:icon.rgba.data() width:icon.width height:icon.height];
            if (!img) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.iconCache[uidNum] = img;
                if (row < self.apps.count && [self.apps[row][@"uid"] isEqual:uidNum]) {
                    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
                    [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                }
            });
        }
    });
}

- (UIImage *)imageFromRGBA:(const std::uint8_t *)data width:(int)w height:(int)h {
    if (!data || w <= 0 || h <= 0) return nil;
    const size_t bytes = (size_t)w * h * 4;
    CFDataRef cfdata = CFDataCreate(NULL, data, bytes);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfdata);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(w, h, 8, 32, w * 4, cs,
        kCGImageAlphaLast | kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CFRelease(cfdata);
    return img;
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EKAHiddenAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"hidden"];
    NSDictionary *app = self.apps[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.detailTextLabel.text = @"Tap to unhide";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = self.iconCache[app[@"uid"]] ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self confirmUnhideAtRow:indexPath.row];
}

// Standard swipe-to-unhide, in addition to tapping / the long-press menu.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak HiddenAppsViewController *weakSelf = self;
    UIContextualAction *unhide = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Unhide" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [weakSelf unhideAtRow:indexPath.row];
            completion(YES);
        }];
    unhide.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[unhide]];
}

#pragma mark - Unhide

- (void)onLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:pt];
    if (!ip || ip.row >= (NSInteger)self.apps.count) return;

    NSDictionary *app = self.apps[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app[@"name"] message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Unhide" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self unhideAtRow:ip.row]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    sheet.popoverPresentationController.sourceView = cell ?: self.tableView;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(pt.x, pt.y, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmUnhideAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.apps.count) return;
    NSDictionary *app = self.apps[row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unhide App"
        message:[NSString stringWithFormat:@"Show “%@” on the home screen again?", app[@"name"]]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unhide" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self unhideAtRow:row]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)unhideAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.apps.count) return;
    uint32_t uid = (uint32_t)[self.apps[row][@"uid"] unsignedIntValue];
    [HiddenAppsViewController setUid:uid hidden:NO];
    [self reloadApps];
    if (self.onChanged) self.onChanged();
}

@end
