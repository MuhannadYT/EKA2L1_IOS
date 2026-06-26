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
#import "RootViewController.h"
#import "EmulatorView.h"
#import "GameControlsView.h"
#import "GameSettingsViewController.h"
#import "GameSettingsStore.h"
#import "InputManager.h"
#import "GameMenuView.h"
#import "KeybindEditorViewController.h"
#import "LayoutEditorViewController.h"
#import "PackageListViewController.h"
#import "HiddenAppsViewController.h"
#import "SyncManager.h"
#import "SyncViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <ios/emu_bridge.h>

#include <string>
#include <vector>

typedef NS_ENUM(NSInteger, PickMode) {
    PickModeDeviceRom,
    PickModeDeviceRpkg,
    PickModeVplFirmware,
    PickModeGame,
    PickModeNGage,
    PickModeNGageFile
};

// Cell that renders every app icon in a fixed square box (aspect-fit, so larger ROM
// icons scale down and all rows align), with the label at a fixed inset.
static const CGFloat kAppIconSize = 40.0;

static BOOL EKAIsNGagePackagePath(NSString *path) {
    NSString *name = path.lastPathComponent.lowercaseString;
    return [name hasSuffix:@".n-gage"] || [name hasSuffix:@".ngage"];
}

static BOOL EKAIsSisPackagePath(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"sis"] || [ext isEqualToString:@"sisx"];
}

@interface EKAAppCell : UITableViewCell
@end

@implementation EKAAppCell
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat x = 14;
    self.imageView.frame = CGRectMake(x, (h - kAppIconSize) / 2.0, kAppIconSize, kAppIconSize);
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.clipsToBounds = YES;
    CGFloat textX = x + kAppIconSize + 14;
    self.textLabel.frame = CGRectMake(textX, 0, w - textX - 12, h);
}
@end

@interface RootViewController () <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate, GameSettingsViewControllerDelegate, InputManagerDelegate>
@property (nonatomic, strong) EmulatorView *emuView;
@property (nonatomic, strong) InputManager *inputManager;
@property (nonatomic, strong) GameMenuView *activeMenu;
@property (nonatomic, strong) GameControlsView *controlsView;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIButton *deviceButton;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UITableView *appsTable;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign) float progressValue;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL gameRunning;
@property (nonatomic, assign) uint32_t currentGameUid;      // uid of the running game (per-game settings)
@property (nonatomic, assign) BOOL currentGameHideIsland;   // running game's "hide dynamic island" pref
@property (nonatomic, assign) BOOL currentGameShowStatus;   // running game's "status" (fps/speed) overlay pref
@property (nonatomic, assign) BOOL currentGameAutoScaleP;   // running game's auto-scale (portrait)
@property (nonatomic, assign) BOOL currentGameAutoScaleL;   // running game's auto-scale (landscape)
@property (nonatomic, assign) NSInteger currentGameRefreshRate; // running game's target fps (for speed %)
@property (nonatomic, strong) UILabel *statusOverlay;       // FPS + emulator-speed overlay (top, 50% opacity)
@property (nonatomic, strong) NSTimer *pollTimer;           // drives auto-scale + status while a game runs
@property (nonatomic, assign) NSInteger keyLayout;          // 0=None, 1..4
@property (nonatomic, assign) PickMode pickMode;
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, assign) NSInteger selectedAppIndex;   // keyboard/controller cursor row in the apps list
@property (nonatomic, assign) BOOL cursorVisible;           // YES once a nav key is pressed; touch hides it again
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *iconCache;
@property (nonatomic, strong) NSString *pendingRomPath;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingImportedFiles;
- (void)pollUntilAppsThen:(void (^)(BOOL found))done attemptsLeft:(int)attempts;
- (void)drainPendingImportedFiles;
- (void)installImportedContentAtPath:(NSString *)path;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.keyLayout = 0;
    self.iconCache = [NSMutableDictionary dictionary];
    self.pendingImportedFiles = [NSMutableArray array];

    // Hardware keyboard + game-controller input (works even when the on-screen layout is None).
    self.inputManager = [[InputManager alloc] init];
    self.inputManager.delegate = self;
    [self.inputManager startObserving];

    // Debug/automation: `--keylayout N` preselects an on-screen control layout.
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    NSUInteger kli = [args indexOfObject:@"--keylayout"];
    if (kli != NSNotFound && kli + 1 < args.count) {
        self.keyLayout = [args[kli + 1] integerValue];
    }

    self.emuView = [[EmulatorView alloc] initWithFrame:self.view.bounds];
    // Frame is managed in viewDidLayoutSubviews so it can be inset out of the Dynamic
    // Island / safe area for the running game (see "Hide Dynamic Island").
    self.emuView.autoresizingMask = UIViewAutoresizingNone;
    [self.view addSubview:self.emuView];

    // On-screen key controls, above the GL view (passes non-key touches through).
    self.controlsView = [[GameControlsView alloc] initWithFrame:self.view.bounds];
    self.controlsView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controlsView.hidden = YES;
    [self.view addSubview:self.controlsView];

    // FPS + emulator-speed overlay, pinned to the top at 50% opacity (per-game "Status" option).
    self.statusOverlay = [[UILabel alloc] init];
    self.statusOverlay.textColor = [UIColor whiteColor];
    self.statusOverlay.textAlignment = NSTextAlignmentCenter;
    self.statusOverlay.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    self.statusOverlay.layer.cornerRadius = 6;
    self.statusOverlay.clipsToBounds = YES;
    self.statusOverlay.alpha = 0.5;          // overlay is 50% opacity
    self.statusOverlay.hidden = YES;
    [self.view addSubview:self.statusOverlay];

    self.appsTable = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.appsTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.appsTable.dataSource = self;
    self.appsTable.delegate = self;
    self.appsTable.rowHeight = 56;
    self.appsTable.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.appsTable.hidden = YES;
    [self.view addSubview:self.appsTable];

    // Long-press a game row → per-game actions (Launch / Game Settings).
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onAppsLongPress:)];
    [self.appsTable addGestureRecognizer:longPress];

    [self setupToolbar];

    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *icon = [UIImage systemImageNamed:@"ellipsis.circle.fill"];
    if (icon) {
        [self.menuButton setImage:icon forState:UIControlStateNormal];
    } else {
        [self.menuButton setTitle:@"☰" forState:UIControlStateNormal];
    }
    self.menuButton.tintColor = [UIColor whiteColor];
    self.menuButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.menuButton.layer.cornerRadius = 20;
    [self.menuButton addTarget:self action:@selector(onMenuTouch) forControlEvents:UIControlEventTouchUpInside];
    self.menuButton.hidden = YES;
    [self.view addSubview:self.menuButton];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:16];
    self.statusLabel.text = @"Starting EKA2L1…";
    [self.view addSubview:self.statusLabel];

    // Progress bar + percentage, shown during install / switch / delete-reboot.
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = [UIColor systemBlueColor];
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];

    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.textColor = [UIColor whiteColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.progressLabel.hidden = YES;
    [self.view addSubview:self.progressLabel];
}

- (void)setupToolbar {
    self.toolbar = [[UIView alloc] init];
    self.toolbar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    // Order matters: viewDidLayoutSubviews lays the buttons out left-to-right.
    NSArray<NSString *> *titles = @[@"Install Device", @"Install Game", @"Settings", @"Apps"];
    NSArray<NSString *> *selectors = @[@"onDeviceButton", @"onInstallGame", @"onSettings", @"onShowApps"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [btn addTarget:self action:NSSelectorFromString(selectors[i]) forControlEvents:UIControlEventTouchUpInside];
        [self.toolbar addSubview:btn];
    }
    self.deviceButton = (UIButton *)self.toolbar.subviews.firstObject;
    [self.view addSubview:self.toolbar];
}

// Once at least one device is installed the first toolbar button becomes "Devices"
// (a manager: switch / rename / add another). Before that it installs the first device.
- (void)refreshDeviceButton {
    BOOL hasDevice = eka2l1::ios::bridge::has_device();
    [self.deviceButton setTitle:(hasDevice ? @"Devices" : @"Install Device") forState:UIControlStateNormal];
    [self.view setNeedsLayout];
}

// Heavy bridge ops (install / switch device / N-Gage install) hold the bridge mutex on a
// background thread for many seconds. Block toolbar taps meanwhile so a main-thread call
// into the bridge can't stall behind that lock and trip the iOS watchdog.
- (void)setToolbarBusy:(BOOL)busy {
    self.toolbar.userInteractionEnabled = !busy;
    self.toolbar.alpha = busy ? 0.5 : 1.0;
}

