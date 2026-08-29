#import "PlayerWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <optional>
#include <vector>

#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

#include "genshin.h"
#include "keyboard.h"
#include "key.h"
#include "playback_controller.h"
#include "settings.h"

namespace {

constexpr CGFloat kW = 262.0;
constexpr CGFloat kH = 268.0;       // expanded height
constexpr CGFloat kMiniH = 62.0;    // collapsed: header only
// Gap from game window edges (top-right dock).
constexpr CGFloat kTopInset = 40.0;
constexpr CGFloat kRightInset = 56.0;
// Local settings keys (hud-settings.json next to the binary).
constexpr const char* kSettingCollapsed = "collapsed";
constexpr const char* kSettingAutoPause = "auto_pause_on_blur";

NSString* format_time(std::chrono::milliseconds ms) {
    const auto s = ms.count() / 1000;
    return [NSString stringWithFormat:@"%lld:%02lld", s / 60, s % 60];
}

// "1×", "1.25×", "0.5×" — trailing zeros trimmed.
NSString* format_speed(double speed) {
    NSString* num = [NSString stringWithFormat:@"%.2f", speed];
    while ([num hasSuffix:@"0"]) {
        num = [num substringToIndex:num.length - 1];
    }
    if ([num hasSuffix:@"."]) {
        num = [num substringToIndex:num.length - 1];
    }
    return [num stringByAppendingString:@"×"];
}

// Preset speeds cycled by the HUD speed button.
const double kSpeedPresets[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0};

// Parse a note label like "Q+G" back into keys (for the idle grid preview).
std::vector<Key> keys_from_label(const std::string& label) {
    static const std::string chars = "QWERTYUASDFGHJZXCVBNM";
    std::vector<Key> keys;
    for (char c : label) {
        const auto pos = chars.find(static_cast<char>(std::toupper(c)));
        if (pos != std::string::npos) {
            keys.push_back(static_cast<Key>(pos));
        }
    }
    return keys;
}

// --- Palette: dark game-native, warm gold accent. One accent, used sparingly.
NSColor* gold() {
    return [NSColor colorWithSRGBRed:0.85 green:0.71 blue:0.42 alpha:1.0];
}
NSColor* ink() {  // primary text: warm off-white, not pure system label
    return [NSColor colorWithSRGBRed:0.93 green:0.91 blue:0.86 alpha:1.0];
}
NSColor* ink_soft() {
    return [NSColor colorWithSRGBRed:0.93 green:0.91 blue:0.86 alpha:0.55];
}
NSColor* ink_faint() {
    return [NSColor colorWithSRGBRed:0.93 green:0.91 blue:0.86 alpha:0.32];
}

NSImage* symbol(NSString* name, CGFloat size, NSFontWeight weight) {
    NSImageSymbolConfiguration* config =
        [NSImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:weight];
    return [[NSImage imageWithSystemSymbolName:name
                      accessibilityDescription:nil]
        imageWithSymbolConfiguration:config];
}

NSImage* tinted_symbol(NSString* name, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSImage* base = symbol(name, size, weight);
    NSImage* tinted = [NSImage imageWithSize:base.size
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect rect) {
        [base drawInRect:rect];
        [color set];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
        return YES;
    }];
    [tinted setTemplate:NO];
    return tinted;
}

// Resolve the Genshin process id, or 0 if not running.
pid_t genshin_pid() {
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.localizedName isEqualToString:@"Genshin Impact"]) {
            return app.processIdentifier;
        }
    }
    return 0;
}

bool genshin_is_focused(pid_t pid) {
    if (pid == 0) {
        return false;
    }
    NSRunningApplication* app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app != nil && app.isActive;
}

// Convert a CoreGraphics window rect (global, top-left origin) into AppKit
// screen coordinates (per-screen, bottom-left origin).
std::optional<NSRect> cg_bounds_to_screen(CGRect bounds) {
    for (NSScreen* screen in NSScreen.screens) {
        NSNumber* num = screen.deviceDescription[@"NSScreenNumber"];
        if (num == nil) {
            continue;
        }

        const CGRect display = CGDisplayBounds(num.unsignedIntValue);
        if (CGRectIsNull(CGRectIntersection(bounds, display))) {
            continue;
        }

        const NSRect frame = screen.frame;
        const CGFloat x = NSMinX(frame) + (CGRectGetMinX(bounds) - CGRectGetMinX(display));
        const CGFloat y = NSMinY(frame) + NSHeight(frame) -
            (CGRectGetMinY(bounds) - CGRectGetMinY(display)) - CGRectGetHeight(bounds);
        return NSMakeRect(x, y, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    }
    return std::nullopt;
}

// Full scan: find Genshin's main game window. Fills out_number when provided.
std::optional<NSRect> game_frame(pid_t pid, CGWindowID* out_number) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (list == nullptr) {
        return std::nullopt;
    }

    auto consider = [&](NSDictionary* window, bool require_name,
                        CGRect& best, CGFloat& best_area, CGWindowID& best_number) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) {
            return;
        }

        const int owner_pid = [window[(id)kCGWindowOwnerPID] intValue];
        NSString* window_name = window[(id)kCGWindowName] ?: @"";
        if (pid != 0) {
            if (owner_pid != pid) {
                return;
            }
            if (require_name && ![window_name isEqualToString:@"Genshin Impact"]) {
                return;
            }
        } else if (![window_name isEqualToString:@"Genshin Impact"]) {
            return;
        }

        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)window[(id)kCGWindowBounds],
                &bounds)) {
            return;
        }
        if (bounds.size.width < 200.0 || bounds.size.height < 150.0) {
            return;
        }

        const CGFloat area = bounds.size.width * bounds.size.height;
        if (area > best_area) {
            best_area = area;
            best = bounds;
            best_number = [window[(id)kCGWindowNumber] unsignedIntValue];
        }
    };

    CGRect best = CGRectZero;
    CGFloat best_area = 0.0;
    CGWindowID best_number = kCGNullWindowID;
    NSArray* windows = CFBridgingRelease(list);

    for (NSDictionary* window in windows) {
        consider(window, true, best, best_area, best_number);
    }
    if (best_area <= 0.0) {
        for (NSDictionary* window in windows) {
            consider(window, false, best, best_area, best_number);
        }
    }

    if (best_area <= 0.0) {
        return std::nullopt;
    }
    if (out_number != nullptr) {
        *out_number = best_number;
    }

    return cg_bounds_to_screen(best);
}

NSScreen* screen_for_rect(NSRect rect) {
    NSScreen* best_screen = NSScreen.mainScreen;
    CGFloat best_area = 0.0;
    for (NSScreen* screen in NSScreen.screens) {
        const NSRect overlap = NSIntersectionRect(rect, screen.frame);
        const CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area > best_area) {
            best_area = area;
            best_screen = screen;
        }
    }
    return best_screen;
}

