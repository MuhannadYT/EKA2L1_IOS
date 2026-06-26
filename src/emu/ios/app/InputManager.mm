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
#import "InputManager.h"
#import "KeybindStore.h"
#import <GameController/GameController.h>

#include <ios/emu_bridge.h>

// Symbian key scancodes (mirror GameControlsView.mm / android Keycode.java).
enum {
    SC_UP = 0x10, SC_DOWN = 0x11, SC_LEFT = 0x0E, SC_RIGHT = 0x0F,
    SC_FIRE = 0xA7, SC_SOFT_LEFT = 0xA4, SC_SOFT_RIGHT = 0xA5,
    // Extra N-Gage helper actions send the same keypad scancodes Android's overlay uses.
    SC_EXTRA_POUND = 0x7F, SC_EXTRA_STAR = '*'
};

@implementation InputManager {
    NSMutableSet<NSNumber *> *_heldKeys;     // currently-down keyboard GCKeyCodes
    NSMutableSet<NSString *> *_heldCtrl;     // currently-active controller tokens (see readGamepad)
    NSMutableSet<NSNumber *> *_pressed;       // scancodes currently pressed into the guest
    NSSet<NSNumber *> *_prevActive;           // actions active last recompute (edge detection)
    NSArray<NSDictionary *> *_kbBindings;     // { keys:[GCKeyCode], action:EKAAction }
    NSArray<NSDictionary *> *_ctrlBindings;   // { tokens:[NSString], action:EKAAction }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _heldKeys = [NSMutableSet set];
        _heldCtrl = [NSMutableSet set];
        _pressed = [NSMutableSet set];
        _prevActive = [NSSet set];
        [self reloadBindingsForUid:0];
    }
    return self;
}

// ---- Bindings -------------------------------------------------------------

- (void)reloadBindingsForUid:(uint32_t)uid {
    _kbBindings = [KeybindStore keyboardBindingsForUid:uid];
    _ctrlBindings = [KeybindStore controllerBindingsForUid:uid];
}

// Keyboard from the UIKit responder chain. _heldKeys is a plain set, so if GCKeyboard also
// reports the same key the add/remove is idempotent (no double input).
- (BOOL)handleKeyCode:(NSInteger)hidUsage down:(BOOL)down {
    NSNumber *code = @(hidUsage);
    if (down) [_heldKeys addObject:code];
    else      [_heldKeys removeObject:code];
    [self recompute];

    for (NSDictionary *b in _kbBindings) {
        if ([b[@"keys"] containsObject:code]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSNumber *> *ScancodesForAction(EKAAction a) {
    switch (a) {
        case EKAActionUp:        return @[@(SC_UP)];
        case EKAActionDown:      return @[@(SC_DOWN)];
        case EKAActionLeft:      return @[@(SC_LEFT)];
        case EKAActionRight:     return @[@(SC_RIGHT)];
        case EKAActionUpLeft:    return @[@(SC_UP), @(SC_LEFT)];
        case EKAActionUpRight:   return @[@(SC_UP), @(SC_RIGHT)];
        case EKAActionDownLeft:  return @[@(SC_DOWN), @(SC_LEFT)];
        case EKAActionDownRight: return @[@(SC_DOWN), @(SC_RIGHT)];
        case EKAActionFire:      return @[@(SC_FIRE)];
        case EKAActionSoftLeft:  return @[@(SC_SOFT_LEFT)];
        case EKAActionSoftRight: return @[@(SC_SOFT_RIGHT)];
        case EKAActionMenu:      return @[];   // UI action, no scancode
        case EKAActionAKey:      return @[@(SC_EXTRA_POUND)];
        case EKAActionBKey:      return @[@(SC_EXTRA_STAR)];
        case EKAActionCount:     return @[];
    }
    return @[];
}

// ---- GameController observation -------------------------------------------

- (void)startObserving {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onKeyboardConnect:) name:GCKeyboardDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(onControllerConnect:) name:GCControllerDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(onControllerDisconnect:) name:GCControllerDidDisconnectNotification object:nil];

    if (GCKeyboard.coalescedKeyboard) {
        [self attachKeyboard:GCKeyboard.coalescedKeyboard];
    }
    for (GCController *c in GCController.controllers) {
        [self attachController:c];
    }
}

- (void)onKeyboardConnect:(NSNotification *)note {
    GCKeyboard *kb = note.object;
    if (kb) {
        [self attachKeyboard:kb];
    }
}

- (void)onControllerConnect:(NSNotification *)note {
    GCController *c = note.object;
    if (c) {
        [self attachController:c];
    }
}

- (void)onControllerDisconnect:(NSNotification *)note {
    [_heldCtrl removeAllObjects];
    [self recompute];
}

- (void)attachKeyboard:(GCKeyboard *)keyboard {
    __weak InputManager *weakSelf = self;
    keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *kbInput, GCControllerButtonInput *key,
                                                 GCKeyCode keyCode, BOOL pressed) {
        InputManager *s = weakSelf;
        if (!s) return;
        NSNumber *code = @((NSInteger)keyCode);
        if (pressed) [s->_heldKeys addObject:code];
        else         [s->_heldKeys removeObject:code];
        [s recompute];
    };
}

- (void)attachController:(GCController *)controller {
    __weak InputManager *weakSelf = self;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) {
        return;
    }
    pad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        InputManager *s = weakSelf;
        if (!s) return;
        [s readGamepad:gamepad];
        [s recompute];
    };
}