// ---- Progress bar (install / switch / delete) -----------------------------

- (void)beginProgress:(NSString *)title {
    self.appsTable.hidden = YES;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = title;
    self.progressView.hidden = NO;
    self.progressLabel.hidden = NO;
    [self setProgressFraction:0];
    [self setToolbarBusy:YES];
}

- (void)setProgressFraction:(float)f {
    if (f < 0) f = 0;
    if (f > 1) f = 1;
    self.progressValue = f;
    self.progressView.progress = f;
    self.progressLabel.text = [NSString stringWithFormat:@"%d%%", (int)(f * 100 + 0.5f)];
}

// Smoothly ease the bar toward `target` (0..1) for operations with no real progress
// metric (the device reboot/boot), so the user sees it is still working.
- (void)climbProgressToward:(float)target {
    [self.progressTimer invalidate];
    __weak RootViewController *weakSelf = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        RootViewController *s = weakSelf;
        if (!s) { [t invalidate]; return; }
        [s setProgressFraction:s.progressValue + (target - s.progressValue) * 0.05f];
    }];
}

- (void)endProgress {
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    [self setProgressFraction:1.0];
    [self setToolbarBusy:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // GL view: full screen, or inset out of the Dynamic Island / safe area (top + sides,
    // the camera/island region) for the running game when "Hide Dynamic Island" is on. The
    // bottom is left flush (the home indicator is translucent and content there is fine).
    CGRect emuFrame = self.view.bounds;
    if (self.gameRunning && self.currentGameHideIsland) {
        UIEdgeInsets si = self.view.safeAreaInsets;
        emuFrame = CGRectMake(self.view.bounds.origin.x + si.left,
                              self.view.bounds.origin.y + si.top,
                              self.view.bounds.size.width - si.left - si.right,
                              self.view.bounds.size.height - si.top);
    }
    if (!CGRectEqualToRect(self.emuView.frame, emuFrame)) {
        self.emuView.frame = emuFrame;
    }

    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat width = self.view.bounds.size.width;
    CGFloat barH = 44;

    self.toolbar.frame = CGRectMake(0, top, width, barH);
    CGFloat bx = 8;
    for (UIView *sub in self.toolbar.subviews) {
        [(UIButton *)sub sizeToFit];
        CGRect f = sub.frame;
        f.size.width += 12; f.origin.x = bx; f.origin.y = (barH - f.size.height) / 2;
        sub.frame = f; bx += f.size.width + 10;
    }

    // The "…" menu button: top-left in landscape; in portrait it goes to the bottom, clear of
    // the on-screen controls. On iPad the D-pad is left-aligned so the button sits in the empty
    // bottom-CENTRE gap; on iPhone the D-pad stays centred so the button goes bottom-LEFT.
    const CGFloat mb = 40;
    UIEdgeInsets si = self.view.safeAreaInsets;
    BOOL portrait = (self.view.bounds.size.height >= self.view.bounds.size.width);
    if (portrait) {
        BOOL pad = (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad);
        CGFloat my = self.view.bounds.size.height - si.bottom - mb - 10;
        CGFloat mx = pad ? (self.view.bounds.size.width - mb) / 2.0   // bottom-centre
                         : (si.left + 10);                            // bottom-left
        self.menuButton.frame = CGRectMake(mx, my, mb, mb);
    } else {
        self.menuButton.frame = CGRectMake(10, top + 4, mb, mb);
    }

    CGFloat listY = top + barH;
    self.appsTable.frame = CGRectMake(0, listY, width, self.view.bounds.size.height - listY);
    self.statusLabel.frame = CGRectMake(20, listY, width - 40, self.view.bounds.size.height - listY);

    // Progress bar just below the (vertically-centred) status text.
    CGFloat cx = width / 2.0;
    CGFloat cy = listY + (self.view.bounds.size.height - listY) / 2.0;
    CGFloat pvW = MIN(260, width - 80);
    self.progressView.frame = CGRectMake(cx - pvW / 2.0, cy + 24, pvW, 4);
    self.progressLabel.frame = CGRectMake(cx - 60, cy + 32, 120, 22);

    [self updateChrome];
}

// Show/hide chrome based on whether a game is running.
- (void)updateChrome {
    if (self.gameRunning) {
        self.toolbar.hidden = YES;
        self.appsTable.hidden = YES;
        // The "…" menu button stays available while a game runs (both orientations) so the
        // user can always reach Switch Key Layout / Exit Game. The on-screen keypad follows
        // the selected layout in both orientations; it is hidden only when "None" is chosen.
        self.menuButton.hidden = NO;
        [self applyControls];
        // Status (fps/speed) overlay follows the per-game pref; the poll timer also feeds
        // auto-scale, so it runs whenever a game is up.
        [self startPollTimer];
        [self.view bringSubviewToFront:self.controlsView];
        [self.view bringSubviewToFront:self.menuButton];
        // Status (fps/speed) overlay follows the per-game pref; the poll timer also feeds
        // auto-scale, so it runs whenever a game is up. Keep the overlay on top of everything.
        self.statusOverlay.hidden = !self.currentGameShowStatus;
        if (self.currentGameShowStatus) {
            [self layoutStatusOverlay];
            [self.view bringSubviewToFront:self.statusOverlay];
        }
    } else {
        self.toolbar.hidden = NO;
        self.menuButton.hidden = YES;
        self.statusOverlay.hidden = YES;
        [self stopPollTimer];
        self.controlsView.customLayout = nil;
        self.controlsView.layout = 0;
        [self.view bringSubviewToFront:self.appsTable];
        [self.view bringSubviewToFront:self.toolbar];
        [self.view bringSubviewToFront:self.statusLabel];
    }
    // Forward hardware key/controller input to the guest only while a game runs; while the
    // homescreen apps list is up, the same keys drive its selection cursor instead.
    self.inputManager.enabled = self.gameRunning;
    self.inputManager.appsListShown = (!self.gameRunning && !self.appsTable.hidden);

    // Defer the system screen-edge gestures while a game runs (a swipe near an edge needs a second
    // swipe to trigger), so a joystick drag toward the bottom-corner edge isn't intercepted by the
    // system. This does NOT relayout, so it can't disturb a held button. (Home-indicator auto-hide
    // is deliberately NOT toggled here — it caused layout passes during play that dropped held keys.)
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return self.gameRunning ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startEmulatorIfNeeded];
}

- (void)startEmulatorIfNeeded {
    if (self.started) return;
    const int w = [self.emuView drawableWidth];
    const int h = [self.emuView drawableHeight];
    if ((w <= 0) || (h <= 0)) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startEmulatorIfNeeded]; });
        return;
    }
    self.started = YES;

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *bundleRes = [[NSBundle mainBundle] resourcePath];
    eka2l1::ios::bridge::set_data_directory([docs UTF8String], [bundleRes UTF8String]);

    __weak RootViewController *weakSelf = self;
    eka2l1::ios::bridge::set_app_exit_callback([weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf onAppExited]; });
    });

    const bool hasDevice = eka2l1::ios::bridge::start([self.emuView glLayer], w, h);
    [self refreshDeviceButton];
    if (hasDevice && self.pendingImportedFiles.count > 0) {
        [self drainPendingImportedFiles];
        return;
    }
    // Progress Sync: pull the latest iCloud backup shortly after opening (no-op unless iCloud
    // sync is on and a container is available — never on the ad-hoc-signed simulator).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [[EKASyncManager shared] syncDownOnLaunch]; });

    if (hasDevice) {
        self.statusLabel.text = @"Loading apps…";
        self.statusLabel.hidden = NO;
        [self pollForAppsWithAttemptsLeft:20];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self maybeAutoInstallGame];
        });
    } else {
        self.statusLabel.text = @"No Symbian device installed.\n\nTap “Install Device” to add one.";
        [self maybeAutoInstallDevice];
        if (self.pendingImportedFiles.count > 0) {
            [self drainPendingImportedFiles];
        }
    }
}