NSPoint top_right_hud_origin(NSRect game, CGFloat hud_height) {
    NSScreen* screen = screen_for_rect(game);
    const NSRect visible = screen != nil ? screen.visibleFrame : NSScreen.mainScreen.visibleFrame;
    const NSRect usable_game = NSIntersectionRect(game, visible);
    const NSRect anchor = NSIsEmptyRect(usable_game) ? visible : usable_game;

    NSPoint origin = NSMakePoint(NSMaxX(anchor) - kRightInset - kW,
                                 NSMaxY(anchor) - kTopInset - hud_height);
    origin.x = std::clamp(origin.x, NSMinX(visible), NSMaxX(visible) - kW);
    origin.y = std::clamp(origin.y, NSMinY(visible), NSMaxY(visible) - hud_height);
    return origin;
}

}  // namespace

// Clickable / draggable seek bar. Reports the scrubbed fraction (0..1) to its
// target on mouse-down and while dragging.
@interface ProgressBar : NSView
@property(nonatomic) double progress;
@property(nonatomic, weak) id seekTarget;
@property(nonatomic) SEL seekAction;   // -(void)seekTo:(NSNumber* fraction)
@property(nonatomic) BOOL hovering;
@end

@implementation ProgressBar {
    NSTrackingArea* _tracking;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setProgress:(double)progress {
    _progress = std::clamp(progress, 0.0, 1.0);
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)event {
    _hovering = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event {
    _hovering = NO;
    self.needsDisplay = YES;
}

- (void)scrubToEvent:(NSEvent*)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const double fraction = std::clamp(p.x / std::max(1.0, self.bounds.size.width), 0.0, 1.0);
    _progress = fraction;
    self.needsDisplay = YES;
    if (_seekTarget != nil && _seekAction != nullptr) {
        NSMethodSignature* sig = [_seekTarget methodSignatureForSelector:_seekAction];
        if (sig != nil) {
            NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = _seekTarget;
            inv.selector = _seekAction;
            NSNumber* arg = @(fraction);
            [inv setArgument:&arg atIndex:2];
            [inv invoke];
        }
    }
}

- (void)mouseDown:(NSEvent*)event {
    [self scrubToEvent:event];
}

- (void)mouseDragged:(NSEvent*)event {
    [self scrubToEvent:event];
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bounds = self.bounds;
    const CGFloat cy = bounds.size.height * 0.5;
    const CGFloat h = 3.0;  // thin hairline track
    const CGFloat radius = h * 0.5;
    NSRect track = NSMakeRect(0, cy - radius, bounds.size.width, h);

    [ink_faint() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:radius yRadius:radius] fill];

    if (_progress > 0.0) {
        NSRect fill = track;
        fill.size.width = std::max(h, bounds.size.width * _progress);
        [gold() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
    }

    if (_hovering) {
        const CGFloat cx = std::clamp(bounds.size.width * _progress, 3.0,
                                      bounds.size.width - 3.0);
        const CGFloat r = 4.0;
        [gold() setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(cx - r, cy - r, r * 2, r * 2)] fill];
    }
}

@end

@interface LyreKeyGridView : NSView
@property(nonatomic, assign) Keyboard* keyboard;
- (void)setActiveKeys:(const std::vector<Key>&)keys;
- (void)setPreviewKeys:(const std::vector<Key>&)keys;  // faint hint when idle
@end

@implementation LyreKeyGridView {
    std::vector<Key> _active;
    std::vector<Key> _preview;   // first-note keys, shown faintly at rest
    double _pulse[21];  // per-key glow, 1.0 on hit, decays toward 0
    std::optional<Key> _held;
    double _shimmer;             // slow ambient breathing for idle keys
}

static const Key kLayout[3][7] = {
    {Key::Q, Key::W, Key::E, Key::R, Key::T, Key::Y, Key::U},
    {Key::A, Key::S, Key::D, Key::F, Key::G, Key::H, Key::J},
    {Key::Z, Key::X, Key::C, Key::V, Key::B, Key::N, Key::M}
};

static const char* kNames[3][7] = {
    {"Q", "W", "E", "R", "T", "Y", "U"},
    {"A", "S", "D", "F", "G", "H", "J"},
    {"Z", "X", "C", "V", "B", "N", "M"}
};

- (BOOL)isFlipped {
    return YES;
}

- (void)setActiveKeys:(const std::vector<Key>&)keys {
    // Newly-active keys light to full pulse; then decayPulse fades them.
    for (Key key : keys) {
        bool was_active = false;
        for (Key prev : _active) {
            if (prev == key) {
                was_active = true;
                break;
            }
        }
        if (!was_active) {
            _pulse[static_cast<std::size_t>(key)] = 1.0;
        }
    }
    _active = keys;
    self.needsDisplay = YES;
}

- (void)setPreviewKeys:(const std::vector<Key>&)keys {
    _preview = keys;
    self.needsDisplay = YES;
}

- (BOOL)isPreview:(Key)key {
    for (Key k : _preview) {
        if (k == key) {
            return YES;
        }
    }
    return NO;
}

// Called on a timer; returns YES while any glow remains so the HUD keeps
// redrawing.
- (BOOL)decayPulse {
    BOOL any = NO;
    for (int i = 0; i < 21; ++i) {
        if (_pulse[i] > 0.0) {
            _pulse[i] = std::max(0.0, _pulse[i] - 0.12);
            any = YES;
        }
    }
    // Ambient shimmer for the previewed keys; always animating (subtle).
    _shimmer += 0.03;
    if (_shimmer > 1.0) {
        _shimmer -= 1.0;
    }
    if (!_preview.empty()) {
        any = YES;
    }
    if (any) {
        self.needsDisplay = YES;
    }
    return any;
}

- (BOOL)isActive:(Key)key {
    for (Key active : _active) {
        if (active == key) {
            return YES;
        }
    }
    return NO;
}

- (void)layoutGridInBounds:(NSRect)bounds
                      cell:(CGFloat*)out_cell
                        ox:(CGFloat*)out_ox
                        oy:(CGFloat*)out_oy {
    const CGFloat gap = 6.0;
    const CGFloat cell = std::min((bounds.size.width - gap * 6.0) / 7.0,
                                  (bounds.size.height - gap * 2.0) / 3.0);
    const CGFloat grid_w = cell * 7 + gap * 6;
    const CGFloat grid_h = cell * 3 + gap * 2;
    *out_cell = cell;
    *out_ox = (bounds.size.width - grid_w) * 0.5;
    *out_oy = (bounds.size.height - grid_h) * 0.5;
}

- (std::optional<Key>)keyAtPoint:(NSPoint)point {
    const NSRect bounds = self.bounds;
    CGFloat cell = 0.0;
    CGFloat ox = 0.0;
    CGFloat oy = 0.0;
    [self layoutGridInBounds:bounds cell:&cell ox:&ox oy:&oy];
    const CGFloat gap = 6.0;

    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 7; ++col) {
            const NSRect r = NSMakeRect(ox + col * (cell + gap),
                                        oy + row * (cell + gap), cell, cell);
            if (NSPointInRect(point, r)) {
                return kLayout[row][col];
            }
        }
    }
    return std::nullopt;
}

