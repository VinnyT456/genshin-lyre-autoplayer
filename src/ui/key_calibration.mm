#import "key_calibration.h"

#include <algorithm>
#include <array>
#include <cmath>

#include "key_layout.h"
#include "strings.h"
#include "theme.h"

// Borderless panels can't become key by default; calibration needs keyboard
// shortcuts, so allow it (still non-activating: Genshin stays frontmost).
@interface KeyCalibrationPanel : NSPanel
@end

@implementation KeyCalibrationPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface KeyCalibrationView : NSView
@property(nonatomic, copy) void (^onFinish)(BOOL saved);
- (void)startAdjusting:(const KeyLayout&)layout;
@end

@implementation KeyCalibrationView {
    int _step;            // 0 = waiting for Q, 1 = waiting for M, 2 = review / adjust
    double _qu, _qv;
    std::array<KeyPlacement, 21> _keys;   // review: every key, individually editable
    int _selected;        // key being adjusted, or -1
    BOOL _dragging;
    NSPoint _dragOffset;  // pointer minus key center at grab time (view points)
    BOOL _adjustOnly;     // started from the saved layout (no Q/M clicks)
    NSStackView* _buttons;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _selected = -1;
        NSButton* save = [self buttonWithTitle:strings::get(Str::calib_save) action:@selector(save)];
        save.keyEquivalent = @"\r";
        save.bezelColor = themes::current().accent;   // themed primary action
        NSButton* redo = [self buttonWithTitle:strings::get(Str::calib_redo) action:@selector(redo)];
        NSButton* cancel = [self buttonWithTitle:strings::get(Str::calib_cancel) action:@selector(cancel)];
        _buttons = [NSStackView stackViewWithViews:@[cancel, redo, save]];
        _buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        _buttons.spacing = 8;
        _buttons.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_buttons];
        [NSLayoutConstraint activateConstraints:@[
            [_buttons.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_buttons.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-28],
        ]];
        [self updateButtons];
    }
    return self;
}

- (NSButton*)buttonWithTitle:(NSString*)title action:(SEL)action {
    NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeLarge;
    return b;
}

- (void)startAdjusting:(const KeyLayout&)layout {
    _keys = layout.keys;
    _adjustOnly = YES;
    _step = 2;
    _selected = -1;
    [self updateButtons];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:_step < 2 ? NSCursor.crosshairCursor : NSCursor.arrowCursor];
}

// ---- Picture-fraction ↔ view mapping ----

- (NSRect)picture {
    return key_picture_rect(self.window, self.bounds);
}

- (NSPoint)viewPointForKey:(int)k {
    const NSRect pic = [self picture];
    const KeyPlacement& key = _keys[static_cast<std::size_t>(k)];
    return NSMakePoint(NSMinX(pic) + key.u * NSWidth(pic), NSMinY(pic) + key.v * NSHeight(pic));
}

- (CGFloat)viewRadiusForKey:(int)k {
    return _keys[static_cast<std::size_t>(k)].radius * NSWidth([self picture]);
}

// The key under a point (nearest center within a generous grab distance).
- (int)keyAtPoint:(NSPoint)p {
    int best = -1;
    CGFloat bestDistance = 0;
    for (int k = 0; k < 21; ++k) {
        const NSPoint c = [self viewPointForKey:k];
        const CGFloat d = std::hypot(p.x - c.x, p.y - c.y);
        if (d <= std::max<CGFloat>([self viewRadiusForKey:k] * 1.15, 14) && (best < 0 || d < bestDistance)) {
            best = k;
            bestDistance = d;
        }
    }
    return best;
}

- (void)moveKey:(int)k toViewPoint:(NSPoint)p {
    const NSRect pic = [self picture];
    KeyPlacement& key = _keys[static_cast<std::size_t>(k)];
    key.u = std::clamp((p.x - NSMinX(pic)) / NSWidth(pic), 0.0, 1.0);
    key.v = std::clamp((p.y - NSMinY(pic)) / NSHeight(pic), 0.0, 1.0);
    self.needsDisplay = YES;
}

// Grow / shrink by view points, kept within a sane range.
- (void)resizeKey:(int)k byPoints:(CGFloat)delta {
    const CGFloat width = NSWidth([self picture]);
    KeyPlacement& key = _keys[static_cast<std::size_t>(k)];
    const double r = key.radius * width + delta;
    key.radius = std::clamp(r, 8.0, 200.0) / width;
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent*)event {
    if (_step != 2 || !_dragging || _selected < 0) {
        return;
    }
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self moveKey:_selected toViewPoint:NSMakePoint(p.x - _dragOffset.x, p.y - _dragOffset.y)];
}

- (void)mouseUp:(NSEvent*)event {
    _dragging = NO;
}