- (void)pollForAppsWithAttemptsLeft:(int)attempts {
    if (self.gameRunning) return;
    std::vector<eka2l1::ios::bridge::app_entry> apps = eka2l1::ios::bridge::get_apps();
    if (!apps.empty()) {
        NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
        NSUInteger luidIdx = [args indexOfObject:@"--launchuid"];
        if (luidIdx != NSNotFound && luidIdx + 1 < args.count) {
            // Automation hook: launch a specific app by UID3 (hex, e.g. 0x20007B39 = Games).
            std::uint32_t target = (std::uint32_t)strtoul([args[luidIdx + 1] UTF8String], nullptr, 16);
            [self launchAppUid:target];
        } else if ([args containsObject:@"--launchfirst"]) {
            [self launchAppUid:apps[0].uid];
        } else if ([args containsObject:@"--gamesettings"]) {
            // Automation hook (like --launchfirst): open the first app's per-game settings.
            [self showAppsScreen];
            [self openGameSettingsForUid:apps[0].uid
                                    name:[NSString stringWithUTF8String:apps[0].name.c_str()]];
        } else if ([args containsObject:@"--sync"]) {
            [self showAppsScreen];
            [self openProgressSync];
        } else if ([args containsObject:@"--packages"]) {
            [self showAppsScreen];
            [self openPackages];
        } else if ([args containsObject:@"--hiddenapps"]) {
            // Automation hook: open Devices → Hidden Apps.
            [self showAppsScreen];
            [self openHiddenApps];
        } else if ([args containsObject:@"--hidefirstapp"]) {
            // Automation hook: hide the first app, then show the (filtered) home screen.
            [HiddenAppsViewController setUid:apps[0].uid hidden:YES];
            [self showAppsScreen];
        } else if ([args containsObject:@"--keybinds"]) {
            [self showAppsScreen];
            [self openGlobalKeybinds];
        } else if ([args containsObject:@"--layouteditor"]) {
            [self showAppsScreen];
            [self openLayoutEditorForUid:apps[0].uid
                                    name:[NSString stringWithUTF8String:apps[0].name.c_str()]];
        } else {
            [self showAppsScreen];
        }
        return;
    }
    if (attempts <= 0) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Device booted, but no apps were found.\nTap “Apps” to retry or install a game.";
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self pollForAppsWithAttemptsLeft:attempts - 1];
    });
}

// Poll until the (freshly rebooted) guest has registered its apps, keeping the progress
// bar climbing meanwhile. A device reboot returns from the bridge almost immediately (the
// OS thread boots the guest asynchronously), so the bar must finish on *apps loaded*, not
// when the bridge call returns. `done(found)` runs once, on the main thread.
- (void)pollUntilAppsThen:(void (^)(BOOL found))done attemptsLeft:(int)attempts {
    if (!eka2l1::ios::bridge::get_apps().empty()) {
        done(YES);
        return;
    }
    if (attempts <= 0) {
        done(NO);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self pollUntilAppsThen:done attemptsLeft:attempts - 1];
    });
}

// ---- Apps screen + icons --------------------------------------------------

- (void)showAppsScreen {
    self.gameRunning = NO;
    std::vector<eka2l1::ios::bridge::app_entry> apps = eka2l1::ios::bridge::get_apps();
    // Apps the user hid for this device are filtered out here (purely a front-end filter;
    // they are unhidden from Devices → Hidden Apps).
    NSSet<NSNumber *> *hidden = [HiddenAppsViewController hiddenUidsForCurrentDevice];
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (auto &a : apps) {
        NSNumber *uidNum = @(a.uid);
        // Some ROMs register the same app under one UID more than once (e.g. Jelly Chase on
        // the 5320). Both rows launch/show the identical app, so collapse them to one row —
        // this also makes hiding (keyed by UID) affect a single entry.
        if ([seen containsObject:uidNum]) {
            continue;
        }
        [seen addObject:uidNum];
        if ([hidden containsObject:uidNum]) {
            continue;
        }
        [list addObject:@{ @"uid": uidNum, @"name": [NSString stringWithUTF8String:a.name.c_str()] }];
    }
    self.apps = list;
    [self.appsTable reloadData];
    [self refreshDeviceButton];

    self.appsTable.hidden = (list.count == 0);
    self.statusLabel.hidden = (list.count != 0);
    if (list.count == 0) {
        self.statusLabel.text = (hidden.count > 0)
            ? @"All apps are hidden.\nTap “Devices” → “Hidden Apps” to unhide one."
            : @"No apps found yet.\nTap “Apps” to refresh, or install a game.";
    }
    [self updateChrome];
    [self loadIconsForApps:list];

    // The keyboard/controller cursor starts hidden — it only appears once a nav key/dpad is
    // pressed (and hides again on touch). Become first responder so hardware-keyboard presses
    // reach us via the responder chain (controllers work regardless).
    self.cursorVisible = NO;
    self.selectedAppIndex = 0;
    if (list.count > 0) {
        [self becomeFirstResponder];
    }
}

// The keyboard/controller selection cursor is drawn manually in cellForRowAtIndexPath (gated on
// cursorVisible) rather than via the table's tap-selection, so touch never shows it. Repaint a
// single row in place (cheap, no reloadData) to match the current cursor state.
- (UIColor *)appRowColor    { return [UIColor colorWithWhite:0.08 alpha:1.0]; }
- (UIColor *)appCursorColor { return [UIColor colorWithRed:0.16 green:0.36 blue:0.66 alpha:1.0]; }

- (void)refreshCursorRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.apps.count) {
        return;
    }
    UITableViewCell *cell = [self.appsTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    // Offscreen cells are coloured by cellForRowAtIndexPath when they scroll in.
    cell.backgroundColor = (self.cursorVisible && row == self.selectedAppIndex) ? [self appCursorColor]
                                                                                : [self appRowColor];
}

// Hide the cursor (called on any touch interaction with the list — scroll / tap / long-press).
- (void)hideAppsCursor {
    if (!self.cursorVisible) {
        return;
    }
    self.cursorVisible = NO;
    [self refreshCursorRow:self.selectedAppIndex];
}

// Controller / keyboard navigation of the homescreen apps list (dir -1 = up, +1 = down,
// 0 = launch the cursor app). The first press just reveals the cursor (on the topmost visible
// row); subsequent presses move it, clamped at the ends (no wrap-around).
- (void)navigateAppsList:(NSInteger)dir {
    if (self.apps.count == 0) {
        return;
    }
    if (!self.cursorVisible) {
        NSArray<NSIndexPath *> *visible = [self.appsTable indexPathsForVisibleRows];
        self.selectedAppIndex = visible.count ? visible.firstObject.row : 0;
        self.cursorVisible = YES;
        [self refreshCursorRow:self.selectedAppIndex];
        [self.appsTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.selectedAppIndex inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone animated:YES];
        return;
    }
    if (dir == 0) {
        NSInteger i = self.selectedAppIndex;
        if (i < 0 || i >= (NSInteger)self.apps.count) {
            return;
        }
        std::uint32_t uid = (std::uint32_t)[self.apps[i][@"uid"] unsignedLongValue];
        [self launchAppUid:uid];
        return;
    }
    NSInteger old = self.selectedAppIndex;
    self.selectedAppIndex = MAX(0, MIN((NSInteger)self.apps.count - 1, old + dir));
    if (self.selectedAppIndex != old) {
        [self refreshCursorRow:old];
        [self refreshCursorRow:self.selectedAppIndex];
        [self.appsTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.selectedAppIndex inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone animated:YES];
    }
}

- (void)loadIconsForApps:(NSArray<NSDictionary *> *)list {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSUInteger row = 0; row < list.count; row++) {
            NSDictionary *entry = list[row];
            NSNumber *uidNum = entry[@"uid"];
            if (self.iconCache[uidNum]) continue;
            eka2l1::ios::bridge::icon_image icon = eka2l1::ios::bridge::get_app_icon((std::uint32_t)uidNum.unsignedLongValue);
            UIImage *img = [self imageFromRGBA:icon.rgba.data() width:icon.width height:icon.height];
            if (img) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.iconCache[uidNum] = img;
                    // Reload just this row (not the whole table) so the scroll position is
                    // preserved as icons stream in (cellForRowAtIndexPath repaints the cursor).
                    if (list == self.apps && row < self.apps.count) {
                        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
                        [self.appsTable reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                    } else {
                        [self.appsTable reloadData];
                    }
                });
            }
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

- (void)onShowApps { [self showAppsScreen]; }

- (void)onAppExited {
    // The guest app ended on its own — either a clean quit or, commonly, a KERN-EXEC panic on
    // exit (the kernel kills the faulting process). Android's equivalent callback nukes the whole
    // process (Process.killProcess) so the activity relaunches from scratch; just flipping back to
    // the apps list over the SAME, still-running emulator instance leaves the dead app's guest
    // state behind (a half-torn-down window-server session / app-server registration), so it looks
    // "still running" and the next launch closes instantly. Reboot the instance in place — exactly
    // what the working "Exit Game" button does — for a guaranteed-clean slate.
    if (!self.gameRunning) {
        return;   // already being torn down (e.g. the user tapped Exit Game, which reboots itself)
    }
    NSLog(@"EKA2L1: guest app exited — rebooting the emulator instance for a clean relaunch");
    // Progress Sync: push a backup right after a game closes (no-op unless iCloud sync is on).
    [[EKASyncManager shared] saveUpOnGameClose];
    [self exitGame];
}