- (void)releaseHeldKey {
    if (!_held.has_value() || _keyboard == nullptr) {
        return;
    }
    _keyboard->keyUp(*_held);
    _held = std::nullopt;
}

- (void)pressKey:(Key)key {
    if (_keyboard == nullptr) {
        return;
    }
    if (_held.has_value() && *_held != key) {
        _keyboard->keyUp(*_held);
    }
    _held = key;
    _pulse[static_cast<std::size_t>(key)] = 1.0;
    _keyboard->keyDown(key);
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent*)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const std::optional<Key> key = [self keyAtPoint:p];
    if (key.has_value()) {
        [self pressKey:*key];
    }
}

- (void)mouseDragged:(NSEvent*)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const std::optional<Key> key = [self keyAtPoint:p];
    if (key.has_value()) {
        [self pressKey:*key];
    } else {
        [self releaseHeldKey];
    }
}

- (void)mouseUp:(NSEvent*)event {
    [self releaseHeldKey];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bounds = self.bounds;
    CGFloat cell = 0.0;
    CGFloat ox = 0.0;
    CGFloat oy = 0.0;
    [self layoutGridInBounds:bounds cell:&cell ox:&ox oy:&oy];
    const CGFloat gap = 6.0;
    const CGFloat radius = cell * 0.26;

    NSColor* g = gold();

    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 7; ++col) {
            const NSRect r = NSMakeRect(ox + col * (cell + gap),
                                        oy + row * (cell + gap), cell, cell);
            const Key key = kLayout[row][col];
            const BOOL held = _held.has_value() && *_held == key;
            const double lit = std::max((double)([self isActive:key] || held),
                                        _pulse[static_cast<std::size_t>(key)]);

            NSBezierPath* face = [NSBezierPath bezierPathWithRoundedRect:r
                                                                xRadius:radius
                                                                yRadius:radius];

            const BOOL preview = (lit <= 0.0) && [self isPreview:key];

            if (lit > 0.0) {
                // Soft glow, then a clean gold fill. No gradient, no gloss.
                const CGFloat spread = 4.0 * lit;
                [[g colorWithAlphaComponent:0.28 * lit] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -spread, -spread)
                                                 xRadius:radius + spread
                                                 yRadius:radius + spread] fill];
                [[g colorWithAlphaComponent:0.35 + 0.65 * lit] setFill];
                [face fill];
            } else if (preview) {
                // Resting hint: the first note's keys glow faintly and breathe,
                // so the hero never reads as a dead grid.
                const double b = 0.10 + 0.06 * (0.5 + 0.5 * std::sin(_shimmer * 2 * M_PI));
                [[g colorWithAlphaComponent:b] setFill];
                [face fill];
                [[g colorWithAlphaComponent:0.35] setStroke];
                face.lineWidth = 1.0;
                [face stroke];
            } else {
                // Idle: near-invisible, just a hairline outline.
                [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.035] setFill];
                [face fill];
                [ink_faint() setStroke];
                face.lineWidth = 1.0;
                [face stroke];
            }

            NSColor* text = lit > 0.35
                ? [NSColor colorWithSRGBRed:0.12 green:0.09 blue:0.03 alpha:1.0]
                : (preview ? [g colorWithAlphaComponent:0.75] : ink_faint());
            NSDictionary* attrs = @{
                NSFontAttributeName:
                    [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: text
            };
            const NSString* label = [NSString stringWithUTF8String:kNames[row][col]];
            const NSSize size = [label sizeWithAttributes:attrs];
            [label drawAtPoint:NSMakePoint(NSMinX(r) + (cell - size.width) * 0.5,
                                           NSMinY(r) + (cell - size.height) * 0.5)
                withAttributes:attrs];
        }
    }
}

@end

// Background panel that forwards drag + hover to the window controller and
// tracks pointer enter/exit for the hover-reveal behaviour.
@protocol PanelMouseDelegate <NSObject>
- (void)panelMouseDown:(NSEvent*)event;
- (void)panelMouseDragged:(NSEvent*)event;
- (void)panelMouseUp:(NSEvent*)event;
- (void)panelPointerInside:(BOOL)inside;
- (void)panelScroll:(CGFloat)deltaY;
- (NSMenu*)panelContextMenu;
@end

@interface DragPanel : NSVisualEffectView
@property(nonatomic, weak) id<PanelMouseDelegate> mouseDelegate;
@end

@implementation DragPanel {
    NSTrackingArea* _tracking;
    CGFloat _scrollAccum;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)event { [_mouseDelegate panelPointerInside:YES]; }
- (void)mouseExited:(NSEvent*)event { [_mouseDelegate panelPointerInside:NO]; }
- (void)mouseDown:(NSEvent*)event { [_mouseDelegate panelMouseDown:event]; }
- (void)mouseDragged:(NSEvent*)event { [_mouseDelegate panelMouseDragged:event]; }
- (void)mouseUp:(NSEvent*)event { [_mouseDelegate panelMouseUp:event]; }

- (void)scrollWheel:(NSEvent*)event {
    // Accumulate so trackpad micro-scrolls don't fire a step each frame.
    _scrollAccum += event.scrollingDeltaY;
    const CGFloat step = 6.0;
    while (std::abs(_scrollAccum) >= step) {
        [_mouseDelegate panelScroll:(_scrollAccum > 0 ? 1.0 : -1.0)];
        _scrollAccum -= (_scrollAccum > 0 ? step : -step);
    }
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    return [_mouseDelegate panelContextMenu];
}

@end

// Thin standalone progress line for the collapsed (mini) HUD.
@interface MiniProgress : NSView
@property(nonatomic) double progress;
@property(nonatomic) BOOL active;   // gold when playing, faint otherwise
@end

@implementation MiniProgress
- (void)setProgress:(double)p { _progress = std::clamp(p, 0.0, 1.0); self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    [ink_faint() setFill];
    NSRectFill(b);
    if (_progress > 0.0) {
        [(_active ? gold() : ink_soft()) setFill];
        NSRectFill(NSMakeRect(0, 0, b.size.width * _progress, b.size.height));
    }
}
@end

// Small status pill: a colored dot + word (playing / paused / idle). Sits by
// the transport so the title row stays clean.
@interface StatusPill : NSView
@property(nonatomic, strong) NSColor* tint;
@property(nonatomic, copy) NSString* text;
@property(nonatomic) BOOL pulsing;   // breathe the dot while playing
@end

