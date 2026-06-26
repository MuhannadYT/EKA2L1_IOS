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
#import "LayoutEditorViewController.h"
#import "GameControlsView.h"
#import "GameSettingsStore.h"

@interface LayoutEditorViewController () <GameControlsEditingDelegate>
@end

@implementation LayoutEditorViewController {
    uint32_t _uid;
    NSString *_name;
    BOOL _portrait;
    void (^_onChange)(void);
    GameControlsView *_controls;
    UIView *_preview;
    UILabel *_hint;
    NSArray<NSDictionary *> *_defaultSeed;   // built-in layout the editor seeds/resets to
}

- (instancetype)initWithUid:(uint32_t)uid name:(NSString *)name portrait:(BOOL)portrait
                   onChange:(void (^)(void))onChange {
    self = [super init];
    if (self) {
        _uid = uid;
        _name = name;
        _portrait = portrait;
        _onChange = [onChange copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = _portrait ? @"Edit Layout (Portrait)" : @"Edit Layout (Landscape)";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self action:@selector(onSave)];

    // Preview area sized to the target orientation's aspect, fit within the screen.
    _preview = [[UIView alloc] init];
    _preview.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    _preview.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    _preview.layer.borderWidth = 1.0;
    [self.view addSubview:_preview];

    _controls = [[GameControlsView alloc] initWithFrame:CGRectZero];
    _controls.editDelegate = self;
    EKAGameSettings *s = [GameSettingsStore settingsForUid:_uid];
    // The "default" for this layout is the selected on-screen layout (e.g. Joystick) rendered as
    // editable elements, so the editor — and the Reset button — reflect the user's choice. None
    // (layout 0) falls back to a sensible D-pad default.
    NSArray *seed = [GameControlsView customLayoutForBuiltinLayout:s.keyLayout];
    _defaultSeed = seed.count ? seed : [GameControlsView defaultCustomLayout];
    NSArray *existing = _portrait ? s.customLayoutPortrait : s.customLayoutLandscape;
    _controls.customLayout = existing.count ? existing : _defaultSeed;
    _controls.editing = YES;
    [_preview addSubview:_controls];

    _hint = [[UILabel alloc] init];
    _hint.text = @"Drag to move • pinch or −/+ to resize • Add inserts a button";
    _hint.font = [UIFont systemFontOfSize:13];
    _hint.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.numberOfLines = 0;
    [self.view addSubview:_hint];

    [self setupToolbar];
}

- (void)setupToolbar {
    self.navigationController.toolbarHidden = NO;
    UIBarButtonItem *(^item)(NSString *, SEL) = ^(NSString *t, SEL a) {
        return [[UIBarButtonItem alloc] initWithTitle:t style:UIBarButtonItemStylePlain target:self action:a];
    };
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[
        item(@"Add", @selector(onAdd)), flex,
        item(@"−", @selector(onShrink)), flex,
        item(@"+", @selector(onGrow)), flex,
        item(@"Delete", @selector(onDelete)), flex,
        item(@"Reset", @selector(onReset)),
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom + 44;   // leave room for the toolbar
    CGRect avail = CGRectMake(16, top + 36, self.view.bounds.size.width - 32,
                              self.view.bounds.size.height - top - bottom - 44);
    _hint.frame = CGRectMake(16, top + 6, self.view.bounds.size.width - 32, 28);

    // Fit a rect with the target orientation's aspect inside `avail`.
    CGFloat dmin = MIN(self.view.bounds.size.width, self.view.bounds.size.height);
    CGFloat dmax = MAX(self.view.bounds.size.width, self.view.bounds.size.height);
    CGFloat ratio = _portrait ? (dmin / dmax) : (dmax / dmin);   // width / height
    CGFloat w = avail.size.width, h = w / ratio;
    if (h > avail.size.height) { h = avail.size.height; w = h * ratio; }
    _preview.frame = CGRectMake(CGRectGetMidX(avail) - w / 2, CGRectGetMinY(avail) + (avail.size.height - h) / 2, w, h);
    _controls.frame = _preview.bounds;
}

// ---- Toolbar actions ------------------------------------------------------

- (void)onAdd {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add Button" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *entry in [GameControlsView buttonPalette]) {
        NSString *label = entry[@"label"];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                if ([entry[@"dpad"] boolValue]) {
                    [self->_controls addDpad];
                } else if ([entry[@"joystick"] boolValue]) {
                    [self->_controls addJoystick];
                } else {
                    [self->_controls addKeyWithCodes:entry[@"codes"] label:label];
                }
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.toolbarItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onShrink { [_controls scaleSelectedBy:0.85]; }
- (void)onGrow   { [_controls scaleSelectedBy:1.18]; }

- (void)onDelete {
    if (![_controls hasSelection]) {
        return;
    }
    [_controls deleteSelected];
}

- (void)onReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Layout"
        message:@"Restore the default on-screen layout for this orientation?"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) { self->_controls.customLayout = self->_defaultSeed; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onSave {
    EKAGameSettings *s = [GameSettingsStore settingsForUid:_uid];
    NSArray *layout = [_controls currentLayout];
    if (_portrait) s.customLayoutPortrait = layout;
    else           s.customLayoutLandscape = layout;
    [GameSettingsStore saveSettings:s forUid:_uid];
    if (_onChange) _onChange();
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)gameControlsDidChange:(GameControlsView *)view {
    // Selection/geometry changed — nothing else needed; the view redraws itself.
}

@end
