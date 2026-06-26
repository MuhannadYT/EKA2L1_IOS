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

// Emulator input actions. Cardinals map to one Symbian scancode; diagonals to two; MENU is a
// UI action (open the in-game menu). The on-screen layout, hardware keyboard and game
// controller all resolve to these.
typedef NS_ENUM(NSInteger, EKAAction) {
    EKAActionUp = 0,
    EKAActionDown,
    EKAActionLeft,
    EKAActionRight,
    EKAActionUpLeft,
    EKAActionUpRight,
    EKAActionDownLeft,
    EKAActionDownRight,
    EKAActionFire,
    EKAActionSoftLeft,
    EKAActionSoftRight,
    EKAActionMenu,
    EKAActionAKey,    // N-Gage helper: sends keypad #. Appended so saved keybind files stay compatible.
    EKAActionBKey,    // N-Gage helper: sends keypad *.
    EKAActionCount
};

// Display name for an action (used by the keybind editor and viewers).
NSString *EKAActionName(EKAAction action);

// Per-action binding model (JSON-serializable, the editor's working format):
//   { "<actionInt>": { "kb":   [ [hidCode,...], ... up to 2 slots ],
//                       "ctrl": [ ["TOKEN",...], ... up to 3 slots ] } }
// A "slot" is a combo: every key/token in it must be held for the binding to fire. Keyboard
// codes share the GCKeyCode / USB-HID numeric space; controller tokens are A, L1, R1, MENU,
// DP_U/D/L/R, LS_U/D/L/R, RS_U/D/L/R (see InputManager).
//
// Bindings are stored globally (keybinds.json) and optionally per-game (game_settings/
// <UID>_keybinds.json). A per-game file fully overrides the global set for that game.
@interface KeybindStore : NSObject

// Max slots the editor exposes per action.
+ (NSInteger)maxKeyboardSlots;      // 2
+ (NSInteger)maxControllerSlots;    // 3

// The built-in default bindings (user spec).
+ (NSMutableDictionary *)defaultModel;

// Effective model used at runtime: per-game if one exists, else the global model.
+ (NSMutableDictionary *)effectiveModelForUid:(uint32_t)uid;
// Model to edit for the given scope (uid 0 = global). Per-game editing starts from any existing
// per-game file, else a copy of the global model.
+ (NSMutableDictionary *)editingModelForUid:(uint32_t)uid;
+ (BOOL)hasGameOverrideForUid:(uint32_t)uid;

// Persist the edited model for the scope. uid 0 → global (keybinds.json); else per-game file.
+ (void)saveModel:(NSDictionary *)model forUid:(uint32_t)uid;
// Reset: uid 0 → global back to defaults; else remove the per-game override (revert to global).
+ (void)resetForUid:(uint32_t)uid;

// Flattened binding lists consumed by InputManager (effective model for the uid).
//   keyboard:   { @"keys":   NSArray<NSNumber*>, @"action": @(EKAAction) }
//   controller: { @"tokens": NSArray<NSString*>, @"action": @(EKAAction) }
+ (NSArray<NSDictionary *> *)keyboardBindingsForUid:(uint32_t)uid;
+ (NSArray<NSDictionary *> *)controllerBindingsForUid:(uint32_t)uid;

// Display helpers.
+ (NSString *)keyNameForCode:(NSInteger)hidCode;
+ (NSString *)controllerNameForToken:(NSString *)token;
+ (NSString *)keyComboName:(NSArray<NSNumber *> *)codes;        // "" when empty
+ (NSString *)controllerComboName:(NSArray<NSString *> *)tokens;// "" when empty

@end

NS_ASSUME_NONNULL_END
