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
#import "GameControlsView.h"

#include <ios/emu_bridge.h>

// Symbian key scancodes (mirror android Keycode.java).
enum {
    SC_NUM0 = '0', SC_NUM1 = '1', SC_NUM2 = '2', SC_NUM3 = '3', SC_NUM4 = '4',
    SC_NUM5 = '5', SC_NUM6 = '6', SC_NUM7 = '7', SC_NUM8 = '8', SC_NUM9 = '9',
    SC_STAR = '*', SC_POUND = 0x7F,
    SC_UP = 0x10, SC_DOWN = 0x11, SC_LEFT = 0x0E, SC_RIGHT = 0x0F,
    SC_FIRE = 0xA7, SC_SOFT_LEFT = 0xA4, SC_SOFT_RIGHT = 0xA5
};

// ---- Built-in -> editable custom-layout conversion ------------------------
// Normalized element builders (cx/cy are fractions of width/height, size of min(W,H)). Used by
// +customLayoutForBuiltinLayout: to render a built-in layout as editable custom elements.
static NSDictionary *EKAKeyEl(int code, NSString *label, CGFloat cx, CGFloat cy, CGFloat size) {
    return @{ @"type": @"key", @"codes": @[@(code)], @"label": label,
              @"cx": @(cx), @"cy": @(cy), @"size": @(size) };
}
static NSDictionary *EKADpadEl(CGFloat cx, CGFloat cy, CGFloat size) {
    return @{ @"type": @"dpad", @"cx": @(cx), @"cy": @(cy), @"size": @(size) };
}
static NSDictionary *EKAJoyEl(CGFloat cx, CGFloat cy, CGFloat size) {
    return @{ @"type": @"joystick", @"cx": @(cx), @"cy": @(cy), @"size": @(size) };
}
// Append a phone keypad (1-9, *, 0, #) as a 3x4 grid whose top-left key centre is (left,top).
static void EKAAppendNumpad(NSMutableArray *out, CGFloat left, CGFloat top,
                            CGFloat colStep, CGFloat rowStep, CGFloat size) {
    int codes[12] = { SC_NUM1, SC_NUM2, SC_NUM3, SC_NUM4, SC_NUM5, SC_NUM6,
                      SC_NUM7, SC_NUM8, SC_NUM9, SC_STAR, SC_NUM0, SC_POUND };
    NSArray *labels = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"*", @"0", @"#"];
    for (int i = 0; i < 12; i++) {
        [out addObject:EKAKeyEl(codes[i], labels[i], left + (i % 3) * colStep, top + (i / 3) * rowStep, size)];
    }
}

@implementation GameControlsView {
    NSMutableArray<NSDictionary *> *_controls;  // {codes:[NSNumber], label:NSString, rect:NSValue}
    NSMapTable<UITouch *, NSNumber *> *_touchToControl;
    NSCountedSet<NSNumber *> *_held;             // refcount of held scancodes

    // Custom-layout / editor state.
    NSMutableArray<NSMutableDictionary *> *_elements;  // nil = use built-in `_layout`
    NSInteger _selectedIndex;
    UIPanGestureRecognizer *_pan;
    UIPinchGestureRecognizer *_pinch;
    UITapGestureRecognizer *_tap;
    NSInteger _dragIndex;
    CGPoint _dragStartCenter;       // element's normalized centre at pan start
    CGFloat _pinchBaseSize;         // element's size at pinch start

    CGFloat _appliedScale;          // cached auto-scale factor for the current build

    // Analog joystick (layout 6) state.
    UITouch *_joyTouch;             // the touch currently driving the stick (nil = idle)
    CGPoint _joyCenter;             // base centre in view coords
    CGFloat _joyRadius;             // base radius
    CGPoint _joyThumb;              // thumb offset from centre (points)
    NSArray<NSNumber *> *_joyCodes; // direction scancodes currently held by the stick

    UIImpactFeedbackGenerator *_haptic;  // lazily created when hapticsEnabled fires
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        self.opaque = NO;
        _controls = [NSMutableArray array];
        _touchToControl = [NSMapTable weakToStrongObjectsMapTable];
        _held = [NSCountedSet set];
        _layout = 0;
        _overlayOpacity = 1.0;
        _autoScaleButtons = NO;
        _guestRect = CGRectZero;       // unknown until the guest draws → full-size buttons
        _appliedScale = 1.0;
        _elements = nil;
        _selectedIndex = -1;
        _dragIndex = -1;
    }
    return self;
}

- (void)updateVisibility {
    self.hidden = !self.editing && (_elements == nil) && (_layout == 0);
}

- (void)setOverlayOpacity:(CGFloat)overlayOpacity {
    _overlayOpacity = MAX(0.0, MIN(1.0, overlayOpacity));
    [self setNeedsDisplay];
}

- (void)setAutoScaleButtons:(BOOL)autoScaleButtons {
    if (_autoScaleButtons == autoScaleButtons) return;
    _autoScaleButtons = autoScaleButtons;
    [self rebuildControls];
    [self setNeedsDisplay];
}

- (void)setGuestRect:(CGRect)guestRect {
    if (CGRectEqualToRect(_guestRect, guestRect)) return;
    _guestRect = guestRect;
    if (_autoScaleButtons) {
        [self rebuildControls];
        [self setNeedsDisplay];
    }
}

