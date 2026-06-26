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
#import "GameSettingsViewController.h"
#import "GameSettingsStore.h"
#import "KeybindEditorViewController.h"
#import "LayoutEditorViewController.h"

// Section / row layout.
typedef NS_ENUM(NSInteger, EKASection) {
    EKASectionSystem = 0,   // Refresh rate
    EKASectionScreen,       // Gravity (portrait/landscape), opacity
    EKASectionKeyLayout,    // On-screen layout + editors (later phases)
    EKASectionReset,        // Reset to default
    EKASectionCount
};

static NSArray<NSString *> *EKAGravityNames(void) {
    // Indexed by EKAScreenGravity (0=Left,1=Top,2=Center,3=Right,4=Bottom).
    return @[@"Left", @"Top", @"Center", @"Right", @"Bottom"];
}

@interface GameSettingsViewController () <UITextFieldDelegate>
@end

@implementation GameSettingsViewController {
    uint32_t _uid;
    NSString *_name;
    EKAGameSettings *_settings;
    UITextField *_fpsField;
    UISlider *_opacitySlider;
}

- (instancetype)initWithUid:(uint32_t)uid name:(NSString *)name {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _uid = uid;
        _name = name ?: @"Game";
        _settings = [GameSettingsStore settingsForUid:uid];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _name;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(onDone)];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)persistAndNotify {
    [GameSettingsStore saveSettings:_settings forUid:_uid];
    [self.settingsDelegate gameSettingsDidChangeForUid:_uid];
}

// ---- Table structure ------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return EKASectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case EKASectionSystem:    return 1;   // Refresh rate
        case EKASectionScreen:    return 8;   // gravity P/L, hide island, opacity, status, auto-scale, render scale, shader
        case EKASectionKeyLayout: return 7;   // Layout + haptics + 3 editor entries + gyro + haptic passthrough
        case EKASectionReset:     return 1;
        default:                  return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case EKASectionSystem:    return @"System Properties";
        case EKASectionScreen:    return @"Screen Options";
        case EKASectionKeyLayout: return @"Key Layout";
        default:                  return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == EKASectionKeyLayout) {
        return @"These settings apply only to this game.";
    }
    return nil;
}

- (NSString *)layoutName:(NSInteger)layout {
    if (layout == 0) return @"None";
    if (layout == 5) return @"Layout 1.5 (#/*)";
    if (layout == 6) return @"Joystick";
    return [NSString stringWithFormat:@"Layout %ld", (long)layout];
}