// ---- Launch / exit --------------------------------------------------------

- (void)launchAppUid:(std::uint32_t)uid {
    self.currentGameUid = uid;

    // Apply this game's saved settings before/at launch.
    EKAGameSettings *s = [GameSettingsStore settingsForUid:uid];
    eka2l1::ios::bridge::set_app_refresh_rate(uid, (int)s.refreshRate);  // read by the guest on launch
    eka2l1::ios::bridge::set_app_filter_shader(uid, (s.filterShader ?: @"").UTF8String);  // upscale shader (off by default)
    eka2l1::ios::bridge::set_gyro_passthrough(s.gyroPassthrough);  // feed device tilt to the guest accelerometer
    eka2l1::ios::bridge::set_haptic_passthrough(s.hapticPassthrough);  // pass guest vibration to the Taptic Engine
    self.keyLayout = s.keyLayout;
    self.controlsView.overlayOpacity = s.controlsOpacity;
    self.controlsView.guestRect = CGRectZero;        // unknown until the guest draws → full size
    self.currentGameHideIsland = s.hideDynamicIsland;
    self.currentGameShowStatus = s.showStatus;
    self.currentGameAutoScaleP = s.autoScalePortrait;
    self.currentGameAutoScaleL = s.autoScaleLandscape;
    self.currentGameRefreshRate = s.refreshRate;
    [self.emuView setRenderScale:s.renderScale];    // per-game render resolution (0 = Native default)
    [self.inputManager reloadBindingsForUid:uid];   // per-game keybind overrides (Phase 3)

    self.gameRunning = YES;
    self.statusLabel.hidden = YES;
    self.appsTable.hidden = YES;
    [self updateChrome];
    [self.view setNeedsLayout];   // inset the GL view if "Hide Dynamic Island" is on
    [self becomeFirstResponder];  // start receiving hardware-keyboard presses
    eka2l1::ios::bridge::launch_app(uid);
    [self applyScreenGravityForSize:self.view.bounds.size];

    // Automation hooks (like --launchfirst): pop a menu so it can be inspected.
    NSArray<NSString *> *launchArgs = [[NSProcessInfo processInfo] arguments];
    if ([launchArgs containsObject:@"--showmenu"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self onMenuController]; });
    }
    if ([launchArgs containsObject:@"--showmenutouch"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self onMenuTouch]; });
    }
}

// Apply the running game's on-screen controls: a per-game custom layout for the current
// orientation if one exists, otherwise the built-in keyLayout. Custom layout overrides.
- (void)applyControls {
    if (!self.gameRunning) {
        self.controlsView.customLayout = nil;
        self.controlsView.layout = 0;
        return;
    }
    EKAGameSettings *s = [GameSettingsStore settingsForUid:self.currentGameUid];
    BOOL portrait = self.view.bounds.size.height >= self.view.bounds.size.width;
    NSArray<NSDictionary *> *custom = portrait ? s.customLayoutPortrait : s.customLayoutLandscape;
    self.controlsView.overlayOpacity = s.controlsOpacity;
    self.controlsView.hapticsEnabled = s.hapticFeedback;
    self.controlsView.autoScaleButtons = [self autoScaleForCurrentOrientation];
    self.controlsView.customLayout = (custom.count ? custom : nil);
    self.controlsView.layout = self.keyLayout;
}

// ---- Auto-scale buttons (per-game, per-orientation) + status overlay -------

// Whether auto-scale is on for the current orientation of the running game.
- (BOOL)autoScaleForCurrentOrientation {
    BOOL portrait = self.view.bounds.size.height >= self.view.bounds.size.width;
    return portrait ? self.currentGameAutoScaleP : self.currentGameAutoScaleL;
}

// One timer drives both adaptive features while a game runs: it keeps the controls' notion of
// how much of the screen the guest fills up to date (auto-scale), and refreshes the fps/speed
// overlay. Cheap try-lock bridge reads — safe to call on the main thread.
- (void)startPollTimer {
    if (self.pollTimer) return;
    __weak RootViewController *weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        [weakSelf onPollTick];
    }];
}

- (void)stopPollTimer {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)onPollTick {
    if (!self.gameRunning) {
        [self stopPollTimer];
        return;
    }
    if (self.controlsView.autoScaleButtons) {
        float fx = 0, fy = 0, fw = 0, fh = 0;
        eka2l1::ios::bridge::get_guest_screen_rect(&fx, &fy, &fw, &fh);
        if (fw > 0 && fh > 0) {
            // Convert the guest rect (fractions of the GL surface) into the controls view's
            // own coordinates via the emuView frame (which may be inset for the Dynamic Island).
            CGRect ev = self.emuView.frame;
            self.controlsView.guestRect = CGRectMake(ev.origin.x + fx * ev.size.width,
                                                     ev.origin.y + fy * ev.size.height,
                                                     fw * ev.size.width, fh * ev.size.height);
        }
    }
    if (self.currentGameShowStatus) {
        float fps = 0;
        if (eka2l1::ios::bridge::get_status(&fps)) {
            NSInteger target = MAX((NSInteger)1, self.currentGameRefreshRate);
            int speed = (int)(fps / (float)target * 100.0f + 0.5f);
            self.statusOverlay.text = [NSString stringWithFormat:@"  %.0f FPS · %d%%  ", fps, speed];
            [self.statusOverlay sizeToFit];
            [self layoutStatusOverlay];
        }
    }
}

- (void)layoutStatusOverlay {
    CGFloat top = self.view.safeAreaInsets.top;
    [self.statusOverlay sizeToFit];
    CGRect f = self.statusOverlay.frame;
    f.size.height = MAX(f.size.height, 20);
    f.origin.x = (self.view.bounds.size.width - f.size.width) / 2.0;
    f.origin.y = top + 4;
    self.statusOverlay.frame = f;
}

// Apply the running game's screen gravity for the given (portrait/landscape) size.
- (void)applyScreenGravityForSize:(CGSize)size {
    if (!self.gameRunning) {
        return;
    }
    EKAGameSettings *s = [GameSettingsStore settingsForUid:self.currentGameUid];
    BOOL portrait = size.height >= size.width;
    NSInteger gravity = portrait ? s.gravityPortrait : s.gravityLandscape;
    eka2l1::ios::bridge::set_screen_gravity((int)gravity);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // Re-apply gravity + the orientation's custom layout after the rotation settles.
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        [self applyScreenGravityForSize:size];
        [self applyControls];
    }];
}

// ---- Per-game settings (long-press a game) --------------------------------