- (void)scrollWheel:(NSEvent*)event {
    if (_step != 2) {
        return;
    }
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const int k = [self keyAtPoint:p] >= 0 ? [self keyAtPoint:p] : _selected;
    if (k < 0) {
        return;
    }
    _selected = k;
    const CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.25
                                                          : event.scrollingDeltaY;
    [self resizeKey:k byPoints:-delta];
}

- (void)updateButtons {
    // Only Save/Redo during review; Cancel is always available.
    for (NSButton* b in _buttons.arrangedSubviews) {
        const BOOL isCancel = b.action == @selector(cancel);
        b.hidden = !isCancel && _step < 2;
    }
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent*)event {
    if (_step >= 2) {
        // Review: grab a ring to move it (click empty space to deselect).
        const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        _selected = [self keyAtPoint:p];
        _dragging = _selected >= 0;
        if (_dragging) {
            const NSPoint c = [self viewPointForKey:_selected];
            _dragOffset = NSMakePoint(p.x - c.x, p.y - c.y);
        }
        self.needsDisplay = YES;
        return;
    }
    const NSRect picture = key_picture_rect(self.window, self.bounds);
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, picture)) {
        return;
    }
    const double u = (p.x - NSMinX(picture)) / NSWidth(picture);
    const double v = (p.y - NSMinY(picture)) / NSHeight(picture);
    if (_step == 0) {
        _qu = u; _qv = v; _step = 1;
    } else {
        // M must be to the lower right of Q, or the grid would be inverted.
        if (u > _qu + 0.02 && v > _qv + 0.02) {
            _keys = key_layout_from_corners(_qu, _qv, u, v).keys;
            _selected = -1;
            _step = 2;
        } else {
            NSBeep();
        }
    }
    [self updateButtons];
}

- (void)keyDown:(NSEvent*)event {
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString;
    if (event.keyCode == 53) {                       // Esc
        [self cancel];
    } else if ([chars isEqualToString:@"r"]) {
        [self redo];
    } else if (_step == 2 && _selected >= 0 && [self adjustSelectedWithEvent:event]) {
        return;
    } else if ((event.keyCode == 36 || event.keyCode == 76) && _step == 2) {   // Return / Enter
        [self save];
    } else {
        [super keyDown:event];
    }
}

// Arrow keys nudge the selected key (⇧ = 10 pt); +/− resize; Tab cycles.
- (BOOL)adjustSelectedWithEvent:(NSEvent*)event {
    const CGFloat step = (event.modifierFlags & NSEventModifierFlagShift) ? 10.0 : 1.0;
    NSPoint c = [self viewPointForKey:_selected];
    switch (event.keyCode) {
        case 123: c.x -= step; break;   // ←
        case 124: c.x += step; break;   // →
        case 125: c.y += step; break;   // ↓ (flipped view)
        case 126: c.y -= step; break;   // ↑
        case 48:                        // Tab / ⇧Tab
            _selected = (_selected + ((event.modifierFlags & NSEventModifierFlagShift) ? 20 : 1)) % 21;
            self.needsDisplay = YES;
            return YES;
        default: {
            NSString* chars = event.charactersIgnoringModifiers;
            if ([chars isEqualToString:@"+"] || [chars isEqualToString:@"="]) {
                [self resizeKey:_selected byPoints:step];
                return YES;
            }
            if ([chars isEqualToString:@"-"] || [chars isEqualToString:@"_"]) {
                [self resizeKey:_selected byPoints:-step];
                return YES;
            }
            return NO;
        }
    }
    [self moveKey:_selected toViewPoint:c];
    return YES;
}

- (void)save {
    if (_step != 2) {
        return;
    }
    save_key_layout(_keys);
    if (self.onFinish) self.onFinish(YES);
}

- (void)redo {
    _step = 0;
    _selected = -1;
    _adjustOnly = NO;
    [self updateButtons];
}

- (void)cancel {
    if (self.onFinish) self.onFinish(NO);
}

- (void)drawMarkerAt:(NSPoint)p radius:(CGFloat)r color:(NSColor*)color {
    [color setStroke];
    NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(p.x - r, p.y - r, r * 2, r * 2)];
    ring.lineWidth = 2.5;
    [ring stroke];
    NSBezierPath* cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(p.x - r * 0.5, p.y)];
    [cross lineToPoint:NSMakePoint(p.x + r * 0.5, p.y)];
    [cross moveToPoint:NSMakePoint(p.x, p.y - r * 0.5)];
    [cross lineToPoint:NSMakePoint(p.x, p.y + r * 0.5)];
    cross.lineWidth = 1.5;
    [cross stroke];
}