// Factor (≤1) applied to every control's size when "auto scale" is on, so the controls fit the
// empty band beside (landscape) or below (portrait) the emulated screen instead of covering it.
// Computed from `guestRect` and the controls' natural inward reach at full size.
- (CGFloat)computeAutoScale {
    if (!_autoScaleButtons || self.editing) return 1.0;
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W <= 0 || H <= 0 || _guestRect.size.width <= 0 || _guestRect.size.height <= 0) return 1.0;

    const CGFloat margin = 10, gap = 6, kMin = 0.35;
    const CGFloat dpadW = MIN(W * 0.5, 210);
    const CGFloat npW = MIN(W * 0.46, 200), npH = npW * 4.0 / 3.0;

    // Natural inward reach of the controls at full size: reachH from a side edge (landscape),
    // reachV up from the bottom edge (portrait).
    CGFloat reachH = 0, reachV = 0;
    if (_elements) {
        CGFloat minX = W, maxX = 0, minY = H;
        for (NSDictionary *el in _elements) {
            CGFloat side = [el[@"size"] floatValue] * MIN(W, H);
            CGFloat cx = [el[@"cx"] floatValue] * W, cy = [el[@"cy"] floatValue] * H;
            minX = MIN(minX, cx - side / 2); maxX = MAX(maxX, cx + side / 2);
            minY = MIN(minY, cy - side / 2);
        }
        reachH = MAX(maxX, W - minX);   // inward reach from whichever side is busier
        reachV = H - minY;              // upward reach from the bottom
    } else {
        switch (_layout) {
            case 1: case 5: case 6:               // D-pad / joystick + softkeys + (#/*)
                reachH = margin + dpadW;
                reachV = dpadW + 42 + 8;
                break;
            case 3: case 4:                        // D-pad one side, numpad the other
                reachH = margin + MAX(dpadW, npW);
                reachV = MAX(dpadW, npH) + 42 + 8;
                break;
            case 2:                                // centred numpad — only fits vertically
                reachV = MIN(H * 0.5, 320) + 42 + 8;
                break;
        }
    }

    BOOL landscape = W > H;
    if (landscape) {
        if (reachH <= 0) return 1.0;
        CGFloat bar = MIN(CGRectGetMinX(_guestRect), W - CGRectGetMaxX(_guestRect));
        return MAX(kMin, MIN(1.0, (bar - gap) / reachH));
    }
    if (reachV <= 0) return 1.0;
    CGFloat bottomBand = H - CGRectGetMaxY(_guestRect);
    return MAX(kMin, MIN(1.0, (bottomBand - gap) / reachV));
}

- (void)setLayout:(NSInteger)layout {
    // No-op on a redundant set. applyControls re-pushes the layout on every updateChrome (which a
    // layout pass triggers), and releaseAllHeld would drop the key the user is mid-press on — so a
    // held button/joystick would "lift itself" whenever anything relaid out. Only react to a real
    // change. (A genuine bounds/orientation change still rebuilds via layoutSubviews; switching to
    // or from a custom layout goes through setCustomLayout:, not here.)
    if (_layout == layout) {
        return;
    }
    _layout = layout;
    [self releaseAllHeld];
    [self rebuildControls];
    [self updateVisibility];
    [self setNeedsDisplay];
}

- (void)setCustomLayout:(NSArray<NSDictionary *> *)customLayout {
    // No-op when the custom layout is unchanged (same reason as setLayout: don't disturb held keys
    // on the redundant re-push that every layout pass / updateChrome does).
    if (_customLayout == customLayout || [_customLayout isEqualToArray:customLayout]) {
        return;
    }
    _customLayout = [customLayout copy];
    if (customLayout) {
        _elements = [NSMutableArray array];
        for (NSDictionary *el in customLayout) {
            [_elements addObject:[el mutableCopy]];
        }
    } else {
        _elements = nil;
    }
    _selectedIndex = -1;
    [self releaseAllHeld];
    [self rebuildControls];
    [self updateVisibility];
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self rebuildControls];
    [self setNeedsDisplay];
}

// ---- Control construction -------------------------------------------------

- (void)addControl:(NSArray<NSNumber *> *)codes label:(NSString *)label rect:(CGRect)rect {
    [_controls addObject:@{ @"codes": codes, @"label": label, @"rect": [NSValue valueWithCGRect:rect] }];
}

// 8-way D-pad as a 3x3 grid; corners send two keys (diagonals), edges one, centre empty.
- (void)addDpadInRect:(CGRect)area {
    CGFloat cw = area.size.width / 3.0;
    CGFloat ch = area.size.height / 3.0;
    NSArray *cells = @[
        @[@(SC_UP), @(SC_LEFT)],  @[@(SC_UP)],   @[@(SC_UP), @(SC_RIGHT)],
        @[@(SC_LEFT)],            @[],           @[@(SC_RIGHT)],
        @[@(SC_DOWN), @(SC_LEFT)],@[@(SC_DOWN)], @[@(SC_DOWN), @(SC_RIGHT)]
    ];
    NSArray *labels = @[@"↖", @"↑", @"↗", @"←", @"", @"→", @"↙", @"↓", @"↘"];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            NSArray *codes = cells[r * 3 + c];
            if (codes.count == 0) continue;
            CGRect cell = CGRectInset(CGRectMake(area.origin.x + c * cw, area.origin.y + r * ch, cw, ch), 3, 3);
            [self addControl:codes label:labels[r * 3 + c] rect:cell];
        }
    }
}