- (void)onAppsLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) {
        return;
    }
    [self hideAppsCursor];   // touch interaction
    CGPoint p = [gr locationInView:self.appsTable];
    NSIndexPath *ip = [self.appsTable indexPathForRowAtPoint:p];
    if (!ip || ip.row >= (NSInteger)self.apps.count) {
        return;
    }
    NSDictionary *app = self.apps[ip.row];
    uint32_t uid = (uint32_t)[app[@"uid"] unsignedLongValue];
    NSString *name = app[@"name"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Launch" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self launchAppUid:uid]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Game Settings" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self openGameSettingsForUid:uid name:name]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hide App" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self confirmHideAppUid:uid name:name]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.appsTable;
    sheet.popoverPresentationController.sourceRect = [self.appsTable rectForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmHideAppUid:(uint32_t)uid name:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hide App"
        message:[NSString stringWithFormat:@"Are you sure you want to hide “%@”? You can unhide it by tapping “Devices”, then “Hidden Apps”.", name]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hide" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            [HiddenAppsViewController setUid:uid hidden:YES];
            [self showAppsScreen];   // re-filter the list so the app disappears
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGameSettingsForUid:(uint32_t)uid name:(NSString *)name {
    GameSettingsViewController *vc = [[GameSettingsViewController alloc] initWithUid:uid name:name];
    vc.settingsDelegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openLayoutEditorForUid:(uint32_t)uid name:(NSString *)name {
    __weak RootViewController *weakSelf = self;
    LayoutEditorViewController *vc = [[LayoutEditorViewController alloc] initWithUid:uid name:name portrait:YES
        onChange:^{
            RootViewController *s = weakSelf;
            if (s.gameRunning && uid == s.currentGameUid) { [s applyControls]; }
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.toolbarHidden = NO;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openGlobalKeybinds {
    __weak RootViewController *weakSelf = self;
    KeybindEditorViewController *vc = [[KeybindEditorViewController alloc] initWithUid:0 scopeName:@"Global"
        onChange:^{
            RootViewController *s = weakSelf;
            if (s.gameRunning) {
                [s.inputManager reloadBindingsForUid:s.currentGameUid];
            }
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// GameSettingsViewControllerDelegate: apply live if the edited game is the one running.
- (void)gameSettingsDidChangeForUid:(uint32_t)uid {
    EKAGameSettings *changed = [GameSettingsStore settingsForUid:uid];
    eka2l1::ios::bridge::set_app_refresh_rate(uid, (int)changed.refreshRate);
    eka2l1::ios::bridge::set_app_filter_shader(uid, (changed.filterShader ?: @"").UTF8String);  // takes effect next launch
    if (!self.gameRunning || uid != self.currentGameUid) {
        return;
    }
    eka2l1::ios::bridge::set_gyro_passthrough(changed.gyroPassthrough);  // live: affects the next sensor sample
    eka2l1::ios::bridge::set_haptic_passthrough(changed.hapticPassthrough);  // live: affects the next vibration request
    EKAGameSettings *s = [GameSettingsStore settingsForUid:uid];
    self.controlsView.overlayOpacity = s.controlsOpacity;
    self.keyLayout = s.keyLayout;
    self.currentGameHideIsland = s.hideDynamicIsland;
    self.currentGameShowStatus = s.showStatus;
    self.currentGameAutoScaleP = s.autoScalePortrait;
    self.currentGameAutoScaleL = s.autoScaleLandscape;
    self.currentGameRefreshRate = s.refreshRate;
    [self.emuView setRenderScale:s.renderScale];    // re-size the GL drawable if render scale changed
    [self.inputManager reloadBindingsForUid:uid];   // per-game keybinds may have changed
    [self updateChrome];
    [self.view setNeedsLayout];   // re-inset the GL view if Hide Dynamic Island changed
    [self applyScreenGravityForSize:self.view.bounds.size];
}

// Present a controller/keyboard-navigable menu (also tappable). Tracks it as the active menu
// so InputManager routes directional input to it instead of the guest.
- (void)presentGameMenu:(GameMenuView *)menu {
    [self.activeMenu dismiss];
    self.activeMenu = menu;
    self.inputManager.menuShown = YES;
    __weak RootViewController *weakSelf = self;
    [menu showInView:self.view onDismiss:^{
        RootViewController *s = weakSelf;
        if (s.activeMenu == menu) {
            s.activeMenu = nil;
            s.inputManager.menuShown = NO;
        }
    }];
}

// On-screen-layout choices in display order (5 = "Layout 1.5 (#/*)" between 1 and 2; 6 = Joystick).
+ (NSArray<NSNumber *> *)layoutOrder {
    return @[@0, @1, @5, @6, @2, @3, @4];
}

- (NSString *)layoutDisplayName:(NSInteger)i {
    if (i == 0) return @"None";
    if (i == 5) return @"Layout 1.5 (#/*)";
    if (i == 6) return @"Joystick";
    return [NSString stringWithFormat:@"Layout %ld", (long)i];
}

- (void)selectLayout:(NSInteger)i {
    self.keyLayout = i;
    [self updateChrome];
    // Persist the choice as this game's default so it sticks next launch.
    if (self.gameRunning) {
        EKAGameSettings *s = [GameSettingsStore settingsForUid:self.currentGameUid];
        s.keyLayout = i;
        [GameSettingsStore saveSettings:s forUid:self.currentGameUid];
    }
}

// Controller / keyboard path: the custom GameMenuView (navigable with dpad/arrows + A/Enter).
- (void)onMenuController {
    if (!self.gameRunning) {
        return;
    }
    GameMenuView *menu = [[GameMenuView alloc] initWithTitle:@"Game Menu"];
    [menu addOption:@"Switch Key Layout" destructive:NO handler:^{ [self showLayoutChooserController]; }];
    [menu addOption:@"Exit Game" destructive:YES handler:^{ [self exitGame]; }];
    [menu addOption:@"Cancel" destructive:NO handler:nil];
    [self presentGameMenu:menu];
}

- (void)showLayoutChooserController {
    GameMenuView *menu = [[GameMenuView alloc] initWithTitle:@"Key Layout"];
    for (NSNumber *num in [RootViewController layoutOrder]) {
        NSInteger i = num.integerValue;
        NSString *name = [self layoutDisplayName:i];
        NSString *title = (i == self.keyLayout) ? [name stringByAppendingString:@"  ✓"] : name;
        [menu addOption:title destructive:NO handler:^{ [self selectLayout:i]; }];
    }
    [menu addOption:@"Cancel" destructive:NO handler:nil];
    [self presentGameMenu:menu];
}

// Touch path (the "…" button): the native iOS action sheet ("liquid glass" popup).
- (void)onMenuTouch {
    if (!self.gameRunning) {
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Game Menu" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Switch Key Layout" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self showLayoutChooserNative]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Exit Game" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self exitGame]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.menuButton;
    sheet.popoverPresentationController.sourceRect = self.menuButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showLayoutChooserNative {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Key Layout" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *num in [RootViewController layoutOrder]) {
        NSInteger i = num.integerValue;
        NSString *name = [self layoutDisplayName:i];
        NSString *title = (i == self.keyLayout) ? [name stringByAppendingString:@"  ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { [self selectLayout:i]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.menuButton;
    sheet.popoverPresentationController.sourceRect = self.menuButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// ---- Hardware keyboard via the UIKit responder chain ----------------------

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet<UIPress *> *unhandled = [NSMutableSet set];
    for (UIPress *p in presses) {
        if (p.key && [self.inputManager handleKeyCode:(NSInteger)p.key.keyCode down:YES]) {
            continue;
        }
        [unhandled addObject:p];
    }
    if (unhandled.count) {
        [super pressesBegan:unhandled withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet<UIPress *> *unhandled = [NSMutableSet set];
    for (UIPress *p in presses) {
        if (p.key && [self.inputManager handleKeyCode:(NSInteger)p.key.keyCode down:NO]) {
            continue;
        }
        [unhandled addObject:p];
    }
    if (unhandled.count) {
        [super pressesEnded:unhandled withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (p.key) {
            [self.inputManager handleKeyCode:(NSInteger)p.key.keyCode down:NO];
        }
    }
    [super pressesCancelled:presses withEvent:event];
}

// ---- InputManagerDelegate -------------------------------------------------

- (void)inputManagerDidRequestMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.activeMenu) {
            [self.activeMenu dismiss];   // toggle closed
        } else {
            [self onMenuController];     // controller/keyboard → navigable menu
        }
    });
}

- (void)inputManagerDidNavigate:(NSInteger)dir {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.activeMenu) {
            [self.activeMenu navigate:dir];
        } else if (!self.gameRunning && !self.appsTable.hidden && self.presentedViewController == nil) {
            // Homescreen apps list: navigate the selection cursor / launch on confirm. The
            // presentedViewController guard stops a controller from driving the list (or
            // launching an app) while a settings/editor modal is up over it.
            [self navigateAppsList:dir];
        }
    });
}

- (void)exitGame {
    self.gameRunning = NO;
    self.controlsView.layout = 0;
    self.menuButton.hidden = YES;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = @"Exiting game…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        eka2l1::ios::bridge::exit_game();   // reboots the emulator instance
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateChrome];
            [self pollForAppsWithAttemptsLeft:20];
        });
    });
}

// ---- Install (device + game) ----------------------------------------------

- (void)maybeAutoInstallGame {
    if (![[[NSProcessInfo processInfo] arguments] containsObject:@"--installgame"]) return;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *imports = [docs stringByAppendingPathComponent:@"imports"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sis = nil;
    for (NSString *f in [fm contentsOfDirectoryAtPath:imports error:nil]) {
        NSString *e = [f pathExtension].lowercaseString;
        if ([e isEqualToString:@"sis"] || [e isEqualToString:@"sisx"]) { sis = [imports stringByAppendingPathComponent:f]; break; }
    }
    if (!sis) return;
    std::string path = [sis UTF8String];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = eka2l1::ios::bridge::install_app(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"EKA2L1: --installgame result=%d", result);
            [self showAppsScreen];
        });
    });
}