- (void)drawCrossAt:(NSPoint)p size:(CGFloat)half color:(NSColor*)color {
    [color setStroke];
    NSBezierPath* cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(p.x - half, p.y)];
    [cross lineToPoint:NSMakePoint(p.x + half, p.y)];
    [cross moveToPoint:NSMakePoint(p.x, p.y - half)];
    [cross lineToPoint:NSMakePoint(p.x, p.y + half)];
    cross.lineWidth = 1.2;
    [cross stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const NSRect picture = key_picture_rect(self.window, self.bounds);

    // Dim the game a little so the guides stand out but the lyre stays visible.
    [[NSColor colorWithWhite:0.0 alpha:0.32] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);

    auto toView = [&](double u, double v) {
        return NSMakePoint(NSMinX(picture) + u * NSWidth(picture),
                           NSMinY(picture) + v * NSHeight(picture));
    };

    if (_step == 1) {
        [self drawMarkerAt:toView(_qu, _qv) radius:18 color:theme.accent];
    }
    if (_step == 2) {
        static const char* kLetters = "QWERTYUASDFGHJZXCVBNM";
        for (int k = 0; k < 21; ++k) {
            const BOOL selected = k == _selected;
            const NSPoint c = [self viewPointForKey:k];
            const CGFloat r = [self viewRadiusForKey:k];
            NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(c.x - r, c.y - r, r * 2, r * 2)];
            if (selected) {
                [[theme.accent colorWithAlphaComponent:0.22] setFill];
                [ring fill];
            }
            ring.lineWidth = selected ? 3.5 : 2.0;
            [(selected ? theme.accent : [theme.accent colorWithAlphaComponent:0.75]) setStroke];
            [ring stroke];
            // Center cross so the middle of each button is easy to line up.
            [self drawCrossAt:c size:std::min<CGFloat>(r * 0.3, 8) color:theme.accent];
            NSDictionary* attrs = @{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:selected ? 15 : 13],
                NSForegroundColorAttributeName: theme.accent
            };
            NSString* letter = [NSString stringWithFormat:@"%c", kLetters[k]];
            const NSSize sz = [letter sizeWithAttributes:attrs];
            [letter drawAtPoint:NSMakePoint(c.x - sz.width / 2, c.y - r - sz.height - 2) withAttributes:attrs];
        }
    }

    // Instruction banner, themed like the HUD.
    NSString* title = _step == 0 ? strings::get(Str::calib_step_q)
        : _step == 1 ? strings::get(Str::calib_step_m)
        : _adjustOnly ? strings::get(Str::calib_adjust) : strings::get(Str::calib_review);
    NSString* sub = _step != 2 ? strings::get(Str::calib_hint_cancel)
        : _adjustOnly ? strings::get(Str::calib_hint_adjust) : strings::get(Str::calib_hint_keys);
    NSDictionary* titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: theme.ink
    };
    NSDictionary* subAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: theme.ink_soft
    };
    const NSSize ts = [title sizeWithAttributes:titleAttrs];
    const NSSize ss = [sub sizeWithAttributes:subAttrs];
    const CGFloat w = std::max(ts.width, ss.width) + 48;
    const NSRect banner = NSMakeRect(NSMidX(picture) - w / 2, NSMinY(picture) + 24, w, 64);
    [[NSColor colorWithCalibratedWhite:0.08 alpha:0.92] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:banner xRadius:12 yRadius:12] fill];
    [theme.panel_tint setFill];
    [[NSBezierPath bezierPathWithRoundedRect:banner xRadius:12 yRadius:12] fill];
    [[theme.accent colorWithAlphaComponent:0.7] setStroke];
    NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(banner, 0.5, 0.5) xRadius:12 yRadius:12];
    edge.lineWidth = 1.0;
    [edge stroke];
    [title drawAtPoint:NSMakePoint(NSMidX(banner) - ts.width / 2, NSMinY(banner) + 11) withAttributes:titleAttrs];
    [sub drawAtPoint:NSMakePoint(NSMidX(banner) - ss.width / 2, NSMinY(banner) + 38) withAttributes:subAttrs];
}

@end

@implementation KeyCalibrationController {
    void (^_completion)(BOOL);
}

- (void)beginOverGameFrame:(NSRect)gameFrame
                 adjusting:(BOOL)adjusting
                completion:(void (^)(BOOL saved))completion {
    _completion = [completion copy];
    KeyCalibrationPanel* panel = [[KeyCalibrationPanel alloc]
        initWithContentRect:gameFrame
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.level = NSScreenSaverWindowLevel + 1;   // above the HUD and overlay
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window = panel;

    KeyCalibrationView* view = [[KeyCalibrationView alloc]
        initWithFrame:NSMakeRect(0, 0, NSWidth(gameFrame), NSHeight(gameFrame))];
    __weak KeyCalibrationController* weakSelf = self;
    view.onFinish = ^(BOOL saved) {
        [weakSelf finish:saved];
    };
    panel.contentView = view;
    if (adjusting && current_key_layout().ready) {
        [view startAdjusting:current_key_layout()];
    }
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:view];
}

- (void)finish:(BOOL)saved {
    [self.window orderOut:nil];
    void (^completion)(BOOL) = _completion;
    _completion = nil;
    if (completion) completion(saved);
}

@end
