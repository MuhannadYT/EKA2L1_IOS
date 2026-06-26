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
#import "KeybindCaptureViewController.h"
#import <GameController/GameController.h>

@implementation KeybindCaptureViewController {
    BOOL _isController;
    void (^_completion)(NSArray * _Nullable);
    NSMutableArray *_working;     // accumulated combo (NSNumber codes / NSString tokens), insertion order
    NSMutableSet *_heldNow;        // currently-held members of _working
    UILabel *_label;
    BOOL _done;
}

- (instancetype)initForController:(BOOL)isController completion:(void (^)(NSArray * _Nullable))completion {
    self = [super init];
    if (self) {
        _isController = isController;
        _completion = [completion copy];
        _working = [NSMutableArray array];
        _heldNow = [NSMutableSet set];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];

    _label = [[UILabel alloc] init];
    _label.numberOfLines = 0;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _label.text = _isController ? @"Press a controller button\n(or hold a combo), then release"
                                : @"Press a key\n(or hold a combo), then release";
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_label];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancel addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:cancel];

    [NSLayoutConstraint activateConstraints:@[
        [_label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [_label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [cancel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-40],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_isController) {
        [self observeControllers];
    } else {
        [self becomeFirstResponder];
    }
}

- (void)onCancel {
    [self finishWith:nil];
}

- (void)finishWith:(NSArray *)combo {
    if (_done) {
        return;
    }
    _done = YES;
    void (^cb)(NSArray *) = _completion;
    _completion = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(combo);
    }];
}

- (void)addMember:(id)m {
    if (![_working containsObject:m]) {
        [_working addObject:m];
    }
    [_heldNow addObject:m];
    _label.text = [NSString stringWithFormat:@"%@", [_working componentsJoinedByString:@" + "]];
}

- (void)removeMember:(id)m {
    [_heldNow removeObject:m];
    // Commit the captured combo once everything is released.
    if (_heldNow.count == 0 && _working.count > 0) {
        [self finishWith:[_working copy]];
    }
}

// ---- Keyboard capture (responder chain) -----------------------------------

- (BOOL)canBecomeFirstResponder { return !_isController; }

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL any = NO;
    for (UIPress *p in presses) {
        if (p.key) { [self addMember:@((NSInteger)p.key.keyCode)]; any = YES; }
    }
    if (!any) [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL any = NO;
    for (UIPress *p in presses) {
        if (p.key) { [self removeMember:@((NSInteger)p.key.keyCode)]; any = YES; }
    }
    if (!any) [super pressesEnded:presses withEvent:event];
}

// ---- Controller capture ---------------------------------------------------

- (void)observeControllers {
    for (GCController *c in GCController.controllers) {
        [self attach:c];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onConnect:)
                                                 name:GCControllerDidConnectNotification object:nil];
}

- (void)onConnect:(NSNotification *)n {
    if (n.object) [self attach:n.object];
}

- (void)attach:(GCController *)controller {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    __weak KeybindCaptureViewController *weakSelf = self;
    pad.valueChangedHandler = ^(GCExtendedGamepad *gp, GCControllerElement *e) {
        [weakSelf readGamepad:gp];
    };
}

- (void)readGamepad:(GCExtendedGamepad *)gp {
    NSMutableSet *now = [NSMutableSet set];
    void (^chk)(BOOL, NSString *) = ^(BOOL on, NSString *tok) { if (on) [now addObject:tok]; };
    chk(gp.buttonA.isPressed, @"A");
    chk(gp.buttonB.isPressed, @"B");
    chk(gp.buttonX.isPressed, @"X");
    chk(gp.buttonY.isPressed, @"Y");
    chk(gp.leftShoulder.isPressed, @"L1");
    chk(gp.rightShoulder.isPressed, @"R1");
    chk(gp.leftTrigger.isPressed, @"L2");
    chk(gp.rightTrigger.isPressed, @"R2");
    chk(gp.buttonMenu.isPressed, @"MENU");
    if (gp.buttonOptions) chk(gp.buttonOptions.isPressed, @"MENU");
    chk(gp.dpad.up.isPressed, @"DP_U"); chk(gp.dpad.down.isPressed, @"DP_D");
    chk(gp.dpad.left.isPressed, @"DP_L"); chk(gp.dpad.right.isPressed, @"DP_R");
    const float TH = 0.5f;
    chk(gp.leftThumbstick.yAxis.value > TH, @"LS_U");  chk(gp.leftThumbstick.yAxis.value < -TH, @"LS_D");
    chk(gp.leftThumbstick.xAxis.value < -TH, @"LS_L"); chk(gp.leftThumbstick.xAxis.value > TH, @"LS_R");
    chk(gp.rightThumbstick.yAxis.value > TH, @"RS_U");  chk(gp.rightThumbstick.yAxis.value < -TH, @"RS_D");
    chk(gp.rightThumbstick.xAxis.value < -TH, @"RS_L"); chk(gp.rightThumbstick.xAxis.value > TH, @"RS_R");

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *t in now) [self addMember:t];
        for (id t in [_working copy]) {
            if (![now containsObject:t]) [self removeMember:t];
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