// On-screen-layout choices in display order (5 = "Layout 1.5 (#/*)" sits between 1 and 2;
// 6 = "Joystick" follows it).
+ (NSArray<NSNumber *> *)layoutOrder {
    return @[@0, @1, @5, @6, @2, @3, @4];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (indexPath.section) {
        case EKASectionSystem: {
            cell.textLabel.text = @"Refresh rate";
            if (!_fpsField) {
                _fpsField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 90, 30)];
                _fpsField.borderStyle = UITextBorderStyleRoundedRect;
                _fpsField.textAlignment = NSTextAlignmentRight;
                _fpsField.keyboardType = UIKeyboardTypeNumberPad;
                _fpsField.placeholder = @"60";
                _fpsField.delegate = self;
                _fpsField.font = [UIFont systemFontOfSize:16];
                // numberPad has no return key — add a Done toolbar to commit/dismiss.
                UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
                UIBarButtonItem *flex = [[UIBarButtonItem alloc]
                    initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
                UIBarButtonItem *done = [[UIBarButtonItem alloc]
                    initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(commitFps)];
                bar.items = @[flex, done];
                [bar sizeToFit];
                _fpsField.inputAccessoryView = bar;
            }
            _fpsField.text = [NSString stringWithFormat:@"%ld", (long)_settings.refreshRate];
            cell.accessoryView = _fpsField;
            break;
        }
        case EKASectionScreen: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Gravity (Portrait)";
                cell.detailTextLabel.text = EKAGravityNames()[_settings.gravityPortrait];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Gravity (Landscape)";
                cell.detailTextLabel.text = EKAGravityNames()[_settings.gravityLandscape];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"Hide Dynamic Island";
                cell.detailTextLabel.text = nil;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = _settings.hideDynamicIsland;
                [sw addTarget:self action:@selector(onHideIslandChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            } else if (indexPath.row == 3) {
                cell.textLabel.text = @"Overlay opacity";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%", (int)(_settings.controlsOpacity * 100 + 0.5)];
                if (!_opacitySlider) {
                    _opacitySlider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 140, 30)];
                    _opacitySlider.minimumValue = 0.2;
                    _opacitySlider.maximumValue = 1.0;
                    [_opacitySlider addTarget:self action:@selector(onOpacityChanged:) forControlEvents:UIControlEventValueChanged];
                }
                _opacitySlider.value = _settings.controlsOpacity;
                cell.accessoryView = _opacitySlider;
            } else if (indexPath.row == 4) {
                cell.textLabel.text = @"Status";
                cell.detailTextLabel.text = @"FPS + speed";
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = _settings.showStatus;
                [sw addTarget:self action:@selector(onShowStatusChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            } else if (indexPath.row == 5) {
                cell.textLabel.text = @"Auto Scale Buttons";
                cell.detailTextLabel.text = [self autoScaleStateName];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (indexPath.row == 6) {
                cell.textLabel.text = @"Render Resolution";
                cell.detailTextLabel.text = [self renderScaleName];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else {
                cell.textLabel.text = @"Upscale Shader";
                cell.detailTextLabel.text = [self filterShaderName];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            break;
        }
        case EKASectionKeyLayout: {
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (indexPath.row == 0) {
                cell.textLabel.text = @"On-screen layout";
                cell.detailTextLabel.text = [self layoutName:_settings.keyLayout];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Haptic Feedback";
                cell.detailTextLabel.text = nil;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = _settings.hapticFeedback;
                [sw addTarget:self action:@selector(onHapticChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"Edit Layout (Portrait)";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 3) {
                cell.textLabel.text = @"Edit Layout (Landscape)";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 4) {
                cell.textLabel.text = @"Per-game Keybinds";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 5) {
                cell.textLabel.text = @"Gyroscope Passthrough";
                cell.detailTextLabel.text = nil;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = _settings.gyroPassthrough;
                [sw addTarget:self action:@selector(onGyroChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            } else {
                cell.textLabel.text = @"Haptic Passthrough";
                cell.detailTextLabel.text = nil;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = _settings.hapticPassthrough;
                [sw addTarget:self action:@selector(onHapticPassthroughChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            }
            break;
        }
        case EKASectionReset: {
            cell.textLabel.text = @"Reset to Default";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
    }
    return cell;
}

// ---- Interaction ----------------------------------------------------------

// Done button on the numeric keypad: just dismiss; textFieldDidEndEditing commits.
- (void)commitFps {
    [_fpsField resignFirstResponder];
}

// Commit the typed value when focus leaves the field (Done, or tapping elsewhere).
- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSInteger v = [textField.text integerValue];
    if (v <= 0) {
        v = 60;   // empty / invalid → default
    }
    v = MAX(1, MIN(120, v));
    _settings.refreshRate = v;
    textField.text = [NSString stringWithFormat:@"%ld", (long)v];
    [self persistAndNotify];
}

- (void)onHideIslandChanged:(UISwitch *)sw {
    _settings.hideDynamicIsland = sw.on;
    [self persistAndNotify];
}

- (void)onShowStatusChanged:(UISwitch *)sw {
    _settings.showStatus = sw.on;
    [self persistAndNotify];
}

- (void)onHapticChanged:(UISwitch *)sw {
    _settings.hapticFeedback = sw.on;
    [self persistAndNotify];
}

- (void)onGyroChanged:(UISwitch *)sw {
    _settings.gyroPassthrough = sw.on;
    [self persistAndNotify];
}

- (void)onHapticPassthroughChanged:(UISwitch *)sw {
    _settings.hapticPassthrough = sw.on;
    [self persistAndNotify];
}

// Auto-scale enable state across orientations → a single display string.
- (NSString *)autoScaleStateName {
    BOOL p = _settings.autoScalePortrait, l = _settings.autoScaleLandscape;
    if (p && l) return @"Both";
    if (p && !l) return @"Portrait only";
    if (!p && l) return @"Landscape only";
    return @"Off";
}

- (void)pickAutoScaleFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Auto Scale Buttons"
        message:@"Shrink the on-screen controls so they don't cover the game when it fills more of the screen."
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *names = @[@"Both", @"Portrait only", @"Landscape only", @"Off"];
    NSString *current = [self autoScaleStateName];
    for (NSString *name in names) {
        NSString *t = [name isEqualToString:current] ? [name stringByAppendingString:@"  ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                _settings.autoScalePortrait  = [name isEqualToString:@"Both"] || [name isEqualToString:@"Portrait only"];
                _settings.autoScaleLandscape = [name isEqualToString:@"Both"] || [name isEqualToString:@"Landscape only"];
                [self persistAndNotify];
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:5 inSection:EKASectionScreen]]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Render-scale choices. 0 = Native (the device's own scale = 3x here) — the default. The Symbian guest
// is low-res so it's upscaled either way; lower scales just fill fewer pixels (a big win on the sim's
// software GL), they don't really change sharpness.
static NSArray<NSNumber *> *EKARenderScales(void) { return @[@0.0, @0.5, @1.0, @1.5, @2.0, @3.0]; }

- (NSString *)renderScaleLabelFor:(double)v {
    if (v <= 0.0)  return @"Native";
    if (v <= 0.75) return @"0.5x (Fastest)";
    if (v <= 1.25) return @"1x";
    if (v <= 1.75) return @"1.5x";
    if (v <= 2.5)  return @"2x";
    return @"3x";
}

- (NSString *)renderScaleName {
    return [self renderScaleLabelFor:_settings.renderScale];
}

- (void)pickRenderScaleFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Render Resolution"
        message:@"Internal render scale. Native matches the screen; lower = faster. The guest is "
                 "low-res, so lower scales rarely lose detail."
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = [self renderScaleName];
    for (NSNumber *scale in EKARenderScales()) {
        NSString *name = [self renderScaleLabelFor:scale.doubleValue];
        NSString *t = [name isEqualToString:current] ? [name stringByAppendingString:@"  ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                _settings.renderScale = scale.doubleValue;
                [self persistAndNotify];
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:6 inSection:EKASectionScreen]]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Upscale/filter shaders. Each entry is @[display name, shader value] where "" = OFF (the default).
// The value maps to a bundled resources/upscale/<value>.frag consumed by the core's filter_shader_path.
static NSArray<NSArray<NSString *> *> *EKAFilterShaders(void) {
    return @[@[@"Off", @""],
             @[@"Sharpen", @"sharpen"],
             @[@"Natural", @"natural"],
             @[@"FXAA (Anti-alias)", @"fxaa"],
             @[@"AA Color", @"aacolor"],
             @[@"2xBR", @"2xBR"],
             @[@"4xBR", @"4xBR"],
             @[@"5xBR", @"5xBR"],
             @[@"4xHQ", @"4xhq"],
             @[@"CRT - Lottes", @"CRT-Lottes"],
             @[@"CRT - Hyllian", @"CRT-Hyllian"],
             @[@"Scanline", @"scanline"],
             @[@"LCD Grid", @"zfast_lcd"],
             @[@"Dot Matrix", @"dot"],
             @[@"Grayscale", @"grayscale"],
             @[@"Inverse Colors", @"inversecolors"]];
}

- (NSString *)filterShaderName {
    NSString *cur = _settings.filterShader ?: @"";
    for (NSArray<NSString *> *e in EKAFilterShaders()) {
        if ([e[1] isEqualToString:cur]) return e[0];
    }
    return cur.length ? cur : @"Off";   // unknown custom value: show it verbatim
}

- (void)pickFilterShaderFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Upscale Shader"
        message:@"A post-process filter applied when scaling the game to the screen. Off by default. "
                 "Some shaders (CRT/xBR) cost GPU."
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *cur = _settings.filterShader ?: @"";
    for (NSArray<NSString *> *e in EKAFilterShaders()) {
        NSString *t = [e[1] isEqualToString:cur] ? [e[0] stringByAppendingString:@"  ✓"] : e[0];
        NSString *value = e[1];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                _settings.filterShader = value;
                [self persistAndNotify];
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:7 inSection:EKASectionScreen]]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onOpacityChanged:(UISlider *)slider {
    _settings.controlsOpacity = slider.value;
    [self persistAndNotify];
    // Update just the detail text without rebuilding the slider (so dragging stays smooth).
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:EKASectionScreen]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%", (int)(_settings.controlsOpacity * 100 + 0.5)];
}

- (void)pickGravityForPortrait:(BOOL)portrait fromCell:(UITableViewCell *)cell {
    NSString *title = portrait ? @"Gravity (Portrait)" : @"Gravity (Landscape)";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *names = EKAGravityNames();
    NSInteger current = portrait ? _settings.gravityPortrait : _settings.gravityLandscape;
    for (NSInteger g = 0; g < (NSInteger)names.count; g++) {
        NSString *t = (g == current) ? [names[g] stringByAppendingString:@"  ✓"] : names[g];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                if (portrait) { _settings.gravityPortrait = (EKAScreenGravity)g; }
                else          { _settings.gravityLandscape = (EKAScreenGravity)g; }
                [self persistAndNotify];
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:EKASectionScreen]
                              withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickLayoutFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"On-screen layout" message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *num in [GameSettingsViewController layoutOrder]) {
        NSInteger i = num.integerValue;
        NSString *base = [self layoutName:i];
        NSString *t = (i == _settings.keyLayout) ? [base stringByAppendingString:@"  ✓"] : base;
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                _settings.keyLayout = i;
                [self persistAndNotify];
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:EKASectionKeyLayout]]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openLayoutEditorPortrait:(BOOL)portrait {
    LayoutEditorViewController *vc = [[LayoutEditorViewController alloc] initWithUid:_uid name:_name portrait:portrait
        onChange:^{ [self.settingsDelegate gameSettingsDidChangeForUid:self->_uid]; }];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openPerGameKeybinds {
    KeybindEditorViewController *vc = [[KeybindEditorViewController alloc] initWithUid:_uid scopeName:_name
        onChange:^{ [self.settingsDelegate gameSettingsDidChangeForUid:self->_uid]; }];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showComingSoon:(NSString *)feature {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:feature
        message:@"This is coming in a later update."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset to Default"
        message:@"Restore this game's settings to their defaults?"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            self->_settings = [[EKAGameSettings alloc] init];
            [self persistAndNotify];
            [self.tableView reloadData];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    if (indexPath.section == EKASectionScreen) {
        if (indexPath.row == 0)      [self pickGravityForPortrait:YES fromCell:cell];
        else if (indexPath.row == 1) [self pickGravityForPortrait:NO fromCell:cell];
        else if (indexPath.row == 5) [self pickAutoScaleFromCell:cell];
        else if (indexPath.row == 6) [self pickRenderScaleFromCell:cell];
        else if (indexPath.row == 7) [self pickFilterShaderFromCell:cell];
    } else if (indexPath.section == EKASectionKeyLayout) {
        if (indexPath.row == 0)      [self pickLayoutFromCell:cell];
        else if (indexPath.row == 1) { /* Haptic Feedback — the switch handles it */ }
        else if (indexPath.row == 2) [self openLayoutEditorPortrait:YES];
        else if (indexPath.row == 3) [self openLayoutEditorPortrait:NO];
        else if (indexPath.row == 4) [self openPerGameKeybinds];
        else if (indexPath.row == 5) { /* Gyroscope Passthrough — the switch handles it */ }
        else                         { /* Haptic Passthrough — the switch handles it */ }
    } else if (indexPath.section == EKASectionReset) {
        [self confirmReset];
    }
}

@end