// Analog joystick occupying `area` (a square). Handled specially in touch/draw (not a tappable key).
- (void)addJoystickInRect:(CGRect)area {
    [_controls addObject:@{ @"joystick": @YES, @"rect": [NSValue valueWithCGRect:area] }];
}

// Phone keypad: rows 1-2-3 / 4-5-6 / 7-8-9 / *-0-#.
- (void)addNumpadInRect:(CGRect)area {
    NSArray *rows = @[ @[@(SC_NUM1),@"1"], @[@(SC_NUM2),@"2"], @[@(SC_NUM3),@"3"],
                       @[@(SC_NUM4),@"4"], @[@(SC_NUM5),@"5"], @[@(SC_NUM6),@"6"],
                       @[@(SC_NUM7),@"7"], @[@(SC_NUM8),@"8"], @[@(SC_NUM9),@"9"],
                       @[@(SC_STAR),@"*"], @[@(SC_NUM0),@"0"], @[@(SC_POUND),@"#"] ];
    CGFloat cw = area.size.width / 3.0;
    CGFloat ch = area.size.height / 4.0;
    for (int i = 0; i < 12; i++) {
        int r = i / 3, c = i % 3;
        CGRect cell = CGRectInset(CGRectMake(area.origin.x + c * cw, area.origin.y + r * ch, cw, ch), 3, 3);
        [self addControl:@[rows[i][0]] label:rows[i][1] rect:cell];
    }
}

- (CGRect)rectForElement:(NSDictionary *)el {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    CGFloat side = [el[@"size"] floatValue] * MIN(W, H) * _appliedScale;
    CGFloat cx = [el[@"cx"] floatValue] * W;
    CGFloat cy = [el[@"cy"] floatValue] * H;
    return CGRectMake(cx - side / 2, cy - side / 2, side, side);
}

