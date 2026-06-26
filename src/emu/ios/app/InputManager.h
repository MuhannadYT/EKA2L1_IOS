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

@protocol InputManagerDelegate <NSObject>
// The MENU action fired (controller Options/Start, keyboard Esc) — open the in-game menu.
- (void)inputManagerDidRequestMenu;
// Directional / confirm navigation for the in-game menu OR the homescreen apps list while it is
// shown (controller dpad + A / keyboard arrows + Enter). dir: -1 = up/previous, +1 = down/next,
// 0 = confirm.
- (void)inputManagerDidNavigate:(NSInteger)dir;
@end

// Hardware keyboard + game-controller input (GameController framework). Translates physical
// keys / controller buttons to Symbian key scancodes via a binding table and forwards them to
// the emulator (works regardless of the on-screen touch layout, including "None"). When a
// menu is shown, directional input drives menu navigation instead of the guest.
@interface InputManager : NSObject
@property (nonatomic, weak) id<InputManagerDelegate> delegate;
@property (nonatomic, assign) BOOL enabled;       // forward gameplay input to the guest only when YES
@property (nonatomic, assign) BOOL menuShown;      // when YES, directions drive menu navigation
@property (nonatomic, assign) BOOL appsListShown;  // when YES, directions drive homescreen apps-list navigation
- (void)startObserving;
// Reload the binding tables (global + per-game override) for the given uid. uid 0 = global only.
- (void)reloadBindingsForUid:(uint32_t)uid;
// Feed a hardware-keyboard key from the UIKit responder chain (UIKey.keyCode, which shares the
// GCKeyCode/USB-HID numeric space). Returns YES if the key is bound (so the caller consumes it).
- (BOOL)handleKeyCode:(NSInteger)hidUsage down:(BOOL)down;
@end

NS_ASSUME_NONNULL_END