@implementation StatusPill {
    double _phase;
}
- (void)setTint:(NSColor*)tint { _tint = tint; self.needsDisplay = YES; }
- (void)setText:(NSString*)text { _text = [text copy]; self.needsDisplay = YES; }
- (void)tick {
    if (_pulsing) { _phase += 0.06; if (_phase > 1) _phase -= 1; self.needsDisplay = YES; }
}
- (NSSize)intrinsicContentSize { return NSMakeSize(12, 12); }
- (void)drawRect:(NSRect)r {
    const NSRect b = self.bounds;
    NSColor* c = _tint ?: ink_faint();
    const CGFloat cx = b.size.width * 0.5;
    const CGFloat cy = b.size.height * 0.5;
    const double a = _pulsing ? (0.55 + 0.45 * (0.5 + 0.5 * std::sin(_phase * 2 * M_PI))) : 1.0;
    // Soft halo while pulsing, then the dot.
    if (_pulsing) {
        [[c colorWithAlphaComponent:0.25 * a] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - 6, cy - 6, 12, 12)] fill];
    }
    const CGFloat d = 6.0;
    [[c colorWithAlphaComponent:a] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - d / 2, cy - d / 2, d, d)] fill];
}
@end

// A faint gold hairline separator.
@interface Hairline : NSView
@end
@implementation Hairline
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 1); }
- (void)drawRect:(NSRect)r {
    [[gold() colorWithAlphaComponent:0.16] setFill];
    NSRectFill(self.bounds);
}
@end

@interface PlayerWindowController () <PanelMouseDelegate>
@end

@implementation PlayerWindowController {
    PlaybackController* _playback;
    Genshin* _genshin;
    Keyboard* _keyboard;
    DragPanel* _panel;
    NSStackView* _content;
    NSView* _expandedSection;
    NSTextField* _titleLabel;
    NSTextField* _metaLabel;
    StatusPill* _statusPill;
    NSTextField* _time;
    NSTextField* _duration;
    NSTextField* _hint;
    ProgressBar* _progress;
    LyreKeyGridView* _key_grid;
    NSButton* _playPause;
    NSButton* _loopButton;
    NSButton* _prevButton;
    NSButton* _nextButton;
    NSButton* _stopButton;
    NSButton* _openButton;
    NSButton* _addButton;
    NSStackView* _libraryRow;
    NSPopUpButton* _songPicker;
    NSButton* _collapseButton;
    NSStackView* _controls;
    NSButton* _speedButton;
    MiniProgress* _miniProgress;   // thin bar shown when collapsed
    NSTimer* _uiTimer;
    id _hotkeyMonitor;
    CGFloat _target_alpha;
    pid_t _genshin_pid;

    BOOL _collapsed;
    BOOL _dragging;
    NSPoint _dragStartMouse;
    NSPoint _dragStartOrigin;
    BOOL _pointerInside;
    // Once the user drags the HUD, remember its position as an offset from the
    // game window's top-right corner so it still follows the game but no longer
    // snaps back to the default dock.
    BOOL _hasUserOffset;
    NSSize _userOffset;

    BOOL _autoPauseOnBlur;         // auto-pause when Genshin loses focus
    BOOL _wasFocused;              // edge-detect focus loss
}

