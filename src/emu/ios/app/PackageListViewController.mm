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
#import "PackageListViewController.h"

#include <ios/emu_bridge.h>

#include <cstdint>
#include <vector>

// Each package icon is rendered in a fixed square box (aspect-fit), matching the apps list.
static const CGFloat kPkgIconSize = 40.0;

// Cell laying the icon + label out exactly like the apps list (EKAAppCell), so the
// Packages page looks at home next to it.
@interface EKAPackageCell : UITableViewCell
@end

@implementation EKAPackageCell
// dequeueReusableCellWithIdentifier (from registerClass:) builds cells with the Default
// style, which has no detailTextLabel — force the Subtitle style so the UID line shows.
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat x = 14;
    self.imageView.frame = CGRectMake(x, (h - kPkgIconSize) / 2.0, kPkgIconSize, kPkgIconSize);
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.clipsToBounds = YES;
    CGFloat textX = x + kPkgIconSize + 14;
    CGFloat textW = w - textX - 12;
    self.textLabel.frame = CGRectMake(textX, h / 2.0 - 20, textW, 22);
    self.detailTextLabel.frame = CGRectMake(textX, h / 2.0 + 2, textW, 18);
}
@end

@interface PackageListViewController ()
// Each entry: @{ @"uid": NSNumber(uint32), @"index": NSNumber(int32), @"name": NSString }.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *packages;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *iconCache;
@property (nonatomic, assign) BOOL didChange;
@end

@implementation PackageListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Packages";
    self.packages = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(onDone)];

    self.tableView.rowHeight = 64;
    [self.tableView registerClass:[EKAPackageCell class] forCellReuseIdentifier:@"pkg"];

    // Hold a row to bring up Delete (mirrors the Android frontend's long-press menu).
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.tableView addGestureRecognizer:lp];

    [self reloadPackages];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadPackages {
    [self.packages removeAllObjects];
    std::vector<eka2l1::ios::bridge::package_entry> pkgs = eka2l1::ios::bridge::get_packages();
    for (const auto &p : pkgs) {
        NSString *name = [NSString stringWithUTF8String:p.name.c_str()];
        if (name.length == 0) {
            name = @"(Unnamed package)";
        }
        [self.packages addObject:@{
            @"uid": @(p.uid),
            @"index": @(p.index),
            @"name": name
        }];
    }
    [self updateEmptyState];
    [self.tableView reloadData];
    [self loadIcons];
}

- (void)updateEmptyState {
    if (self.packages.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No installed packages.\n\nApps you install (.sis/.sisx) appear here.";
        empty.textColor = [UIColor secondaryLabelColor];
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        self.tableView.backgroundView = empty;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (void)loadIcons {
    NSArray<NSDictionary *> *snapshot = [self.packages copy];
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
                // Reload just this row if it still maps to the same package (the list may
                // have changed underneath us after a delete + reboot).
                if (row < self.packages.count && [self.packages[row][@"uid"] isEqual:uidNum]) {
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
    return self.packages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EKAPackageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pkg"];
    NSDictionary *pkg = self.packages[indexPath.row];
    cell.textLabel.text = pkg[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"UID: 0x%08X",
                                 [pkg[@"uid"] unsignedIntValue]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = self.iconCache[pkg[@"uid"]] ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

// Standard swipe-to-delete, in addition to the long-press menu.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak PackageListViewController *weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Delete" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [weakSelf confirmDeleteAtRow:indexPath.row];
            completion(NO);   // we run our own confirm + reload
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

#pragma mark - Delete

- (void)onLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:pt];
    if (!ip || ip.row >= (NSInteger)self.packages.count) return;

    NSDictionary *pkg = self.packages[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:pkg[@"name"] message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self confirmDeleteAtRow:ip.row]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // Anchor the popover (iPad) on the pressed row.
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    sheet.popoverPresentationController.sourceView = cell ?: self.tableView;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(pt.x, pt.y, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeleteAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.packages.count) return;
    NSDictionary *pkg = self.packages[row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Package"
        message:[NSString stringWithFormat:@"Delete “%@”? Its installed files and save data are removed. This cannot be undone.", pkg[@"name"]]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self performDeleteOfPackage:pkg]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDeleteOfPackage:(NSDictionary *)pkg {
    std::uint32_t uid = (std::uint32_t)[pkg[@"uid"] unsignedIntValue];
    std::int32_t index = (std::int32_t)[pkg[@"index"] intValue];

    UIAlertController *spin = [self spinnerAlert:@"Deleting…"];
    [self presentViewController:spin animated:YES completion:nil];

    // uninstall_package reboots the guest in place, so run it off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        eka2l1::ios::bridge::uninstall_package(uid, index);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didChange = YES;
            [spin dismissViewControllerAnimated:YES completion:^{
                [self reloadPackages];
                if (self.onChanged) self.onChanged();
            }];
        });
    });
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

@end