- (void)rebuildControls {
    [_controls removeAllObjects];
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    if (W <= 0 || H <= 0) {
        return;
    }

    // Auto-scale factor for this build (1.0 unless "auto scale buttons" is on for this game).
    _appliedScale = [self computeAutoScale];

    // Custom (data-driven) layout overrides the built-in ones.
    if (_elements) {
        for (NSMutableDictionary *el in _elements) {
            CGRect r = [self rectForElement:el];
            if ([el[@"type"] isEqualToString:@"dpad"]) {
                [self addDpadInRect:r];
            } else if ([el[@"type"] isEqualToString:@"joystick"]) {
                [self addJoystickInRect:r];
            } else {
                [self addControl:el[@"codes"] label:el[@"label"] rect:r];
            }
        }
        return;
    }

    if (_layout == 0) {
        return;
    }

    // "Auto scale": shrink every control to fit beside/below the guest (see computeAutoScale).
    const CGFloat s = _appliedScale;
    const CGFloat margin = 10;
    const CGFloat softW = 78 * s, softH = 42 * s;
    const CGFloat fireD = 78 * s;
    const CGFloat bottom = H - margin;

    // Softkeys sit just above the home-indicator at the bottom corners for all layouts.
    CGFloat softY = bottom - softH;

    switch (_layout) {
        case 1: {  // D-pad centred, FIRE in the middle cell, softkeys above the top diagonals
            CGFloat dpad = MIN(W * 0.5, 210) * s;
            CGFloat dpadX = (W - dpad) / 2.0;            // centre the D-pad horizontally
            CGFloat dpadTop = bottom - dpad;
            [self addDpadInRect:CGRectMake(dpadX, dpadTop, dpad, dpad)];

            // FIRE occupies the (otherwise empty) centre cell of the D-pad.
            CGFloat cell = dpad / 3.0;
            [self addControl:@[@(SC_FIRE)] label:@"FIRE"
                        rect:CGRectInset(CGRectMake(dpadX + cell, dpadTop + cell, cell, cell), 3, 3)];

            // L / R sit just above the top-left (↖) and top-right (↗) diagonal arrows.
            CGFloat softY = dpadTop - softH - 8;
            CGFloat leftX = dpadX + (cell - softW) / 2.0;
            CGFloat rightX = dpadX + 2 * cell + (cell - softW) / 2.0;
            [self addControl:@[@(SC_SOFT_LEFT)] label:@"L" rect:CGRectMake(leftX, softY, softW, softH)];
            [self addControl:@[@(SC_SOFT_RIGHT)] label:@"R" rect:CGRectMake(rightX, softY, softW, softH)];
            break;
        }
        case 5: {  // "Layout 1.5 (#/*)": layout 1 + keypad # and * buttons for N-Gage remaps
            CGFloat dpad = MIN(W * 0.5, 210) * s;
            // Pin the whole D-pad cluster (L/R, arrows, FIRE) to the LEFT edge — mirroring the
            // #/* column hugging the right edge — on iPad (both orientations) and on iPhone in
            // landscape. iPhone-portrait keeps the cluster centred (the screen is too narrow to
            // benefit from left/right split).
            BOOL landscape = (W > H);
            BOOL pad = (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad);
            BOOL leftAlign = pad || landscape;
            CGFloat dpadX = leftAlign ? margin : (W - dpad) / 2.0;
            CGFloat dpadTop = bottom - dpad;
            [self addDpadInRect:CGRectMake(dpadX, dpadTop, dpad, dpad)];

            CGFloat cell = dpad / 3.0;
            [self addControl:@[@(SC_FIRE)] label:@"FIRE"
                        rect:CGRectInset(CGRectMake(dpadX + cell, dpadTop + cell, cell, cell), 3, 3)];

            CGFloat softYa = dpadTop - softH - 8;
            CGFloat leftX = dpadX + (cell - softW) / 2.0;
            CGFloat rightX = dpadX + 2 * cell + (cell - softW) / 2.0;
            [self addControl:@[@(SC_SOFT_LEFT)] label:@"L" rect:CGRectMake(leftX, softYa, softW, softH)];
            [self addControl:@[@(SC_SOFT_RIGHT)] label:@"R" rect:CGRectMake(rightX, softYa, softW, softH)];

            // Extra keypad # and * buttons stacked to the right of the D-pad. These use the same
            // scancodes as the regular phone keypad buttons, matching Android's overlay.
            CGFloat aD = MIN(70 * s, (W - dpad) / 2.0 - margin);
            if (aD >= 34) {
                CGFloat aX = W - margin - aD;
                CGFloat midY = dpadTop + dpad / 2.0;
                [self addControl:@[@(SC_POUND)] label:@"#" rect:CGRectMake(aX, midY - aD - 5, aD, aD)];
                [self addControl:@[@(SC_STAR)] label:@"*" rect:CGRectMake(aX, midY + 5, aD, aD)];
            }
            break;
        }
        case 6: {  // Joystick: analog stick bottom-left, FIRE + #/* bottom-right, L above stick, R above #/*
            CGFloat joyD = MIN(W * 0.42, 200) * s;
            CGFloat joyX = margin;
            CGFloat joyTop = bottom - joyD;
            [self addJoystickInRect:CGRectMake(joyX, joyTop, joyD, joyD)];

            // L sits just above the joystick (left); R mirrors it on the right at the same height.
            CGFloat softYj = joyTop - softH - 8;
            CGFloat lX = MAX(margin, joyX + (joyD - softW) / 2.0);
            [self addControl:@[@(SC_SOFT_LEFT)] label:@"L" rect:CGRectMake(lX, softYj, softW, softH)];
            [self addControl:@[@(SC_SOFT_RIGHT)] label:@"R" rect:CGRectMake(W - margin - softW, softYj, softW, softH)];

            // Right side: # and * stacked at the right edge (# above *), FIRE to their left.
            CGFloat aD = MIN(70 * s, W * 0.5 - margin);
            CGFloat aX = W - margin - aD;
            [self addControl:@[@(SC_POUND)] label:@"#" rect:CGRectMake(aX, bottom - 2 * aD - 6, aD, aD)];
            [self addControl:@[@(SC_STAR)]  label:@"*" rect:CGRectMake(aX, bottom - aD, aD, aD)];

            CGFloat fireDj = 84 * s;
            CGFloat fireX = aX - 10 - fireDj;
            [self addControl:@[@(SC_FIRE)] label:@"FIRE" rect:CGRectMake(fireX, bottom - fireDj, fireDj, fireDj)];
            break;
        }
        case 2: {  // Android variant 3: numeric keypad + softkeys, no D-pad
            CGFloat npW = MIN(W - 2 * margin, 270) * s;
            CGFloat npH = MIN(H * 0.5, 320) * s;
            CGFloat npX = (W - npW) / 2.0;
            [self addNumpadInRect:CGRectMake(npX, bottom - npH, npW, npH)];
            [self addControl:@[@(SC_SOFT_LEFT)] label:@"L" rect:CGRectMake(margin, bottom - npH - softH - 8, softW, softH)];
            [self addControl:@[@(SC_SOFT_RIGHT)] label:@"R" rect:CGRectMake(W - margin - softW, bottom - npH - softH - 8, softW, softH)];
            break;
        }
        case 3:    // Android variant 0: D-pad right, keypad left
        case 4: {  // Android variant 1: D-pad left, keypad right
            BOOL dpadRight = (_layout == 3);
            CGFloat dpad = MIN(W * 0.42, 180) * s;
            CGFloat npW = MIN(W * 0.46, 200) * s;
            CGFloat npH = npW * 4.0 / 3.0;
            CGFloat dpadX = dpadRight ? (W - margin - dpad) : margin;
            CGFloat npX = dpadRight ? margin : (W - margin - npW);
            [self addDpadInRect:CGRectMake(dpadX, bottom - dpad, dpad, dpad)];
            [self addNumpadInRect:CGRectMake(npX, bottom - npH, npW, npH)];
            CGFloat fireX = dpadRight ? (W - margin - dpad - fireD - 6) : (margin + dpad + 6);
            [self addControl:@[@(SC_FIRE)] label:@"F" rect:CGRectMake(fireX, bottom - fireD, fireD, fireD)];
            [self addControl:@[@(SC_SOFT_LEFT)] label:@"L" rect:CGRectMake(margin, softY - MAX(dpad, npH) - 8, softW, softH)];
            [self addControl:@[@(SC_SOFT_RIGHT)] label:@"R" rect:CGRectMake(W - margin - softW, softY - MAX(dpad, npH) - 8, softW, softH)];
            break;
        }
    }
}