- (instancetype)initWithPlayback:(PlaybackController*)playback
                         genshin:(Genshin*)genshin
                        keyboard:(Keyboard*)keyboard
                           title:(NSString*)title
                             bpm:(NSInteger)bpm {
    NSPanel* window = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, kW, kH)
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self == nil) {
        return nil;
    }

    _playback = playback;
    _genshin = genshin;
    _keyboard = keyboard;
    _target_alpha = 1.0;
    _genshin_pid = 0;
    _dragging = NO;
    _pointerInside = NO;

    _collapsed = settings::get_bool(kSettingCollapsed, false);
    // Auto-pause defaults ON (first launch has no stored value).
    _autoPauseOnBlur = settings::get_bool(kSettingAutoPause, true);
    _wasFocused = NO;

    _playback->set_countdown(std::chrono::milliseconds(3000));

    // Auto-advance to the next queued song when one finishes naturally.
    __weak PlayerWindowController* weak = self;
    _playback->set_on_finished([weak] {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak songFinished];
        });
    });

    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = YES;
    window.level = NSScreenSaverWindowLevel;
    window.floatingPanel = YES;
    window.becomesKeyOnlyIfNeeded = YES;
    window.hidesOnDeactivate = NO;
    window.movableByWindowBackground = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorStationary;

    _panel = [[DragPanel alloc] initWithFrame:window.contentView.bounds];
    _panel.mouseDelegate = self;
    _panel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _panel.material = NSVisualEffectMaterialUnderWindowBackground;
    _panel.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _panel.state = NSVisualEffectStateActive;
    _panel.wantsLayer = YES;
    _panel.layer.cornerRadius = 16.0;
    _panel.layer.masksToBounds = YES;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = [NSColor colorWithSRGBRed:0.85 green:0.71 blue:0.42
                                                   alpha:0.14].CGColor;

    // Tint the blur toward a warm-dark game tone.
    NSView* tint = [[NSView alloc] initWithFrame:_panel.bounds];
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tint.wantsLayer = YES;
    tint.layer.backgroundColor =
        [NSColor colorWithSRGBRed:0.06 green:0.06 blue:0.08 alpha:0.55].CGColor;
    [_panel addSubview:tint];

    // ---- Header: title, meta, chevron, close. No badge, no glow. ----
    _titleLabel = [NSTextField labelWithString:title ?: @"Untitled"];
    _titleLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _titleLabel.textColor = ink();
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.toolTip = title;

    NSString* meta = bpm > 0 ? [NSString stringWithFormat:@"%ld BPM", (long)bpm] : @"Lyre";
    _metaLabel = [NSTextField labelWithString:meta];
    _metaLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium];
    _metaLabel.textColor = ink_soft();

    // Add-song button lives in the header chrome once a playlist exists.
    _addButton = [self chromeButton:@"plus" action:@selector(openSongs:)
                            tooltip:@"Add songs"];
    _addButton.hidden = YES;
    _collapseButton = [self chromeButton:@"chevron.up" action:@selector(toggleCollapse)
                                 tooltip:@"Collapse / expand"];
    NSButton* hide = [self chromeButton:@"xmark" action:@selector(hideHud)
                                tooltip:@"Close and stop"];
    hide.accessibilityLabel = @"Close HUD and stop playback";

    NSStackView* title_col = [NSStackView stackViewWithViews:@[_titleLabel, _metaLabel]];
    title_col.orientation = NSUserInterfaceLayoutOrientationVertical;
    title_col.spacing = 2;
    title_col.alignment = NSLayoutAttributeLeading;

    NSStackView* chrome = [NSStackView stackViewWithViews:@[
        _addButton, _collapseButton, hide]];
    chrome.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chrome.spacing = 6;
    chrome.alignment = NSLayoutAttributeCenterY;

    NSView* header_spacer = [[NSView alloc] init];
    [header_spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header_spacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView* header = [NSStackView stackViewWithViews:@[
        title_col, header_spacer, chrome]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.spacing = 8;
    header.alignment = NSLayoutAttributeCenterY;
    header.distribution = NSStackViewDistributionFill;
    [title_col setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [chrome setContentHuggingPriority:NSLayoutPriorityRequired
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    Hairline* rule = [[Hairline alloc] init];
    rule.translatesAutoresizingMaskIntoConstraints = NO;

    // Library row: a big "Open songs…" when empty; the playlist picker once
    // loaded (adding more happens via the header +).
    _openButton = [NSButton buttonWithTitle:@"Open songs…"
                                     target:self
                                     action:@selector(openSongs:)];
    _openButton.bezelStyle = NSBezelStyleRounded;
    _openButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _openButton.contentTintColor = gold();
    _openButton.toolTip = @"Add .genshinsheet files or folders";

    _songPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _songPicker.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    _songPicker.toolTip = @"Playlist";
    _songPicker.target = self;
    _songPicker.action = @selector(songPickerChanged:);
    _songPicker.hidden = YES;

    _libraryRow = [NSStackView stackViewWithViews:@[_openButton, _songPicker]];
    _libraryRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _libraryRow.spacing = 8;
    _libraryRow.distribution = NSStackViewDistributionFillEqually;
    _libraryRow.alignment = NSLayoutAttributeCenterY;
    NSStackView* library_row = _libraryRow;

    // ---- Hero: the lyre grid, large. ----
    _key_grid = [[LyreKeyGridView alloc] initWithFrame:NSMakeRect(0, 0, kW - 32, 108)];
    _key_grid.keyboard = keyboard;
    _key_grid.translatesAutoresizingMaskIntoConstraints = NO;
    [_key_grid.heightAnchor constraintEqualToConstant:108].active = YES;

    // ---- Seek: elapsed  [====bar====]  duration, one tight row ----
    _progress = [[ProgressBar alloc] initWithFrame:NSMakeRect(0, 0, kW - 120, 9)];
    _progress.translatesAutoresizingMaskIntoConstraints = NO;
    _progress.seekTarget = self;
    _progress.seekAction = @selector(seekTo:);
    [_progress.heightAnchor constraintEqualToConstant:9].active = YES;

    _time = [NSTextField labelWithString:@"0:00"];
    _time.font = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium];
    _time.textColor = ink_soft();
    [_time setContentHuggingPriority:NSLayoutPriorityRequired
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    _duration = [NSTextField labelWithString:@"0:00"];
    _duration.font = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium];
    _duration.textColor = ink_faint();
    _duration.alignment = NSTextAlignmentRight;
    [_duration setContentHuggingPriority:NSLayoutPriorityRequired
                         forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView* seek_row = [NSStackView stackViewWithViews:@[_time, _progress, _duration]];
    seek_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    seek_row.spacing = 8;
    seek_row.alignment = NSLayoutAttributeCenterY;
    [_progress setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Status pill (dot + word) + speed chip sit on the transport row.
    _statusPill = [[StatusPill alloc] init];
    _statusPill.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusPill.widthAnchor constraintEqualToConstant:12].active = YES;  // dot only

    // Speed control: click to cycle preset speeds, or scroll over the HUD for
    // fine steps. Shows the current rate; gold when not 1×.
    _speedButton = [NSButton buttonWithTitle:@"1×"
                                      target:self
                                      action:@selector(cycleSpeed)];
    _speedButton.bezelStyle = NSBezelStyleInline;
    _speedButton.bordered = NO;
    _speedButton.font = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightSemibold];
    _speedButton.toolTip = @"Playback speed — click to cycle, scroll to fine-tune";
    _speedButton.contentTintColor = ink_soft();
    [_speedButton.widthAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;

    // ---- Transport: flat, quiet. Play is a gold glyph, no disc/ring. ----
    _prevButton = [self transportButton:@"backward.fill" size:12 gold:NO
                                 action:@selector(previousSong) tooltip:@"Previous"];
    _prevButton.hidden = YES;
    _loopButton = [self transportButton:@"repeat" size:12 gold:NO
                                 action:@selector(toggleLoop) tooltip:@"Loop"];
    _playPause = [self transportButton:@"play.fill" size:18 gold:YES
                                action:@selector(togglePlayPause:) tooltip:@"Play / Pause"];
    _stopButton = [self transportButton:@"stop.fill" size:12 gold:NO
                                 action:@selector(stopPlayback:) tooltip:@"Stop"];
    _nextButton = [self transportButton:@"forward.fill" size:12 gold:NO
                                 action:@selector(nextSong) tooltip:@"Next"];
    _nextButton.hidden = YES;

    _controls = [NSStackView stackViewWithViews:@[
        _prevButton, _loopButton, _playPause, _stopButton, _nextButton]];
    _controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _controls.spacing = 16;
    _controls.alignment = NSLayoutAttributeCenterY;

    // Transport row: controls are hard-centered; status pill floats at the
    // leading edge and the speed chip at the trailing edge, so the play button
    // stays dead-center regardless of the flanks' widths.
    NSView* transport_row = [[NSView alloc] init];
    transport_row.translatesAutoresizingMaskIntoConstraints = NO;
    _statusPill.translatesAutoresizingMaskIntoConstraints = NO;
    _speedButton.translatesAutoresizingMaskIntoConstraints = NO;
    _controls.translatesAutoresizingMaskIntoConstraints = NO;
    [transport_row addSubview:_statusPill];
    [transport_row addSubview:_controls];
    [transport_row addSubview:_speedButton];
    [NSLayoutConstraint activateConstraints:@[
        [_controls.centerXAnchor constraintEqualToAnchor:transport_row.centerXAnchor],
        [_controls.centerYAnchor constraintEqualToAnchor:transport_row.centerYAnchor],
        [_controls.topAnchor constraintEqualToAnchor:transport_row.topAnchor],
        [_controls.bottomAnchor constraintEqualToAnchor:transport_row.bottomAnchor],
        [_statusPill.leadingAnchor constraintEqualToAnchor:transport_row.leadingAnchor],
        [_statusPill.centerYAnchor constraintEqualToAnchor:transport_row.centerYAnchor],
        [_speedButton.trailingAnchor constraintEqualToAnchor:transport_row.trailingAnchor],
        [_speedButton.centerYAnchor constraintEqualToAnchor:transport_row.centerYAnchor],
    ]];

    _hint = [NSTextField labelWithString:@""];
    _hint.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
    _hint.textColor = ink_faint();
    _hint.alignment = NSTextAlignmentCenter;
    _hint.lineBreakMode = NSLineBreakByTruncatingTail;

    NSStackView* expanded = [NSStackView stackViewWithViews:@[
        library_row, _key_grid, seek_row, transport_row, _hint]];
    expanded.orientation = NSUserInterfaceLayoutOrientationVertical;
    expanded.alignment = NSLayoutAttributeCenterX;
    expanded.spacing = 10;
    expanded.translatesAutoresizingMaskIntoConstraints = NO;
    _expandedSection = expanded;

    _content = [NSStackView stackViewWithViews:@[header, rule, expanded]];
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    _content.orientation = NSUserInterfaceLayoutOrientationVertical;
    _content.alignment = NSLayoutAttributeLeading;
    _content.spacing = 11;
    [_content setCustomSpacing:9 afterView:header];
    [_content setCustomSpacing:11 afterView:rule];
    [_panel addSubview:_content];

    for (NSView* row in @[library_row, _key_grid, seek_row, transport_row, _hint]) {
        [row.widthAnchor constraintEqualToAnchor:expanded.widthAnchor].active = YES;
    }

    [NSLayoutConstraint activateConstraints:@[
        [_content.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:16],
        [_content.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-16],
        [_content.topAnchor constraintEqualToAnchor:_panel.topAnchor constant:15],
        [header.widthAnchor constraintEqualToAnchor:_content.widthAnchor],
        [rule.widthAnchor constraintEqualToAnchor:_content.widthAnchor],
        [expanded.widthAnchor constraintEqualToAnchor:_content.widthAnchor],
    ]];
    NSLayoutConstraint* bottom =
        [_content.bottomAnchor constraintLessThanOrEqualToAnchor:_panel.bottomAnchor
                                                        constant:-13];
    bottom.priority = NSLayoutPriorityDefaultHigh;
    bottom.active = YES;

    window.contentView = _panel;

    // Mini progress line, pinned to the panel bottom; only shown when collapsed.
    _miniProgress = [[MiniProgress alloc] initWithFrame:NSZeroRect];
    _miniProgress.translatesAutoresizingMaskIntoConstraints = NO;
    _miniProgress.hidden = YES;
    [_panel addSubview:_miniProgress];
    [NSLayoutConstraint activateConstraints:@[
        [_miniProgress.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_miniProgress.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_miniProgress.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor],
        [_miniProgress.heightAnchor constraintEqualToConstant:2.5],
    ]];

    _uiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                target:self selector:@selector(refresh)
                                              userInfo:nil repeats:YES];

    // Global hotkeys work while Genshin has focus. ⌘⌥Space play/pause,
    // ⌘⌥. stop, ⌘⌥L loop, ⌘⌥H show/raise the HUD.
    __weak PlayerWindowController* weakSelf = self;
    _hotkeyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^(NSEvent* e) {
        [weakSelf handleGlobalKey:e];
    }];

    [self applyCollapseState:NO];
    [self placeHudInitially];
    [self refresh];
    return self;
}

- (void)dealloc {
    if (_hotkeyMonitor != nil) {
        [NSEvent removeMonitor:_hotkeyMonitor];
    }
    _playback->set_on_finished(nullptr);
    [_uiTimer invalidate];
}

#pragma mark - Small builders

- (NSButton*)chromeButton:(NSString*)name action:(SEL)action tooltip:(NSString*)tip {
    NSButton* b = [NSButton buttonWithImage:tinted_symbol(name, 10, NSFontWeightSemibold, ink_soft())
                                     target:self action:action];
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip = tip;
    return b;
}

- (NSButton*)transportButton:(NSString*)name size:(CGFloat)size gold:(BOOL)isGold
                      action:(SEL)action tooltip:(NSString*)tip {
    NSColor* color = isGold ? gold() : ink_soft();
    NSButton* b = [NSButton buttonWithImage:tinted_symbol(name, size, NSFontWeightMedium, color)
                                     target:self action:action];
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip = tip;
    b.accessibilityLabel = tip;
    return b;
}

#pragma mark - Transport

- (void)startPlayback {
    if (_playback->note_count() == 0) {
        [self openSongs:nil];
        return;
    }
    _genshin->activate_application();
    _playback->play();
    [self refresh];
}

- (void)togglePlayPause:(id)sender {
    const PlaybackState state = _playback->snapshot().state;
    if (state == PlaybackState::playing || state == PlaybackState::countdown) {
        _playback->pause();
        [self refresh];
    } else if (_playback->note_count() == 0) {
        [self openSongs:nil];
    } else {
        [self startPlayback];
    }
}

- (void)stopPlayback:(id)sender {
    _playback->stop();
    [self refresh];
}

- (void)seekTo:(NSNumber*)fraction {
    _playback->seek_fraction(fraction.doubleValue);
    [self refresh];
}

- (void)toggleLoop {
    _playback->toggle_loop();
    [self refresh];
}

#pragma mark - Speed / auto-advance / hotkeys

- (void)panelScroll:(CGFloat)deltaY {
    _playback->nudge_speed(deltaY > 0 ? 0.05 : -0.05);
    [self refresh];
}

// Click the speed button → jump to the next preset above the current speed,
// wrapping back to the slowest after the fastest.
- (void)cycleSpeed {
    const double current = _playback->snapshot().speed;
    const int n = sizeof(kSpeedPresets) / sizeof(kSpeedPresets[0]);
    double next = kSpeedPresets[0];
    for (int i = 0; i < n; ++i) {
        if (kSpeedPresets[i] > current + 0.001) {
            next = kSpeedPresets[i];
            break;
        }
    }
    _playback->set_speed(next);
    [self refresh];
}

- (void)songFinished {
    // Natural end. If a next song exists, advance and keep playing.
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        [self refresh];
        return;
    }
    const NSInteger idx = [q queueCurrentIndex];
    if (idx + 1 < [q queueCount]) {
        [self loadQueueIndex:idx + 1 autoplay:YES];
    } else {
        [self refresh];
    }
}