- (void)readGamepad:(GCExtendedGamepad *)gp {
    [_heldCtrl removeAllObjects];
    if (gp.buttonA.isPressed)        [_heldCtrl addObject:@"A"];
    if (gp.buttonB.isPressed)        [_heldCtrl addObject:@"B"];
    if (gp.buttonX.isPressed)        [_heldCtrl addObject:@"X"];
    if (gp.buttonY.isPressed)        [_heldCtrl addObject:@"Y"];
    if (gp.leftShoulder.isPressed)   [_heldCtrl addObject:@"L1"];
    if (gp.rightShoulder.isPressed)  [_heldCtrl addObject:@"R1"];
    if (gp.buttonMenu.isPressed)     [_heldCtrl addObject:@"MENU"];
    if (gp.buttonOptions && gp.buttonOptions.isPressed) [_heldCtrl addObject:@"MENU"];

    GCControllerDirectionPad *d = gp.dpad;
    if (d.up.isPressed)    [_heldCtrl addObject:@"DP_U"];
    if (d.down.isPressed)  [_heldCtrl addObject:@"DP_D"];
    if (d.left.isPressed)  [_heldCtrl addObject:@"DP_L"];
    if (d.right.isPressed) [_heldCtrl addObject:@"DP_R"];

    const float TH = 0.5f;
    GCControllerDirectionPad *ls = gp.leftThumbstick;
    if (ls.yAxis.value >  TH) [_heldCtrl addObject:@"LS_U"];
    if (ls.yAxis.value < -TH) [_heldCtrl addObject:@"LS_D"];
    if (ls.xAxis.value < -TH) [_heldCtrl addObject:@"LS_L"];
    if (ls.xAxis.value >  TH) [_heldCtrl addObject:@"LS_R"];

    GCControllerDirectionPad *rs = gp.rightThumbstick;
    if (rs.yAxis.value >  TH) [_heldCtrl addObject:@"RS_U"];
    if (rs.yAxis.value < -TH) [_heldCtrl addObject:@"RS_D"];
    if (rs.xAxis.value < -TH) [_heldCtrl addObject:@"RS_L"];
    if (rs.xAxis.value >  TH) [_heldCtrl addObject:@"RS_R"];
}

// ---- Resolve held inputs → actions → guest keys ---------------------------

// All actions currently active given the held keyboard/controller inputs. A binding is
// active when every one of its tokens is held (supports multi-key combos).
- (NSSet<NSNumber *> *)activeActions {
    NSMutableSet<NSNumber *> *active = [NSMutableSet set];

    for (NSDictionary *b in _kbBindings) {
        BOOL all = YES;
        for (NSNumber *k in b[@"keys"]) {
            if (![_heldKeys containsObject:k]) { all = NO; break; }
        }
        if (all && [b[@"keys"] count] > 0) [active addObject:b[@"action"]];
    }
    for (NSDictionary *b in _ctrlBindings) {
        BOOL all = YES;
        for (NSString *t in b[@"tokens"]) {
            if (![_heldCtrl containsObject:t]) { all = NO; break; }
        }
        if (all && [b[@"tokens"] count] > 0) [active addObject:b[@"action"]];
    }
    return active;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self recompute];
}

- (void)setMenuShown:(BOOL)menuShown {
    _menuShown = menuShown;
    [self recompute];
}

- (void)setAppsListShown:(BOOL)appsListShown {
    _appsListShown = appsListShown;
    [self recompute];
}

- (BOOL)action:(EKAAction)a newlyActiveIn:(NSSet<NSNumber *> *)now {
    return [now containsObject:@(a)] && ![_prevActive containsObject:@(a)];
}

- (void)recompute {
    BOOL uiNav = self.menuShown || self.appsListShown;
    NSSet<NSNumber *> *active = (self.enabled || uiNav) ? [self activeActions] : [NSSet set];

    if (uiNav) {
        // While a menu or the homescreen apps list is up, directions navigate it (move the
        // selection) and Fire confirms, instead of reaching the guest.
        [self releaseAll];
        if ([self action:EKAActionUp newlyActiveIn:active])    [self.delegate inputManagerDidNavigate:-1];
        if ([self action:EKAActionDown newlyActiveIn:active])  [self.delegate inputManagerDidNavigate:+1];
        if ([self action:EKAActionFire newlyActiveIn:active])  [self.delegate inputManagerDidNavigate:0];
        _prevActive = active;
        return;
    }

    // MENU action: open the in-game menu on the rising edge.
    if ([self action:EKAActionMenu newlyActiveIn:active]) {
        [self.delegate inputManagerDidRequestMenu];
    }

    // Desired scancodes = union of every active (non-menu) action's scancodes.
    NSMutableSet<NSNumber *> *desired = [NSMutableSet set];
    for (NSNumber *actNum in active) {
        for (NSNumber *sc in ScancodesForAction((EKAAction)actNum.integerValue)) {
            [desired addObject:sc];
        }
    }

    // Press newly-desired scancodes, release no-longer-desired ones.
    for (NSNumber *sc in desired) {
        if (![_pressed containsObject:sc]) {
            eka2l1::ios::bridge::key(sc.intValue, true);
        }
    }
    for (NSNumber *sc in [_pressed allObjects]) {
        if (![desired containsObject:sc]) {
            eka2l1::ios::bridge::key(sc.intValue, false);
        }
    }
    _pressed = [desired mutableCopy];
    _prevActive = active;
}

- (void)releaseAll {
    for (NSNumber *sc in [_pressed allObjects]) {
        eka2l1::ios::bridge::key(sc.intValue, false);
    }
    [_pressed removeAllObjects];
}

@end