- (void)maybeAutoInstallDevice {
    if (![[[NSProcessInfo processInfo] arguments] containsObject:@"--autoinstall"]) return;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *imports = [docs stringByAppendingPathComponent:@"imports"];
    NSFileManager *fm = [NSFileManager defaultManager];
    std::string romPath, rpkgPath;
    for (NSString *f in [fm contentsOfDirectoryAtPath:imports error:nil]) {
        NSString *full = [imports stringByAppendingPathComponent:f];
        if ([[f pathExtension].lowercaseString isEqualToString:@"rpkg"]) rpkgPath = full.UTF8String;
        else if ([[f pathExtension].lowercaseString isEqualToString:@"rom"]) romPath = full.UTF8String;
    }
    if (romPath.empty() && rpkgPath.empty()) return;
    if (romPath.empty()) romPath = rpkgPath;
    [self runDeviceInstallWithRpkg:rpkgPath rom:romPath installRpkg:YES];
}

- (NSString *)importFileAtURL:(NSURL *)url {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *importsDir = [docs stringByAppendingPathComponent:@"imports"];
    [fm createDirectoryAtPath:importsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [importsDir stringByAppendingPathComponent:url.lastPathComponent];
    if (url.isFileURL && [url.path isEqualToString:dest]) {
        return dest;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [fm removeItemAtPath:dest error:nil];
    NSError *err = nil;
    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return ok ? dest : nil;
}

- (void)presentPicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleIncomingFileURL:(NSURL *)url {
    if (!url) {
        return;
    }
    if (!self.pendingImportedFiles) {
        self.pendingImportedFiles = [NSMutableArray array];
    }

    NSString *local = [self importFileAtURL:url];
    if (!local) {
        [self showAlert:@"Import failed" message:@"Could not read the selected file."];
        return;
    }

    if (!self.started) {
        [self.pendingImportedFiles addObject:local];
        return;
    }

    [self installImportedContentAtPath:local];
}

- (void)drainPendingImportedFiles {
    if (self.pendingImportedFiles.count == 0) {
        return;
    }

    NSString *path = self.pendingImportedFiles.firstObject;
    [self.pendingImportedFiles removeObjectAtIndex:0];
    [self installImportedContentAtPath:path];
}

- (void)installImportedContentAtPath:(NSString *)path {
    if (EKAIsNGagePackagePath(path)) {
        if (!eka2l1::ios::bridge::has_device()) {
            [self showAlert:@"No device" message:@"Install a Symbian device first, then import the N-Gage file again."];
            return;
        }
        [self installNGageFileFromPath:path];
        return;
    }

    if (EKAIsSisPackagePath(path)) {
        if (!eka2l1::ios::bridge::has_device()) {
            [self showAlert:@"No device" message:@"Install a Symbian device first, then install the package."];
            return;
        }

        std::string packagePath = [path UTF8String];
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Installing game…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int result = eka2l1::ios::bridge::install_app(packagePath);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (result == 0) {
                    [self showAppsScreen];
                    [self showAlert:@"Game installed" message:@"It now appears in the apps list."];
                } else {
                    [self showAlert:@"Install failed"
                            message:[NSString stringWithFormat:@"Could not install the package (error %d).", result]];
                }
            });
        });
        return;
    }

    [self showAlert:@"Unsupported file" message:@"Choose a SIS, SISX, or .n-gage file."];
}

// ---- Devices manager ------------------------------------------------------

- (void)onDeviceButton {
    if (!eka2l1::ios::bridge::has_device()) {
        [self onInstallDevice];
        return;
    }
    [self showDevicesMenu];
}

- (void)showDevicesMenu {
    std::vector<eka2l1::ios::bridge::device_entry> devices = eka2l1::ios::bridge::get_devices();
    int current = eka2l1::ios::bridge::get_current_device();

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Devices" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i < (int)devices.size(); i++) {
        NSString *name = [NSString stringWithUTF8String:devices[i].name.c_str()];
        NSString *title = (i == current) ? [name stringByAppendingString:@"  ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { [self deviceActionsForIndex:i name:name current:(i == current)]; }]];
    }
    NSUInteger hiddenCount = [HiddenAppsViewController hiddenCountForCurrentDevice];
    NSString *hiddenTitle = hiddenCount > 0
        ? [NSString stringWithFormat:@"Hidden Apps (%lu)", (unsigned long)hiddenCount]
        : @"Hidden Apps";
    [sheet addAction:[UIAlertAction actionWithTitle:hiddenTitle style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self openHiddenApps]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Install Another Device…" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self onInstallDevice]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.deviceButton;
    sheet.popoverPresentationController.sourceRect = self.deviceButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openHiddenApps {
    HiddenAppsViewController *vc = [[HiddenAppsViewController alloc] init];
    __weak RootViewController *weakSelf = self;
    vc.onChanged = ^{ [weakSelf showAppsScreen]; };   // re-show any unhidden app on the home screen
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)deviceActionsForIndex:(int)index name:(NSString *)name current:(BOOL)current {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    if (!current) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Switch to This Device" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { [self switchToDevice:index]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self promptRenameDevice:index name:name]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Language" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self showLanguagePickerForIndex:index name:name current:current]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self confirmDeleteDevice:index name:name current:current]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.deviceButton;
    sheet.popoverPresentationController.sourceRect = self.deviceButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)switchToDevice:(int)index {
    [self beginProgress:@"Switching device…"];
    [self climbProgressToward:0.95f];   // reboot has no granular metric
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // set_current_device returns once the new instance's threads are spawned; the guest
        // then boots asynchronously, so keep the bar climbing until its apps appear.
        eka2l1::ios::bridge::set_current_device(index);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateChrome];
            [self pollUntilAppsThen:^(BOOL found) {
                [self endProgress];
                [self showAppsScreen];
            } attemptsLeft:30];
        });
    });
}

- (void)confirmDeleteDevice:(int)index name:(NSString *)name current:(BOOL)current {
    NSString *msg = current
        ? [NSString stringWithFormat:@"Delete “%@”? It’s the active device, so the emulator will reboot onto another installed device.", name]
        : [NSString stringWithFormat:@"Delete “%@” from your devices?", name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Device" message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self performDeleteDevice:index current:current]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDeleteDevice:(int)index current:(BOOL)current {
    if (!current) {
        // Removing a non-active device only reshuffles the list — quick, no reboot.
        eka2l1::ios::bridge::delete_device(index);
        [self refreshDeviceButton];
        [self showAlert:@"Device deleted" message:@"It was removed from your devices."];
        return;
    }
    [self beginProgress:@"Deleting device…"];
    [self climbProgressToward:0.95f];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        eka2l1::ios::bridge::delete_device(index);   // reboots onto another device (or none)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateChrome];
            [self refreshDeviceButton];
            if (eka2l1::ios::bridge::has_device()) {
                [self pollUntilAppsThen:^(BOOL found) {
                    [self endProgress];
                    [self showAppsScreen];
                } attemptsLeft:30];
            } else {
                [self endProgress];
                self.appsTable.hidden = YES;
                self.statusLabel.hidden = NO;
                self.statusLabel.text = @"No Symbian device installed.\n\nTap “Install Device” to add one.";
            }
        });
    });
}

- (void)promptRenameDevice:(int)index name:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Device"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = name;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            NSString *newName = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (newName.length == 0) return;
            eka2l1::ios::bridge::rename_device(index, std::string([newName UTF8String]));
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLanguagePickerForIndex:(int)index name:(NSString *)name current:(BOOL)current {
    std::vector<eka2l1::ios::bridge::language_entry> langs = eka2l1::ios::bridge::get_device_languages(index);
    if (langs.empty()) {
        [self showAlert:@"No languages" message:@"This device's firmware doesn't list any languages."];
        return;
    }
    // Each device keeps its own language; check the one selected for THIS device.
    int selectedLang = eka2l1::ios::bridge::get_device_language(index);

    // The active device reboots to apply immediately; others just remember the choice.
    NSString *msg = current ? nil : @"Applies the next time you switch to this device.";
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"%@ — Language", name] message:msg
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (const auto &lang : langs) {
        int langId = lang.id;
        NSString *lname = [NSString stringWithUTF8String:lang.name.c_str()];
        NSString *title = (langId == selectedLang) ? [lname stringByAppendingString:@"  ✓"] : lname;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { [self applyLanguage:langId forDeviceIndex:index current:current]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.deviceButton;
    sheet.popoverPresentationController.sourceRect = self.deviceButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyLanguage:(int)languageId forDeviceIndex:(int)index current:(BOOL)current {
    if (!current) {
        // A non-active device only needs the choice stored — no reboot. It takes effect when
        // the user switches to that device.
        eka2l1::ios::bridge::set_device_language(index, languageId);
        [self showAlert:@"Language set" message:@"It will be used when you switch to this device."];
        return;
    }
    [self beginProgress:@"Changing language…"];
    [self climbProgressToward:0.95f];   // reboot has no granular metric
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The active device reboots in place to apply the new language; the guest then boots
        // asynchronously, so keep the bar climbing until its apps reappear.
        eka2l1::ios::bridge::set_device_language(index, languageId);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateChrome];
            [self refreshDeviceButton];
            [self pollUntilAppsThen:^(BOOL found) {
                [self endProgress];
                [self showAppsScreen];
            } attemptsLeft:30];
        });
    });
}