- (void)toggleAutoPause:(id)sender {
    _autoPauseOnBlur = !_autoPauseOnBlur;
    settings::set_bool(kSettingAutoPause, _autoPauseOnBlur);
}

- (NSMenu*)panelContextMenu {
    NSMenu* menu = [[NSMenu alloc] init];
    NSMenuItem* ap = [[NSMenuItem alloc] initWithTitle:@"Auto-pause when Genshin loses focus"
                                                action:@selector(toggleAutoPause:)
                                         keyEquivalent:@""];
    ap.target = self;
    ap.state = _autoPauseOnBlur ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:ap];

    NSMenuItem* reset = [[NSMenuItem alloc] initWithTitle:@"Reset speed to 1×"
                                                   action:@selector(resetSpeed:)
                                            keyEquivalent:@""];
    reset.target = self;
    [menu addItem:reset];
    return menu;
}

- (void)resetSpeed:(id)sender {
    _playback->set_speed(1.0);
    [self refresh];
}

- (void)handleGlobalKey:(NSEvent*)event {
    const NSEventModifierFlags flags =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) == 0 ||
        (flags & NSEventModifierFlagOption) == 0) {
        return;
    }
    NSString* chars = event.charactersIgnoringModifiers ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([chars isEqualToString:@" "]) {
            [self togglePlayPause:nil];
        } else if ([chars isEqualToString:@"."]) {
            [self stopPlayback:nil];
        } else if ([chars isEqualToString:@"l"]) {
            [self toggleLoop];
        } else if ([chars isEqualToString:@"h"]) {
            [self.window orderFrontRegardless];
        }
    });
}

