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
#import "GameMenuView.h"

@implementation GameMenuView {
    NSString *_title;
    NSMutableArray<NSString *> *_titles;
    NSMutableArray *_handlers;          // NSNull or block
    NSMutableArray<NSNumber *> *_destructive;
    NSMutableArray<UIButton *> *_buttons;
    NSInteger _highlight;
    UIView *_panel;
    void (^_onDismiss)(void);
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _title = [title copy];
        _titles = [NSMutableArray array];
        _handlers = [NSMutableArray array];
        _destructive = [NSMutableArray array];
        _buttons = [NSMutableArray array];
        _highlight = 0;
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    }
    return self;
}

- (void)addOption:(NSString *)title destructive:(BOOL)destructive handler:(void (^)(void))handler {
    [_titles addObject:title];
    [_handlers addObject:(handler ? [handler copy] : (id)[NSNull null])];
    [_destructive addObject:@(destructive)];
}

- (void)showInView:(UIView *)parent onDismiss:(void (^)(void))onDismiss {
    _onDismiss = [onDismiss copy];
    self.frame = parent.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent addSubview:self];

    const CGFloat W = MIN(320, parent.bounds.size.width - 48);
    const CGFloat rowH = 52, titleH = _title.length ? 44 : 8, pad = 8;
    const CGFloat H = titleH + _titles.count * rowH + pad;
    _panel = [[UIView alloc] initWithFrame:CGRectMake((parent.bounds.size.width - W) / 2,
                                                      (parent.bounds.size.height - H) / 2, W, H)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    _panel.layer.cornerRadius = 16;
    _panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                              UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self addSubview:_panel];

    if (_title.length) {
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, W - 24, titleH)];
        t.text = _title;
        t.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        t.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:t];
    }

    for (NSInteger i = 0; i < (NSInteger)_titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(pad, titleH + i * rowH, W - 2 * pad, rowH - 6);
        b.layer.cornerRadius = 10;
        [b setTitle:_titles[i] forState:UIControlStateNormal];
        UIColor *fg = [_destructive[i] boolValue] ? [UIColor systemRedColor] : [UIColor whiteColor];
        [b setTitleColor:fg forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        b.tag = i;
        [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:b];
        [_buttons addObject:b];
    }
    [self refreshHighlight];
}

- (void)refreshHighlight {
    for (NSInteger i = 0; i < (NSInteger)_buttons.count; i++) {
        _buttons[i].backgroundColor = (i == _highlight) ? [UIColor colorWithWhite:1.0 alpha:0.22]
                                                        : [UIColor clearColor];
    }
}

- (void)onTap:(UIButton *)b {
    _highlight = b.tag;
    [self choose];
}

- (void)navigate:(NSInteger)dir {
    if (_buttons.count == 0) {
        return;
    }
    if (dir == 0) {
        [self choose];
        return;
    }
    _highlight = (_highlight + dir + _buttons.count) % _buttons.count;
    [self refreshHighlight];
}

- (void)choose {
    if (_highlight < 0 || _highlight >= (NSInteger)_handlers.count) {
        return;
    }
    id handler = _handlers[_highlight];
    [self dismiss];
    if (handler != [NSNull null]) {
        ((void (^)(void))handler)();
    }
}

- (void)dismiss {
    void (^cb)(void) = _onDismiss;
    _onDismiss = nil;   // ensure onDismiss fires once
    [self removeFromSuperview];
    if (cb) {
        cb();
    }
}

@end