// ---- Settings (N-Gage) ----------------------------------------------------

- (void)onSettings {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Settings" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    // Progress Sync. Once iCloud sync is on, the entry shows its status and a "Sync Now" refresh
    // appears next to it; tapping the status entry re-opens the sync page.
    EKASyncManager *sync = [EKASyncManager shared];
    [sheet addAction:[UIAlertAction actionWithTitle:[self progressSyncTitle] style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self openProgressSync]; }]];
    if (sync.iCloudEnabled) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Sync Now  ⟳" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { [sync syncNow:nil]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"N-Gage" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self showNGageMenu]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Keybinds" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self openGlobalKeybinds]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Packages" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self openPackages]; }]];
    // CPU backend: jitless interpreter (default) vs. the dynarmic JIT (opt-in, needs an enabler).
    [sheet addAction:[UIAlertAction actionWithTitle:@"CPU Backend" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self showCpuBackendMenu]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete All App Data" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self confirmWipeAllData]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // Anchor on the Settings toolbar button (3rd subview) for iPad popovers.
    UIView *anchor = (self.toolbar.subviews.count > 2) ? self.toolbar.subviews[2] : self.toolbar;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Settings-sheet label for Progress Sync, reflecting the live sync state once iCloud is on.
- (NSString *)progressSyncTitle {
    EKASyncManager *s = [EKASyncManager shared];
    if (!s.iCloudEnabled) return @"Progress Sync";
    switch (s.status) {
        case EKASyncStatusSyncing:     return @"Progress Sync — Syncing…";
        case EKASyncStatusSynced:      return @"Progress Sync — Synced";
        case EKASyncStatusUnavailable: return @"Progress Sync — iCloud unavailable";
        case EKASyncStatusError:       return @"Progress Sync — Error";
        default:                       return @"Progress Sync";
    }
}

// CPU backend chooser: jitless interpreter (works anywhere) vs. the dynarmic JIT (faster but
// only runs when the app is launched through a JIT enabler).
- (void)showCpuBackendMenu {
    BOOL jit = eka2l1::ios::bridge::get_jit_enabled();
    NSString *msg = @"The interpreter runs on any device with no setup — this is the default. "
                     "JIT (the dynarmic recompiler) is faster for CPU-heavy games, but only works when "
                     "you launch the app through a JIT enabler (AltStore / SideStore / StikJIT, or "
                     "with a debugger attached). Without an enabler, turning JIT on will stop apps "
                     "from opening. Changing this reboots the emulator.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"CPU Backend" message:msg
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:(jit ? @"Interpreter (no JIT)" : @"Interpreter (no JIT)  ✓")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self applyJitEnabled:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:(jit ? @"JIT — dynarmic (Experimental)  ✓" : @"JIT — dynarmic (Experimental)")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self confirmEnableJit]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = (self.toolbar.subviews.count > 2) ? self.toolbar.subviews[2] : self.toolbar;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmEnableJit {
    if (eka2l1::ios::bridge::get_jit_enabled()) { return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enable JIT?"
        message:@"JIT only works if you launch this app through a JIT enabler (AltStore / SideStore / "
                 "StikJIT) or with a debugger attached. If the app isn't JIT-enabled, apps won't open — "
                 "relaunch through your enabler, or toggle JIT back off, to recover. Continue?"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Enable JIT" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self applyJitEnabled:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyJitEnabled:(BOOL)enabled {
    if (eka2l1::ios::bridge::get_jit_enabled() == enabled) { return; }
    [self beginProgress:enabled ? @"Enabling JIT…" : @"Disabling JIT…"];
    [self climbProgressToward:0.95f];   // reboot has no granular metric
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Persists the preference and reboots the emulator in place so the new CPU core is built.
        eka2l1::ios::bridge::set_jit_enabled(enabled);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateChrome];
            // With a device installed the guest re-boots asynchronously, so keep the bar climbing
            // until its apps reappear; with no device there's nothing to wait for.
            if (eka2l1::ios::bridge::has_device()) {
                [self pollUntilAppsThen:^(BOOL found) {
                    [self endProgress];
                    [self showAppsScreen];
                } attemptsLeft:30];
            } else {
                [self endProgress];
                [self showAppsScreen];
            }
        });
    });
}

- (void)openProgressSync {
    SyncViewController *vc = [[SyncViewController alloc] init];
    __weak RootViewController *weakSelf = self;
    vc.onDataImported = ^{ [weakSelf refreshAfterDataImport]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openPackages {
    if (!eka2l1::ios::bridge::has_device()) {
        [self showAlert:@"No device" message:@"Install a Symbian device first to manage installed packages."];
        return;
    }
    PackageListViewController *vc = [[PackageListViewController alloc] init];
    __weak RootViewController *weakSelf = self;
    // Deleting a package reboots the guest, so re-scan the apps list when something changed.
    vc.onChanged = ^{ [weakSelf refreshAfterDataImport]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// A backup import overwrote the data dir and rebooted the emulator — refresh the home UI.
- (void)refreshAfterDataImport {
    self.gameRunning = NO;
    [self.iconCache removeAllObjects];
    [self updateChrome];
    [self refreshDeviceButton];
    [self showAppsScreen];
}

- (void)confirmWipeAllData {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete All App Data"
        message:@"This erases everything — installed devices, games, save data and settings — and returns the app to a fresh state. This cannot be undone."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete Everything" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { [self performWipeAllData]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performWipeAllData {
    [self beginProgress:@"Erasing all app data…"];
    [self climbProgressToward:0.95f];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        eka2l1::ios::bridge::wipe_app_data();   // tears down, deletes data, restarts (no device)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endProgress];
            self.gameRunning = NO;
            [self.iconCache removeAllObjects];
            self.apps = @[];
            [self.appsTable reloadData];
            [self updateChrome];
            [self refreshDeviceButton];
            self.appsTable.hidden = YES;
            self.statusLabel.hidden = NO;
            self.statusLabel.text = @"App data erased.\n\nNo Symbian device installed — tap “Install Device” to add one.";
        });
    });
}

- (void)showNGageMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"N-Gage" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Install N-Gage Game" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            if (!eka2l1::ios::bridge::has_device()) {
                [self showAlert:@"No device" message:@"Install a Symbian device first, then install an N-Gage game."];
                return;
            }
            self.pickMode = PickModeNGage;
            [self presentFolderPicker];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Install .n-gage File" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            if (!eka2l1::ios::bridge::has_device()) {
                [self showAlert:@"No device" message:@"Install a Symbian device first, then install an N-Gage file."];
                return;
            }
            self.pickMode = PickModeNGageFile;
            [self presentPicker];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = (self.toolbar.subviews.count > 2) ? self.toolbar.subviews[2] : self.toolbar;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentFolderPicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)installNGageFromFolder:(NSString *)folder {
    self.appsTable.hidden = YES;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = @"Installing N-Gage game…";
    [self setToolbarBusy:YES];
    std::string path = [folder UTF8String];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string name;
        int result = eka2l1::ios::bridge::install_ngage_game(path, name);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setToolbarBusy:NO];
            if (result == 0) {
                [self showAppsScreen];
                NSString *gameName = name.empty() ? @"the game" : [NSString stringWithUTF8String:name.c_str()];
                [self showAlert:@"N-Gage game installed"
                        message:[NSString stringWithFormat:@"Installed %@. It now appears in the apps list.", gameName]];
            } else {
                [self showAppsScreen];
                [self showAlert:@"Install failed" message:[self ngageErrorMessage:result]];
            }
        });
    });
}