#pragma mark - Queue

- (void)setQueueDelegate:(id<PlayerQueueDelegate>)queueDelegate {
    _queueDelegate = queueDelegate;
    [self reloadQueuePicker];   // toggles prev/next by queue count
    [self reloadQueueMetadata];
}

- (void)reloadQueuePicker {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    [_songPicker removeAllItems];
    const NSInteger count = q != nil ? [q queueCount] : 0;

    // Empty → big "Open songs…" button. Loaded → playlist picker + header "+".
    const BOOL loaded = count > 0;
    _openButton.hidden = loaded;
    _songPicker.hidden = !loaded;
    _addButton.hidden = !loaded;
    // Prev/next only make sense with more than one song. Re-evaluated here so
    // adding songs later (via +) reveals them.
    _prevButton.hidden = count <= 1;
    _nextButton.hidden = count <= 1;
    if (!loaded) {
        return;
    }
    for (NSInteger i = 0; i < count; ++i) {
        [_songPicker addItemWithTitle:[q queueTitleAtIndex:i]];
    }
    NSInteger idx = [q queueCurrentIndex];
    if (idx < 0) {
        idx = 0;
    }
    if (idx < count) {
        [_songPicker selectItemAtIndex:idx];
    }
}

- (void)reloadQueueMetadata {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    const NSInteger count = [q queueCount];
    if (count == 0) {
        _titleLabel.stringValue = @"No song selected";
        _titleLabel.toolTip = @"No song selected";
        _metaLabel.stringValue = @"Open songs to begin";
        return;
    }
    const NSInteger idx = [q queueCurrentIndex];
    NSString* title = idx >= 0 ? ([q queueTitleAtIndex:idx] ?: @"Untitled")
                               : @"Choose a song";
    const NSInteger bpm = idx >= 0 ? [q queueBpmAtIndex:idx] : 0;
    _titleLabel.stringValue = title;
    _titleLabel.toolTip = title;
    NSString* meta = bpm > 0 ? [NSString stringWithFormat:@"%ld BPM", (long)bpm] : @"Lyre";
    if (count > 1 && idx >= 0) {
        meta = [NSString stringWithFormat:@"%@   %ld/%ld", meta,
                (long)(idx + 1), (long)count];
    } else if (idx < 0) {
        meta = [NSString stringWithFormat:@"%ld songs", (long)count];
    }
    _metaLabel.stringValue = meta;
}

- (void)loadQueueIndex:(NSInteger)index autoplay:(BOOL)autoplay {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil || index < 0 || index >= [q queueCount]) {
        return;
    }
    _playback->stop();
    if (![q queueLoadIndex:index]) {
        return;
    }
    [self reloadQueuePicker];
    [self reloadQueueMetadata];
    [self refresh];
    if (autoplay) {
        [self startPlayback];
    }
}

- (void)previousSong {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    const BOOL wasPlaying = _playback->snapshot().state != PlaybackState::stopped;
    [self loadQueueIndex:[q queueCurrentIndex] - 1 autoplay:wasPlaying];
}

- (void)nextSong {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    const BOOL wasPlaying = _playback->snapshot().state != PlaybackState::stopped;
    [self loadQueueIndex:[q queueCurrentIndex] + 1 autoplay:wasPlaying];
}

- (void)songPickerChanged:(NSPopUpButton*)sender {
    [self loadQueueIndex:sender.indexOfSelectedItem autoplay:NO];
}

- (void)openSongs:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"genshinsheet"]
    ];
    panel.message = @"Choose .genshinsheet files or folders";
    panel.prompt = @"Add";
    [panel beginSheetModalForWindow:self.window
                    completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK) {
            return;
        }
        NSMutableArray<NSString*>* paths = [NSMutableArray array];
        for (NSURL* url in panel.URLs) {
            if (url.path != nil) {
                [paths addObject:url.path];
            }
        }
        id<PlayerQueueDelegate> q = self.queueDelegate;
        if (q == nil || paths.count == 0) {
            return;
        }
        const BOOL hadSong = _playback->note_count() > 0;
        const NSInteger added = [q queueAddPaths:paths];
        if (added == 0) {
            return;
        }
        if (!hadSong) {
            [self loadQueueIndex:0 autoplay:NO];
        } else {
            [self reloadQueuePicker];
            [self reloadQueueMetadata];
        }
    }];
}

#pragma mark - Collapse / drag

- (void)toggleCollapse {
    _collapsed = !_collapsed;
    settings::set_bool(kSettingCollapsed, _collapsed);
    [self applyCollapseState:YES];
}

- (void)applyCollapseState:(BOOL)animated {
    _expandedSection.hidden = _collapsed;
    _miniProgress.hidden = !_collapsed;
    _collapseButton.image = tinted_symbol(_collapsed ? @"chevron.down" : @"chevron.up",
                                          10, NSFontWeightSemibold, ink_soft());
    const CGFloat target_h = _collapsed ? kMiniH : kH;
    NSRect frame = self.window.frame;
    frame.origin.y = NSMaxY(frame) - target_h;
    frame.size.height = target_h;
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
            ctx.duration = 0.18;
            [self.window.animator setFrame:frame display:YES];
        } completionHandler:nil];
    } else {
        [self.window setFrame:frame display:YES];
    }
}

- (CGFloat)currentHeight {
    return _collapsed ? kMiniH : kH;
}

// Where the HUD should sit for a given game frame: the user's dragged offset
// from the game's top-right corner if they've moved it, else the default dock.
- (NSPoint)hudOriginForGameFrame:(NSRect)game {
    if (_hasUserOffset) {
        const NSPoint corner = NSMakePoint(NSMaxX(game), NSMaxY(game));
        NSPoint origin = NSMakePoint(corner.x + _userOffset.width,
                                     corner.y + _userOffset.height);
        // Keep it on-screen.
        const NSRect vf = screen_for_rect(game).visibleFrame;
        origin.x = std::clamp(origin.x, NSMinX(vf), NSMaxX(vf) - kW);
        origin.y = std::clamp(origin.y, NSMinY(vf), NSMaxY(vf) - [self currentHeight]);
        return origin;
    }
    return top_right_hud_origin(game, [self currentHeight]);
}

#pragma mark - HUD placement

- (void)placeHudInitially {
    [self placeHudNearGenshinWithRetries:8];
}

- (void)placeHudNearGenshinWithRetries:(int)retries_left {
    _genshin_pid = genshin_pid();
    std::optional<NSRect> game;
    if (_genshin_pid != 0) {
        game = game_frame(_genshin_pid, nullptr);
    }

    if (!game.has_value() && retries_left > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self placeHudNearGenshinWithRetries:retries_left - 1];
        });
        return;
    }

    const CGFloat h = [self currentHeight];
    NSPoint origin;
    if (game.has_value()) {
        origin = [self hudOriginForGameFrame:*game];
    } else {
        const NSRect vf = NSScreen.mainScreen.visibleFrame;
        origin = NSMakePoint(NSMaxX(vf) - kW - 20, NSMaxY(vf) - h - 20);
    }

    [self.window setFrame:NSMakeRect(origin.x, origin.y, kW, h) display:YES];
    self.window.alphaValue = 1.0;
    [self.window orderFrontRegardless];
}