// ---- Drawing --------------------------------------------------------------

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIFont *font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    const CGFloat op = _overlayOpacity;

    for (NSDictionary *ctrl in _controls) {
        CGRect r = [ctrl[@"rect"] CGRectValue];
        if (ctrl[@"joystick"]) {
            [self drawJoystickInRect:r ctx:ctx op:op];
            continue;
        }
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10];
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.16 * op].CGColor);
        CGContextAddPath(ctx, path.CGPath); CGContextFillPath(ctx);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.5 * op].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextAddPath(ctx, path.CGPath); CGContextStrokePath(ctx);

        NSString *label = ctrl[@"label"];
        if (label.length) {
            NSDictionary *attrs = @{ NSFontAttributeName: font,
                                     NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85 * op] };
            CGSize sz = [label sizeWithAttributes:attrs];
            [label drawAtPoint:CGPointMake(r.origin.x + (r.size.width - sz.width) / 2,
                                           r.origin.y + (r.size.height - sz.height) / 2)
                withAttributes:attrs];
        }
    }

    // Editor overlay: outline each element; highlight + handle the selected one.
    if (self.editing && _elements) {
        for (NSInteger i = 0; i < (NSInteger)_elements.count; i++) {
            CGRect r = [self rectForElement:_elements[i]];
            BOOL sel = (i == _selectedIndex);
            UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10];
            CGContextSetStrokeColorWithColor(ctx, (sel ? [UIColor systemYellowColor]
                                                       : [UIColor colorWithWhite:1.0 alpha:0.9]).CGColor);
            CGContextSetLineWidth(ctx, sel ? 3.0 : 1.5);
            if (!sel) {
                CGFloat dash[] = { 6, 4 };
                CGContextSetLineDash(ctx, 0, dash, 2);
            } else {
                CGContextSetLineDash(ctx, 0, NULL, 0);
            }
            CGContextAddPath(ctx, box.CGPath); CGContextStrokePath(ctx);
            CGContextSetLineDash(ctx, 0, NULL, 0);
            if (sel) {
                CGRect handle = CGRectMake(CGRectGetMaxX(r) - 11, CGRectGetMaxY(r) - 11, 22, 22);
                CGContextSetFillColorWithColor(ctx, [UIColor systemYellowColor].CGColor);
                CGContextFillEllipseInRect(ctx, handle);
            }
        }
    }
}

// Analog stick: a ring (base) plus a filled thumb offset by the current input.
- (void)drawJoystickInRect:(CGRect)r ctx:(CGContextRef)ctx op:(CGFloat)op {
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.10 * op].CGColor);
    CGContextFillEllipseInRect(ctx, r);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.5 * op].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, r);

    CGFloat thumbR = r.size.width * 0.30;
    CGPoint c = CGPointMake(CGRectGetMidX(r) + _joyThumb.x, CGRectGetMidY(r) + _joyThumb.y);
    CGRect tr = CGRectMake(c.x - thumbR, c.y - thumbR, thumbR * 2, thumbR * 2);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.28 * op].CGColor);
    CGContextFillEllipseInRect(ctx, tr);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.75 * op].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, tr);
}

// Map the stick's thumb offset to held D-pad scancodes (8-way via two axes + a dead zone).
- (void)updateJoystickToPoint:(CGPoint)p {
    CGFloat dx = p.x - _joyCenter.x;
    CGFloat dy = p.y - _joyCenter.y;
    CGFloat dist = hypot(dx, dy);
    if (dist > _joyRadius && dist > 0) {
        dx = dx / dist * _joyRadius;
        dy = dy / dist * _joyRadius;
    }
    _joyThumb = CGPointMake(dx, dy);

    CGFloat dead = _joyRadius * 0.32;
    NSMutableArray<NSNumber *> *codes = [NSMutableArray array];
    if (dx < -dead)      [codes addObject:@(SC_LEFT)];
    else if (dx > dead)  [codes addObject:@(SC_RIGHT)];
    if (dy < -dead)      [codes addObject:@(SC_UP)];
    else if (dy > dead)  [codes addObject:@(SC_DOWN)];

    // Diff against the currently-held set so only changes are sent.
    for (NSNumber *c in _joyCodes) {
        if (![codes containsObject:c]) [self releaseCodes:@[c]];
    }
    for (NSNumber *c in codes) {
        if (![_joyCodes containsObject:c]) [self pressCodes:@[c]];
    }
    _joyCodes = [codes copy];
    [self setNeedsDisplay];
}

- (void)resetJoystick {
    for (NSNumber *c in _joyCodes) [self releaseCodes:@[c]];
    _joyCodes = nil;
    _joyTouch = nil;
    _joyThumb = CGPointZero;
    [self setNeedsDisplay];
}

// ---- Touch handling -------------------------------------------------------

- (NSInteger)controlIndexAtPoint:(CGPoint)p {
    for (NSInteger i = 0; i < (NSInteger)_controls.count; i++) {
        if (CGRectContainsPoint([_controls[i][@"rect"] CGRectValue], p)) {
            return i;
        }
    }
    return -1;
}

- (void)pressCodes:(NSArray<NSNumber *> *)codes {
    for (NSNumber *code in codes) {
        if (![_held containsObject:code]) {
            eka2l1::ios::bridge::key(code.intValue, true);
            [self fireHaptic];   // only on a genuine new key-down
        }
        [_held addObject:code];
    }
}