- (NSString *)ngageErrorMessage:(int)code {
    switch (code) {
        case 1: return @"Couldn't find the game data folder. Pick the N-Gage game card folder itself (the one containing the “system” folder).";
        case 2: return @"That card folder contains more than one game.";
        case 3: return @"The game registration file is missing from the card folder.";
        case 4: return @"The game registration file is corrupted. Check your data.";
        default: return [NSString stringWithFormat:@"Could not install the N-Gage game (error %d).", code];
    }
}

// Install a single ".n-gage" file by copying it into drives/e/n-gage (what Android asks
// the user to do by hand) and rebooting so the N-Gage launcher re-scans on next open.
- (void)installNGageFileFromPath:(NSString *)path {
    [self beginProgress:@"Adding .n-gage file…"];
    [self climbProgressToward:0.95f];   // the copy is quick; the reboot afterwards is the wait
    std::string src = [path UTF8String];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string name;
        int result = eka2l1::ios::bridge::install_ngage_file(src, name);   // copies + reboots
        NSString *fileName = name.empty() ? @"The game file" : [NSString stringWithUTF8String:name.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == 0) {
                // Reboot in progress; finish once the guest's apps reload.
                [self pollUntilAppsThen:^(BOOL found) {
                    [self endProgress];
                    [self showAppsScreen];
                    [self showAlert:@"N-Gage file added"
                            message:[NSString stringWithFormat:@"%@ was placed in drives/e/n-gage. Open the N-Gage app — it will detect and install the game.", fileName]];
                } attemptsLeft:30];
            } else {
                [self endProgress];
                [self showAppsScreen];
                [self showAlert:@"Install failed"
                        message:@"Couldn't copy the .n-gage file into the device’s storage."];
            }
        });
    });
}

- (void)onInstallDevice {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Install Device"
                         message:@"Choose how you want to install your Symbian device."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Device Dump (Recommended)" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self onInstallDeviceDump]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"VPL Firmware" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [self onInstallVplFirmware]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onInstallDeviceDump {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Install Device (1/2)"
                         message:@"Select your Symbian ROM file (e.g. SYM.ROM)."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose ROM" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { self.pickMode = PickModeDeviceRom; [self presentPicker]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// A VPL firmware is a folder holding the .vpl manifest plus its .fpsx/.rofs blobs, all
// resolved relative to the .vpl's directory by install_firmware. iOS sandboxes single-file
// picks (only the chosen file is reachable), so — like the Android scoped-storage path — we
// pick the whole folder, copy it in, and locate the .vpl inside.
- (void)onInstallVplFirmware {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VPL Firmware"
                         message:@"Select the folder that contains your firmware’s .vpl file (along with its .fpsx / .rofs files)."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose Folder" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { self.pickMode = PickModeVplFirmware; [self presentFolderPicker]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Returns the first ".vpl" file found directly inside folder, or nil if none.
- (NSString *)findVplInFolder:(NSString *)folder {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:folder error:nil]) {
        if ([[f pathExtension].lowercaseString isEqualToString:@"vpl"]) {
            return [folder stringByAppendingPathComponent:f];
        }
    }
    return nil;
}

- (void)installVplFirmwareFromFolder:(NSString *)folder {
    NSString *vpl = [self findVplInFolder:folder];
    if (!vpl) {
        [self showAlert:@"No .vpl file"
                message:@"That folder doesn’t contain a .vpl file. Pick the folder that holds your firmware’s .vpl manifest and its .fpsx / .rofs files."];
        return;
    }
    [self runDeviceInstallWithRpkg:std::string() rom:std::string([vpl UTF8String]) installRpkg:NO];
}

- (void)promptForRpkg {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Install Device (2/2)"
                         message:@"Select the RPKG firmware file. Most S60v5 / Symbian^3 ROMs need one. Tap “Skip” if your ROM is already complete."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose RPKG" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { self.pickMode = PickModeDeviceRpkg; [self presentPicker]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Skip" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            [self runDeviceInstallWithRpkg:std::string() rom:std::string([self.pendingRomPath UTF8String]) installRpkg:YES];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onInstallGame { self.pickMode = PickModeGame; [self presentPicker]; }

// Device-dump install: installRpkg = YES, rom = ROM path, rpkg = optional RPKG.
// VPL firmware install: installRpkg = NO, rpkg empty, rom = the .vpl manifest path.
- (void)runDeviceInstallWithRpkg:(std::string)rpkg rom:(std::string)rom installRpkg:(BOOL)installRpkg {
    [self beginProgress:installRpkg ? @"Installing device…" : @"Installing firmware…"];

    // Real extraction progress (0..100) drives the bar to 90%; the post-extraction boot
    // then eases it toward completion (no granular metric for the boot itself). `me` is
    // the root view controller, which lives for the app's lifetime, so a strong capture is
    // safe (and the std::function is released as soon as the install call returns).
    RootViewController *me = self;
    std::function<void(int)> progress = [me](int pct) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (pct >= 100) {
                me.statusLabel.text = @"Booting device…";
                [me setProgressFraction:0.9f];
                [me climbProgressToward:0.98f];
            } else {
                [me setProgressFraction:(pct / 100.0f) * 0.9f];
            }
        });
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = eka2l1::ios::bridge::install_device(rpkg, rom, installRpkg, progress);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result == 0) {
                // Extraction done; the guest now boots asynchronously. Keep the bar moving
                // until its apps register, then finish.
                self.statusLabel.text = @"Booting device…";
                [self climbProgressToward:0.98f];
                [self pollUntilAppsThen:^(BOOL found) {
                    [self endProgress];
                    [self showAppsScreen];
                    [self showAlert:@"Device installed" message:@"The Symbian device was installed and booted."];
                } attemptsLeft:30];
            } else {
                [self endProgress];
                self.statusLabel.text = @"No Symbian device installed.\n\nTap “Install Device” to try again.";
                NSString *msg;
                if (!installRpkg) {
                    // device_installation_vpl_file_invalid == 8 (system/installation/common.h)
                    msg = (result == 8)
                        ? @"That .vpl firmware is invalid. Pick the folder holding a valid .vpl manifest and all of its .fpsx / .rofs files."
                        : [NSString stringWithFormat:@"Could not install the firmware (error %d). Select a folder with a valid .vpl manifest and its firmware files.", result];
                } else {
                    msg = [NSString stringWithFormat:@"Could not install (error %d). Select a valid ROM and RPKG.", result];
                }
                [self showAlert:@"Install failed" message:msg];
            }
        });
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    PickMode mode = self.pickMode;
    NSString *local = (urls.count > 0) ? [self importFileAtURL:urls.firstObject] : nil;
    if (!local) { [self showAlert:@"Import failed" message:@"Could not read the selected file."]; return; }

    if (mode == PickModeDeviceRom) {
        self.pendingRomPath = local;
        [self promptForRpkg];
    } else if (mode == PickModeDeviceRpkg) {
        std::string rpkg = [local UTF8String];
        std::string rom = self.pendingRomPath ? std::string([self.pendingRomPath UTF8String]) : rpkg;
        [self runDeviceInstallWithRpkg:rpkg rom:rom installRpkg:YES];
    } else if (mode == PickModeVplFirmware) {
        [self installVplFirmwareFromFolder:local];
    } else if (mode == PickModeNGage) {
        [self installNGageFromFolder:local];
    } else if (mode == PickModeNGageFile) {
        if (!EKAIsNGagePackagePath(local)) {
            [self showAlert:@"Unsupported file" message:@"Choose a .n-gage file."];
            return;
        }
        [self installNGageFileFromPath:local];
    } else {
        [self installImportedContentAtPath:local];
    }
}

// ---- Apps table -----------------------------------------------------------

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EKAAppCell *cell = (EKAAppCell *)[tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[EKAAppCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        // No tap-selection highlight: the keyboard/controller cursor is drawn manually below
        // (via backgroundColor) so a plain touch/tap never lights a row up.
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *app = self.apps[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.imageView.image = self.iconCache[app[@"uid"]] ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.backgroundColor = (self.cursorVisible && indexPath.row == self.selectedAppIndex) ? [self appCursorColor]
                                                                                          : [self appRowColor];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self hideAppsCursor];   // this was a touch, not a nav key
    std::uint32_t uid = (std::uint32_t)[self.apps[indexPath.row][@"uid"] unsignedLongValue];
    [self launchAppUid:uid];
}

// Any touch-drag of the list hides the keyboard/controller cursor (programmatic scrolls from
// navigateAppsList do not trigger this, so moving the cursor keeps it visible).
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self hideAppsCursor];
}

@end