// The × closes the HUD and quits the program.
- (void)hideHud {
    _playback->stop();
    [_uiTimer invalidate];
    [self.window orderOut:nil];
    [NSApp terminate:nil];
}

#pragma mark - Dragging

- (void)panelPointerInside:(BOOL)inside {
    _pointerInside = inside;
    [self updateFocusAppearance];
}

- (void)panelMouseDown:(NSEvent*)event {
    _dragging = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _dragStartOrigin = self.window.frame.origin;
}

- (void)panelMouseDragged:(NSEvent*)event {
    if (!_dragging) {
        return;
    }
    const NSPoint now = NSEvent.mouseLocation;
    NSRect frame = self.window.frame;
    frame.origin = NSMakePoint(_dragStartOrigin.x + (now.x - _dragStartMouse.x),
                               _dragStartOrigin.y + (now.y - _dragStartMouse.y));
    [self.window setFrameOrigin:frame.origin];
}

- (void)panelMouseUp:(NSEvent*)event {
    if (!_dragging) {
        return;
    }
    _dragging = NO;

    // Remember where the user parked it, as an offset from the game's top-right
    // corner, so the follow logic keeps that spot instead of snapping to dock.
    if (_genshin_pid != 0) {
        const std::optional<NSRect> game = game_frame(_genshin_pid, nullptr);
        if (game.has_value()) {
            const NSPoint origin = self.window.frame.origin;
            _userOffset = NSMakeSize(origin.x - NSMaxX(*game),
                                     origin.y - NSMaxY(*game));
            _hasUserOffset = YES;
        }
    }
}

#pragma mark - Refresh

// Follow the Genshin window and show/hide the HUD with focus. Runs on a timer
// so the HUD travels with the game and vanishes cleanly when Genshin isn't
// frontmost (no faint ghost hovering over other apps).
- (void)updateFocusAppearance {
    if (_dragging) {
        return;  // don't fight an active drag
    }
    if (_genshin_pid == 0 ||
        [NSRunningApplication runningApplicationWithProcessIdentifier:_genshin_pid] == nil) {
        _genshin_pid = genshin_pid();
    }
    const BOOL focused = genshin_is_focused(_genshin_pid);

    // Auto-pause when Genshin loses focus to ANOTHER app — but not for the
    // brief blur caused by interacting with the HUD itself (pointer inside),
    // otherwise pressing play would instantly pause playback.
    if (_autoPauseOnBlur && _wasFocused && !focused && !_pointerInside) {
        if (_playback->snapshot().state == PlaybackState::playing) {
            _playback->pause();
        }
    }
    // Only update the focus edge-tracker once the pointer has left the HUD, so
    // a HUD click doesn't register as a focus loss on the next real blur.
    if (!_pointerInside) {
        _wasFocused = focused;
    }

    // Keep the HUD visible while the pointer is over it (so you can click
    // controls even though clicking the HUD unfocuses Genshin momentarily).
    const BOOL shouldShow = focused || _pointerInside;

    if (!shouldShow) {
        if (self.window.isVisible) {
            [self.window orderOut:nil];
        }
        return;
    }

    // Follow the current game window position (keeping the user's dragged
    // offset, if any).
    if (_genshin_pid != 0) {
        const std::optional<NSRect> game = game_frame(_genshin_pid, nullptr);
        if (game.has_value()) {
            const NSPoint want = [self hudOriginForGameFrame:*game];
            const NSPoint have = self.window.frame.origin;
            if (std::abs(want.x - have.x) > 0.5 || std::abs(want.y - have.y) > 0.5) {
                [self.window setFrameOrigin:want];
            }
        }
    }

    self.window.alphaValue = 1.0;
    if (!self.window.isVisible) {
        [self.window orderFrontRegardless];
    }
}

- (void)refresh {
    const PlaybackSnapshot s = _playback->snapshot();
    [_key_grid decayPulse];
    [_statusPill tick];

    _progress.progress = s.progress;
    _miniProgress.progress = s.progress;
    _miniProgress.active = (s.state == PlaybackState::playing ||
                            s.state == PlaybackState::countdown);
    _time.stringValue = format_time(s.elapsed);
    _duration.stringValue = format_time(s.duration);
    [_key_grid setActiveKeys:s.active_keys];

    // Idle hint: when stopped with a song loaded, glow the current note's keys
    // faintly so the grid has life at rest.
    if (s.state == PlaybackState::stopped && !s.current_note.empty()) {
        [_key_grid setPreviewKeys:keys_from_label(s.current_note)];
    } else {
        [_key_grid setPreviewKeys:{}];
    }

    const BOOL normalSpeed = std::abs(s.speed - 1.0) < 0.001;
    _speedButton.title = format_speed(s.speed);
    _speedButton.contentTintColor = normalSpeed ? ink_soft() : gold();

    _loopButton.image = tinted_symbol(@"repeat", 12, NSFontWeightMedium,
                                      s.loop ? gold() : ink_soft());

    const BOOL empty = _playback->note_count() == 0;

    long long countdown_secs = 0;
    switch (s.state) {
        case PlaybackState::countdown:
            countdown_secs = (s.countdown_remaining.count() + 999) / 1000;
            _statusPill.tint = gold();
            _statusPill.pulsing = YES;
            _statusPill.toolTip = @"counting in";
            _playPause.image = tinted_symbol(@"pause.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::playing:
            _statusPill.tint = gold();
            _statusPill.pulsing = YES;
            _statusPill.toolTip = @"playing";
            _playPause.image = tinted_symbol(@"pause.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::paused:
            _statusPill.tint = ink_soft();
            _statusPill.pulsing = NO;
            _statusPill.toolTip = @"paused";
            _playPause.image = tinted_symbol(@"play.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::stopped:
            _statusPill.tint = ink_faint();
            _statusPill.pulsing = NO;
            _statusPill.toolTip = empty ? @"no song" : @"idle";
            _playPause.image = tinted_symbol(@"play.fill", 18, NSFontWeightMedium, gold());
            break;
    }

    // Dim the transport/seek when there is nothing loaded.
    const CGFloat controlsAlpha = empty ? 0.35 : 1.0;
    _controls.alphaValue = controlsAlpha;
    _progress.alphaValue = controlsAlpha;

    if (s.state == PlaybackState::countdown) {
        _hint.textColor = gold();
        _hint.stringValue = [NSString stringWithFormat:@"starting in %lld…", countdown_secs];
    } else if (empty && s.state == PlaybackState::stopped) {
        _hint.textColor = ink_faint();
        _hint.stringValue = @"open a song to begin";
    } else {
        _hint.stringValue = @"";
    }

    [self updateFocusAppearance];
}

@end