// Short impact on a button/joystick-direction press, when enabled. The generator is created
// lazily and is a no-op on devices (and the simulator) without a Taptic Engine.
- (void)fireHaptic {
    if (!_hapticsEnabled) {
        return;
    }
    if (!_haptic) {
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    [_haptic impactOccurred];
}

- (void)setHapticsEnabled:(BOOL)hapticsEnabled {
    _hapticsEnabled = hapticsEnabled;
    if (hapticsEnabled && !_haptic) {
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [_haptic prepare];   // warm up the Taptic Engine so the first press has no latency
    }
}

// Codes for a tracked control index, or nil for the "slid off everything" sentinel (-1) and any
// stale index (a rebuild can never reorder a layout, but guard anyway). pressCodes/releaseCodes
// treat nil as a no-op.
- (NSArray<NSNumber *> *)codesForControlIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_controls.count) {
        return nil;
    }
    return _controls[idx][@"codes"];
}

- (void)releaseCodes:(NSArray<NSNumber *> *)codes {
    for (NSNumber *code in codes) {
        [_held removeObject:code];
        if (![_held containsObject:code]) {
            eka2l1::ios::bridge::key(code.intValue, false);
        }
    }
}

- (void)releaseAllHeld {
    for (NSNumber *code in [_held allObjects]) {
        eka2l1::ios::bridge::key(code.intValue, false);
    }
    [_held removeAllObjects];
    [_touchToControl removeAllObjects];
    _joyCodes = nil;
    _joyTouch = nil;
    _joyThumb = CGPointZero;
}

- (BOOL)isJoystickAt:(NSInteger)idx {
    return idx >= 0 && _controls[idx][@"joystick"] != nil;
}

// Whether the touch currently believed to own the joystick is still a live finger for this event.
// A stale owner (a missed touchesEnded, or a touch zapped by a system gesture / layout rebuild that
// was never cleared) must NOT keep blocking a fresh grab — otherwise the stick gets permanently
// stuck and every later joystick touch falls through to the button slide-to-switch path, which is
// what made sliding onto L register a press and the thumb sit dead at centre.
- (BOOL)joyTouchIsLiveInEvent:(UIEvent *)event {
    if (!_joyTouch) {
        return NO;
    }
    UITouchPhase ph = _joyTouch.phase;
    if (ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) {
        return NO;
    }
    return [[event allTouches] containsObject:_joyTouch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;   // gestures handle editing; no key output
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        NSInteger idx = [self controlIndexAtPoint:p];
        if (idx < 0) continue;
        if ([self isJoystickAt:idx]) {
            // Claim the stick for this finger unless another *live* finger already drives it
            // (one stick → first finger wins). A stale owner is reclaimed so the stick self-heals.
            if (![self joyTouchIsLiveInEvent:event]) {
                if (_joyTouch) {
                    [self resetJoystick];   // drop any directions the dead owner left held
                }
                _joyTouch = t;
                CGRect r = [_controls[idx][@"rect"] CGRectValue];
                _joyCenter = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
                _joyRadius = r.size.width / 2.0;
                [self updateJoystickToPoint:p];
            }
        } else {
            [_touchToControl setObject:@(idx) forKey:t];
            [self pressCodes:[self codesForControlIndex:idx]];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.editing) return;
    for (UITouch *t in touches) {
        // The stick owns its finger for the finger's whole life: roaming anywhere (even up onto L)
        // only drives the stick and never presses a button.
        if (t == _joyTouch) {
            [self updateJoystickToPoint:[t locationInView:self]];
            continue;
        }
        // Only touches that began on a button participate in slide-to-switch. A touch with no
        // tracking entry is a stray (e.g. a second finger on the stick) — ignore it rather than
        // letting a roaming finger press whatever button it crosses.
        NSNumber *prev = [_touchToControl objectForKey:t];
        if (!prev) continue;
        NSInteger prevIdx = prev.integerValue;
        NSInteger now = [self controlIndexAtPoint:[t locationInView:self]];
        if ([self isJoystickAt:now]) now = -1;   // never slide onto the stick
        if (now == prevIdx) continue;

        if (prevIdx >= 0) [self releaseCodes:[self codesForControlIndex:prevIdx]];
        if (now >= 0)     [self pressCodes:[self codesForControlIndex:now]];
        // Keep tracking the touch even when it slid off every button (now == -1), so sliding back
        // onto a button re-presses it — this is the slide-to-switch behaviour the layouts rely on.
        [_touchToControl setObject:@(now) forKey:t];
    }
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    for (UITouch *t in touches) {
        if (t == _joyTouch) {
            [self resetJoystick];
            continue;
        }
        NSNumber *idx = [_touchToControl objectForKey:t];
        if (idx) {
            [self releaseCodes:[self codesForControlIndex:idx.integerValue]];
            [_touchToControl removeObjectForKey:t];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }

// Let touches that miss every control pass through to the GL view (so the game still
// receives stylus/pointer taps in areas without a virtual key). In edit mode the whole view
// captures touches so the move/scale gestures work anywhere.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) {
        return nil;
    }
    if (self.editing) {
        return self;
    }
    if ([self controlIndexAtPoint:point] >= 0) {
        return self;
    }
    return nil;
}

// ---- Layout editor --------------------------------------------------------

+ (NSArray<NSDictionary *> *)defaultCustomLayout {
    // A sensible starting layout (like built-in layout 1): D-pad bottom-left, FIRE right,
    // L/R softkeys on the sides. Positions are normalized to width/height; size to min(W,H).
    return @[
        @{ @"type": @"dpad", @"cx": @(0.28), @"cy": @(0.78), @"size": @(0.52) },
        @{ @"type": @"key", @"codes": @[@(SC_FIRE)], @"label": @"FIRE", @"cx": @(0.76), @"cy": @(0.80), @"size": @(0.2) },
        @{ @"type": @"key", @"codes": @[@(SC_SOFT_LEFT)], @"label": @"L", @"cx": @(0.12), @"cy": @(0.46), @"size": @(0.15) },
        @{ @"type": @"key", @"codes": @[@(SC_SOFT_RIGHT)], @"label": @"R", @"cx": @(0.88), @"cy": @(0.46), @"size": @(0.15) },
    ];
}

+ (NSArray<NSDictionary *> *)customLayoutForBuiltinLayout:(NSInteger)layout {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    switch (layout) {
        case 1:   // D-pad centred, FIRE in the middle, L/R above
            [out addObject:EKADpadEl(0.5, 0.78, 0.52)];
            [out addObject:EKAKeyEl(SC_FIRE, @"FIRE", 0.5, 0.78, 0.16)];
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.33, 0.54, 0.12)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.67, 0.54, 0.12)];
            break;
        case 5:   // Layout 1.5: D-pad + FIRE + L/R, plus # and * on the right edge
            [out addObject:EKADpadEl(0.40, 0.78, 0.50)];
            [out addObject:EKAKeyEl(SC_FIRE, @"FIRE", 0.40, 0.78, 0.15)];
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.25, 0.54, 0.12)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.55, 0.54, 0.12)];
            [out addObject:EKAKeyEl(SC_POUND, @"#", 0.88, 0.70, 0.13)];
            [out addObject:EKAKeyEl(SC_STAR, @"*", 0.88, 0.86, 0.13)];
            break;
        case 6:   // Joystick bottom-left, FIRE + #/* bottom-right, L/R above
            [out addObject:EKAJoyEl(0.22, 0.76, 0.40)];
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.22, 0.50, 0.12)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.88, 0.50, 0.12)];
            [out addObject:EKAKeyEl(SC_POUND, @"#", 0.88, 0.68, 0.13)];
            [out addObject:EKAKeyEl(SC_STAR, @"*", 0.88, 0.85, 0.13)];
            [out addObject:EKAKeyEl(SC_FIRE, @"FIRE", 0.64, 0.80, 0.16)];
            break;
        case 2:   // Centred numeric keypad + softkeys, no D-pad
            EKAAppendNumpad(out, 0.30, 0.50, 0.20, 0.12, 0.12);
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.15, 0.40, 0.12)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.85, 0.40, 0.12)];
            break;
        case 3:   // D-pad right, keypad left, FIRE between
            EKAAppendNumpad(out, 0.12, 0.50, 0.15, 0.11, 0.10);
            [out addObject:EKADpadEl(0.74, 0.74, 0.42)];
            [out addObject:EKAKeyEl(SC_FIRE, @"F", 0.50, 0.80, 0.14)];
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.12, 0.38, 0.11)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.88, 0.38, 0.11)];
            break;
        case 4:   // D-pad left, keypad right, FIRE between
            EKAAppendNumpad(out, 0.62, 0.50, 0.15, 0.11, 0.10);
            [out addObject:EKADpadEl(0.26, 0.74, 0.42)];
            [out addObject:EKAKeyEl(SC_FIRE, @"F", 0.50, 0.80, 0.14)];
            [out addObject:EKAKeyEl(SC_SOFT_LEFT, @"L", 0.12, 0.38, 0.11)];
            [out addObject:EKAKeyEl(SC_SOFT_RIGHT, @"R", 0.88, 0.38, 0.11)];
            break;
        default:  // 0 = None: nothing to seed
            break;
    }
    return out;
}

