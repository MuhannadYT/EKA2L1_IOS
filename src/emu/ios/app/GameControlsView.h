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
#import <UIKit/UIKit.h>

@class GameControlsView;

@protocol GameControlsEditingDelegate <NSObject>
// Fired while editing whenever an element is moved/scaled/added/removed or the selection changes.
- (void)gameControlsDidChange:(GameControlsView *)view;
@end

// On-screen touch controls overlay. Renders virtual keys for a given layout and sends
// Symbian key scancodes to the emulator. The four built-in layouts mirror the Android
// frontend's VirtualKeyboard variants (remapped per the user's requested ordering):
//   layout 1 -> centred gaming D-pad with FIRE in the middle + L/R softkeys, no digits
//   layout 5 -> "Layout 1.5 (#/*)": layout 1 plus extra # and * buttons for N-Gage remaps
//   layout 2 -> Android variant 3 (numeric keypad + softkeys, no D-pad)
//   layout 3 -> Android variant 0 (D-pad right, keypad left, fire + softkeys)
//   layout 4 -> Android variant 1 (D-pad left, keypad right, fire + softkeys)
// layout 0 = None (overlay hidden).
//
// A per-game CUSTOM layout (see customLayout) overrides the built-in one: a list of normalized
// element dictionaries that the user arranges in the layout editor. Each element is:
//   { @"type": @"dpad" | @"key", @"codes": NSArray<NSNumber*> (key only),
//     @"label": NSString (key only), @"cx": @(0..1), @"cy": @(0..1), @"size": @(0..1 of min(W,H)) }
@interface GameControlsView : UIView
@property (nonatomic, assign) NSInteger layout;       // 0 = none, 1..4 (built-in)
@property (nonatomic, assign) CGFloat overlayOpacity; // 0..1, scales the drawn controls' alpha

// Haptic feedback: when YES, a short impact fires on every new key-down (button taps, slide-to-switch
// transitions and joystick direction changes). Off by default. No-op on devices without a Taptic Engine.
@property (nonatomic, assign) BOOL hapticsEnabled;

// "Auto scale buttons": when YES, the controls shrink to fit the empty space beside/below the
// emulated screen so they don't cover it. `guestRect` is the emulated screen's rectangle in this
// view's own coordinates; the frontend keeps it updated. CGRectZero = unknown → full size.
@property (nonatomic, assign) BOOL autoScaleButtons;
@property (nonatomic, assign) CGRect guestRect;

// Custom per-game layout. nil = use the built-in `layout`. Setting it makes the overlay
// data-driven. Stored/loaded as plain arrays of dictionaries (see above).
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *customLayout;

// ---- Layout-editor mode ----
@property (nonatomic, assign) BOOL editing;           // YES = drag/scale/select elements (no key output)
@property (nonatomic, weak) id<GameControlsEditingDelegate> editDelegate;
- (NSArray<NSDictionary *> *)currentLayout;            // snapshot of elements (for saving)
- (BOOL)hasSelection;
- (void)addKeyWithCodes:(NSArray<NSNumber *> *)codes label:(NSString *)label; // adds + selects at centre
- (void)addDpad;
- (void)addJoystick;
- (void)deleteSelected;
- (void)scaleSelectedBy:(CGFloat)factor;
- (void)scaleAllBy:(CGFloat)factor;
+ (NSArray<NSDictionary *> *)defaultCustomLayout;
// Editable approximation of a built-in `layout` (1..6) as normalized custom elements, so the
// layout editor can seed itself from the selected on-screen layout. Empty for 0 (None).
+ (NSArray<NSDictionary *> *)customLayoutForBuiltinLayout:(NSInteger)layout;
// Palette of addable elements for the editor: { @"label": NSString, @"codes": NSArray<NSNumber*>,
// @"dpad": @(BOOL) }. A "dpad" entry has empty codes.
+ (NSArray<NSDictionary *> *)buttonPalette;
@end