+ (NSArray<NSDictionary *> *)buttonPalette {
    return @[
        @{ @"label": @"D-pad", @"codes": @[], @"dpad": @(YES) },
        @{ @"label": @"Joystick", @"codes": @[], @"joystick": @(YES) },
        @{ @"label": @"FIRE", @"codes": @[@(SC_FIRE)], @"dpad": @(NO) },
        @{ @"label": @"L", @"codes": @[@(SC_SOFT_LEFT)], @"dpad": @(NO) },
        @{ @"label": @"R", @"codes": @[@(SC_SOFT_RIGHT)], @"dpad": @(NO) },
        @{ @"label": @"↑", @"codes": @[@(SC_UP)], @"dpad": @(NO) },
        @{ @"label": @"↓", @"codes": @[@(SC_DOWN)], @"dpad": @(NO) },
        @{ @"label": @"←", @"codes": @[@(SC_LEFT)], @"dpad": @(NO) },
        @{ @"label": @"→", @"codes": @[@(SC_RIGHT)], @"dpad": @(NO) },
        @{ @"label": @"1", @"codes": @[@(SC_NUM1)], @"dpad": @(NO) },
        @{ @"label": @"2", @"codes": @[@(SC_NUM2)], @"dpad": @(NO) },
        @{ @"label": @"3", @"codes": @[@(SC_NUM3)], @"dpad": @(NO) },
        @{ @"label": @"4", @"codes": @[@(SC_NUM4)], @"dpad": @(NO) },
        @{ @"label": @"5", @"codes": @[@(SC_NUM5)], @"dpad": @(NO) },
        @{ @"label": @"6", @"codes": @[@(SC_NUM6)], @"dpad": @(NO) },
        @{ @"label": @"7", @"codes": @[@(SC_NUM7)], @"dpad": @(NO) },
        @{ @"label": @"8", @"codes": @[@(SC_NUM8)], @"dpad": @(NO) },
        @{ @"label": @"9", @"codes": @[@(SC_NUM9)], @"dpad": @(NO) },
        @{ @"label": @"0", @"codes": @[@(SC_NUM0)], @"dpad": @(NO) },
        @{ @"label": @"*", @"codes": @[@(SC_STAR)], @"dpad": @(NO) },
        @{ @"label": @"#", @"codes": @[@(SC_POUND)], @"dpad": @(NO) },
    ];
}

- (void)ensureGestures {
    if (_pan) {
        return;
    }
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    _pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:_pan];
    [self addGestureRecognizer:_pinch];
    [self addGestureRecognizer:_tap];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    if (editing) {
        [self ensureGestures];
        [self releaseAllHeld];
    }
    _pan.enabled = _pinch.enabled = _tap.enabled = editing;
    [self updateVisibility];
    [self setNeedsDisplay];
}

- (NSInteger)elementIndexAtPoint:(CGPoint)p {
    // Topmost (last drawn) first.
    for (NSInteger i = (NSInteger)_elements.count - 1; i >= 0; i--) {
        if (CGRectContainsPoint([self rectForElement:_elements[i]], p)) {
            return i;
        }
    }
    return -1;
}

- (void)notifyChanged {
    [self rebuildControls];
    [self setNeedsDisplay];
    [self.editDelegate gameControlsDidChange:self];
}

- (void)onTap:(UITapGestureRecognizer *)g {
    _selectedIndex = [self elementIndexAtPoint:[g locationInView:self]];
    [self setNeedsDisplay];
    [self.editDelegate gameControlsDidChange:self];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragIndex = [self elementIndexAtPoint:p];
        if (_dragIndex >= 0) {
            _selectedIndex = _dragIndex;
            _dragStartCenter = CGPointMake([_elements[_dragIndex][@"cx"] floatValue],
                                           [_elements[_dragIndex][@"cy"] floatValue]);
        }
        [self setNeedsDisplay];
    } else if (g.state == UIGestureRecognizerStateChanged && _dragIndex >= 0) {
        CGPoint d = [g translationInView:self];
        CGFloat cx = MIN(1.0, MAX(0.0, _dragStartCenter.x + (W > 0 ? d.x / W : 0)));
        CGFloat cy = MIN(1.0, MAX(0.0, _dragStartCenter.y + (H > 0 ? d.y / H : 0)));
        _elements[_dragIndex][@"cx"] = @(cx);
        _elements[_dragIndex][@"cy"] = @(cy);
        [self notifyChanged];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _dragIndex = -1;
    }
}

- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (_selectedIndex < 0) {
        return;
    }
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchBaseSize = [_elements[_selectedIndex][@"size"] floatValue];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat s = MIN(0.95, MAX(0.06, _pinchBaseSize * g.scale));
        _elements[_selectedIndex][@"size"] = @(s);
        [self notifyChanged];
    }
}

- (NSArray<NSDictionary *> *)currentLayout {
    return [[NSArray alloc] initWithArray:(_elements ?: @[]) copyItems:YES];
}

- (BOOL)hasSelection {
    return _selectedIndex >= 0 && _selectedIndex < (NSInteger)_elements.count;
}

- (void)addKeyWithCodes:(NSArray<NSNumber *> *)codes label:(NSString *)label {
    if (!_elements) _elements = [NSMutableArray array];
    [_elements addObject:[@{ @"type": @"key", @"codes": codes, @"label": label,
                             @"cx": @(0.5), @"cy": @(0.5), @"size": @(0.16) } mutableCopy]];
    _selectedIndex = (NSInteger)_elements.count - 1;
    [self notifyChanged];
}

- (void)addDpad {
    if (!_elements) _elements = [NSMutableArray array];
    [_elements addObject:[@{ @"type": @"dpad", @"cx": @(0.5), @"cy": @(0.5), @"size": @(0.5) } mutableCopy]];
    _selectedIndex = (NSInteger)_elements.count - 1;
    [self notifyChanged];
}

- (void)addJoystick {
    if (!_elements) _elements = [NSMutableArray array];
    [_elements addObject:[@{ @"type": @"joystick", @"cx": @(0.5), @"cy": @(0.5), @"size": @(0.4) } mutableCopy]];
    _selectedIndex = (NSInteger)_elements.count - 1;
    [self notifyChanged];
}

- (void)deleteSelected {
    if (![self hasSelection]) return;
    [_elements removeObjectAtIndex:_selectedIndex];
    _selectedIndex = -1;
    [self notifyChanged];
}

- (void)scaleSelectedBy:(CGFloat)factor {
    if (![self hasSelection]) return;
    CGFloat s = MIN(0.95, MAX(0.06, [_elements[_selectedIndex][@"size"] floatValue] * factor));
    _elements[_selectedIndex][@"size"] = @(s);
    [self notifyChanged];
}

- (void)scaleAllBy:(CGFloat)factor {
    for (NSMutableDictionary *el in _elements) {
        CGFloat s = MIN(0.95, MAX(0.06, [el[@"size"] floatValue] * factor));
        el[@"size"] = @(s);
    }
    [self notifyChanged];
}

@end
