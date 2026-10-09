#import "PlayerWindow.h"
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <optional>
#include <vector>

#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

#include <nlohmann/json.hpp>

#include "genshin.h"
#include "keyboard.h"
#include "key.h"
#include "playback_controller.h"
#include "practice_dashboard.h"
#include "settings.h"
#include "strings.h"
#include "theme.h"

namespace {

constexpr CGFloat kW = 260.0;
constexpr CGFloat kH = 252.0;       // expanded height
constexpr CGFloat kMiniH = 62.0;    // collapsed: header only
// Gap from game window edges (top-right dock).
constexpr CGFloat kTopInset = 40.0;
constexpr CGFloat kRightInset = 56.0;
// Local settings keys (hud-settings.json next to the binary).
constexpr const char* kSettingCollapsed = "collapsed";
constexpr const char* kSettingAutoPause = "auto_pause_on_blur";
constexpr const char* kSettingPlayInBackground = "play_in_background";
constexpr const char* kSettingLearn = "learn_mode";
constexpr const char* kSettingTempoPractice = "tempo_practice";
constexpr const char* kSettingAutoSpeed = "practice_auto_speed";
constexpr const char* kSettingLockMastered = "practice_lock_until_mastered";
constexpr const char* kSettingRampStart = "practice_ramp_start_pct";   // 0 = current speed
constexpr const char* kSettingDifficulty = "practice_difficulty";      // 0 easy, 1 normal, 2 strict
constexpr const char* kSettingShowSummary = "practice_show_summary";

// Timing windows for each practice difficulty. Strict also caps chord
// assembly so both keys of a chord must land close together.
PracticeTimingWindows timing_windows_for_difficulty(NSInteger difficulty) {
    PracticeTimingWindows windows;
    switch (difficulty) {
        case 0:  // Easy
            windows.early = std::chrono::milliseconds(350);
            windows.miss = std::chrono::milliseconds(700);
            break;
        case 2:  // Strict
            windows.early = std::chrono::milliseconds(120);
            windows.miss = std::chrono::milliseconds(250);
            windows.chord = std::chrono::milliseconds(120);
            break;
        default:  // Normal (the historical defaults)
            break;
    }
    return windows;
}
constexpr const char* kSettingShowUpcoming = "practice_show_upcoming";
constexpr const char* kSettingCountIn = "count_in_seconds";
constexpr const char* kSettingLatencyOffset = "practice_latency_offset_ms";
constexpr const char* kSettingReducedMotion = "reduced_motion";
constexpr const char* kSettingMetronome = "practice_metronome";        // legacy bool
constexpr const char* kSettingMetronomeMode = "practice_metronome_mode"; // 0 off, 1 cues, 2 beat

// One stop in a "drill weakest phrases" run: a playlist song and one of its
// inferred phrases, with the best accuracy that made it a drill candidate.
struct DrillItem {
    NSInteger song;
    std::size_t phrase;
    double best;
};
constexpr std::size_t kDrillLength = 5;
// Phrases at or above this best accuracy are considered solid, not drilled.
constexpr double kDrillThreshold = 0.95;
constexpr const char* kSettingHighContrast = "high_contrast";
constexpr const char* kSettingFavoritesOnly = "favorites_only";
constexpr const char* kSettingTheme = "theme";
constexpr const char* kSettingLang = "language";

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

std::optional<Key> key_from_event(NSEvent* event) {
    NSString* characters = event.charactersIgnoringModifiers.uppercaseString;
    if (characters.length != 1) {
        return std::nullopt;
    }
    static const NSString* key_chars = @"QWERTYUASDFGHJZXCVBNM";
    const NSRange range = [key_chars rangeOfString:characters];
    if (range.location == NSNotFound) {
        return std::nullopt;
    }
    return static_cast<Key>(range.location);
}

// --- Palette: one accent used sparingly, driven by the active theme. The
// names stay (gold/ink) for brevity though the accent may not be gold.
NSColor* gold() { return themes::current().accent; }
NSColor* ink() { return themes::current().ink; }
NSColor* ink_soft() { return themes::current().ink_soft; }
NSColor* ink_faint() { return themes::current().ink_faint; }
NSColor* on_accent() { return themes::current().on_accent; }

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

bool contains_genshin(NSString* value) {
    if (value == nil) {
        return false;
    }
    // Match the global client plus the CN release, whose app / window name is
    // "YuanShen" / "原神" and contains none of the string "genshin".
    for (NSString* needle in @[@"genshin", @"yuanshen", @"原神"]) {
        if ([value rangeOfString:needle
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return true;
        }
    }
    return false;
}

// Resolve the Genshin process id, or 0 if not running. Shared with the
// keyboard so the HUD's focus checks and the keystroke target always agree.
pid_t genshin_pid() {
    return find_genshin_pid();
}

bool genshin_is_focused(pid_t pid) {
    if (pid == 0) {
        return false;
    }
    NSRunningApplication* app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app == nil) {
        return false;
    }
    NSRunningApplication* frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    return app.isActive ||
        (frontmost != nil && frontmost.processIdentifier == pid);
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
            if (require_name && !contains_genshin(window_name)) {
                return;
            }
        } else if (!contains_genshin(window_name) &&
                   !contains_genshin(window[(id)kCGWindowOwnerName])) {
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

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSString*)accessibilityRole {
    return NSAccessibilityGroupRole;
}

- (NSString*)accessibilityLabel {
    return @"Lyre key grid";
}

- (BOOL)acceptsFirstResponder {
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
@property(nonatomic, weak) id practiceTarget;
@property(nonatomic) SEL practiceAction;
@property(nonatomic) BOOL practiceMode;
@property(nonatomic) BOOL reducedMotion;
@property(nonatomic) BOOL highContrast;
- (void)setActiveKeys:(const std::vector<Key>&)keys;
- (void)setPreviewKeys:(const std::vector<Key>&)keys;  // faint hint when idle
- (void)releaseHeldKey;
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
    // Ambient shimmer is optional so the HUD can remain calm for motion-
    // sensitive users.
    if (!_reducedMotion) {
        _shimmer += 0.03;
        if (_shimmer > 1.0) {
            _shimmer -= 1.0;
        }
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
    // A drag generates many mouse events over the same cell. Treat the held
    // key as one input so practice mode cannot advance twice from one click.
    if (_held.has_value() && *_held == key) {
        return;
    }
    if (_held.has_value() && *_held != key) {
        _keyboard->keyUp(*_held);
    }
    _held = key;
    _pulse[static_cast<std::size_t>(key)] = 1.0;

    // Recognize the practice input before posting to Genshin. If the target
    // process needs activating, posting can briefly block; the learning cue
    // should still advance immediately for the person clicking the HUD.
    if (_practiceTarget != nil && _practiceAction != nullptr &&
        [_practiceTarget respondsToSelector:_practiceAction]) {
        NSMethodSignature* signature = [_practiceTarget methodSignatureForSelector:_practiceAction];
        if (signature != nil) {
            NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = _practiceTarget;
            invocation.selector = _practiceAction;
            NSNumber* value = @(static_cast<NSInteger>(key));
            [invocation setArgument:&value atIndex:2];
            [invocation invoke];
        }
    }
    _keyboard->keyDown(key);
    self.needsDisplay = YES;
}

- (void)keyDown:(NSEvent*)event {
    const std::optional<Key> key = key_from_event(event);
    if (key.has_value()) {
        [self pressKey:key.value()];
        return;
    }
    [super keyDown:event];
}

- (void)keyUp:(NSEvent*)event {
    [self releaseHeldKey];
}

- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
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
    // Key silhouette comes from the theme: sharp crests vs halo circles.
    const CGFloat radius = cell * themes::current().key_radius;

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
            const BOOL practicePreview = preview && _practiceMode;

            if (lit > 0.0) {
                // Keep the idle face underneath so a fading key dims back into
                // the grid instead of settling on a muddy mid-tone — the glow
                // should read as light going out, not as paint.
                [[themes::current().ink colorWithAlphaComponent:_highContrast ? 0.11 : 0.055] setFill];
                [face fill];

                // Soft outer glow, then the accent fill fading to transparent.
                // The halo falls off faster than the fill (lit²) so a decaying
                // key doesn't leave a hazy smear around itself. Spread and
                // strength come from the theme: a wide holy bloom for Naberius,
                // a tight hot flare for Ronova.
                const CGFloat spread = themes::current().glow_spread * lit;
                [[g colorWithAlphaComponent:themes::current().glow_strength * lit * lit] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -spread, -spread)
                                                 xRadius:radius + spread
                                                 yRadius:radius + spread] fill];
                [[g colorWithAlphaComponent:lit] setFill];
                [face fill];
            } else if (preview) {
                // Resting hint: practice targets are intentionally stronger
                // than the normal idle preview, but still use the current
                // theme's accent so they do not introduce a new visual style.
                const double breathe = _reducedMotion
                    ? 0.0 : 0.5 + 0.5 * std::sin(_shimmer * 2 * M_PI);
                const double b = practicePreview
                    ? 0.20 + 0.08 * breathe
                    : 0.10 + 0.06 * breathe;
                [[g colorWithAlphaComponent:b] setFill];
                [face fill];
                [[g colorWithAlphaComponent:practicePreview ? 0.78 : 0.35] setStroke];
                face.lineWidth = practicePreview
                    ? themes::current().key_stroke * 1.5
                    : themes::current().key_stroke;
                [face stroke];
            } else {
                // Idle: near-invisible fill, plus a per-theme edge. The stroke
                // is blended toward the accent by edge_tint so a "plated" theme
                // (Asmoday) shows its gold trim while others stay neutral.
                [[themes::current().ink colorWithAlphaComponent:_highContrast ? 0.11 : 0.055] setFill];
                [face fill];
                NSColor* edge = _highContrast
                    ? [ink_soft() colorWithAlphaComponent:0.95]
                    : [ink_faint()
                        blendedColorWithFraction:themes::current().edge_tint
                                         ofColor:gold()];
                [edge setStroke];
                face.lineWidth = themes::current().key_stroke;
                [face stroke];
            }

            // Only swap to the on-accent color while the key is bright enough to
            // carry it; below that, blend back toward the normal label color.
            NSColor* text = lit > 0.55
                ? on_accent()
                : (preview ? [g colorWithAlphaComponent:practicePreview ? 0.95 : 0.75]
                           : (_highContrast ? ink_soft()
                                            : [ink_faint() blendedColorWithFraction:lit
                                                                            ofColor:on_accent()]));
            // Foundation raises an Objective-C exception if an object in a
            // dictionary literal is nil. A color blend can legally return nil
            // for an unsupported color-space combination, so keep rendering
            // the key labels with a themed fallback instead of crashing the
            // whole HUD during a display refresh.
            NSFont* labelFont =
                [NSFont monospacedSystemFontOfSize:11
                                              weight:practicePreview
                                                  ? NSFontWeightBold
                                                  : NSFontWeightSemibold];
            if (labelFont == nil) {
                labelFont = [NSFont systemFontOfSize:11
                                                weight:practicePreview
                                                    ? NSFontWeightBold
                                                    : NSFontWeightSemibold];
            }
            if (labelFont == nil) {
                labelFont = [NSFont systemFontOfSize:11];
            }

            NSColor* labelColor = text != nil ? text : ink_soft();
            if (labelColor == nil) {
                labelColor = NSColor.whiteColor;
            }

            NSMutableDictionary* attrs = [NSMutableDictionary dictionaryWithCapacity:2];
            if (labelFont != nil) {
                attrs[NSFontAttributeName] = labelFont;
            }
            attrs[NSForegroundColorAttributeName] = labelColor;
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

// Themed song picker: a rounded field showing the current song plus a chevron,
// which pops a menu of the playlist on click. AppKit's NSPopUpButton draws its
// label in a system color we can't override, which breaks light themes — this
// draws everything itself so it always follows the palette.
@interface SongPicker : NSView
@property(nonatomic, copy) NSString* title;
@property(nonatomic, strong) NSMenu* menu_;      // items supplied by the owner
@property(nonatomic) BOOL hovering;
@property(nonatomic) BOOL expanded;
@end

@implementation SongPicker {
    NSTrackingArea* _tracking;
}

- (void)setTitle:(NSString*)title { _title = [title copy]; self.needsDisplay = YES; }

- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 26); }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)e { _hovering = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { _hovering = NO; self.needsDisplay = YES; }

- (BOOL)isAccessibilityElement { return YES; }
- (NSString*)accessibilityRole { return NSAccessibilityPopUpButtonRole; }
- (NSString*)accessibilityLabel { return self.title.length > 0 ? self.title : @"Song picker"; }
- (NSString*)accessibilityValue { return self.title ?: @""; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)openMenu {
    if (_menu_ == nil) {
        return;
    }
    [self.window makeFirstResponder:self];
    self.expanded = YES;
    self.needsDisplay = YES;
    [_menu_ popUpMenuPositioningItem:nil
                         atLocation:NSMakePoint(0, NSHeight(self.bounds) + 3)
                             inView:self];
    self.expanded = NO;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent*)event {
    [self openMenu];
}

- (void)keyDown:(NSEvent*)event {
    if (event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76) {
        [self openMenu];
        return;
    }
    [super keyDown:event];
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7];
    const BOOL active = _hovering || _expanded || self.window.firstResponder == self;
    [[themes::current().ink colorWithAlphaComponent:active ? 0.12 : 0.07] setFill];
    [bg fill];
    [[(active ? gold() : themes::current().ink)
        colorWithAlphaComponent:active ? 0.38 : 0.10] setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    // Give the chevron its own small affordance so the field reads as a
    // picker rather than a static label.
    const CGFloat dividerX = NSMaxX(b) - 31;
    [[themes::current().ink colorWithAlphaComponent:active ? 0.18 : 0.10] setStroke];
    NSBezierPath* divider = [NSBezierPath bezierPath];
    [divider moveToPoint:NSMakePoint(dividerX, NSMinY(b) + 6)];
    [divider lineToPoint:NSMakePoint(dividerX, NSMaxY(b) - 6)];
    divider.lineWidth = 1.0;
    [divider stroke];

    // Chevron on the trailing edge.
    const CGFloat cx = NSMaxX(b) - 14;
    const CGFloat cy = NSMidY(b);
    NSBezierPath* chev = [NSBezierPath bezierPath];
    const CGFloat direction = _expanded ? 1.0 : -1.0;
    [chev moveToPoint:NSMakePoint(cx - 3.5, cy - direction * 1.5)];
    [chev lineToPoint:NSMakePoint(cx, cy + direction * 2.0)];
    [chev lineToPoint:NSMakePoint(cx + 3.5, cy - direction * 1.5)];
    chev.lineWidth = 1.6;
    chev.lineCapStyle = NSLineCapStyleRound;
    [(active ? gold() : ink_soft()) setStroke];
    [chev stroke];

    if (_title.length == 0) {
        return;
    }
    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: ink()
    };
    const CGFloat maxw = b.size.width - 12 - 34;
    NSString* text = _title;
    NSSize size = [text sizeWithAttributes:attrs];
    // Truncate by trimming until it fits, then add an ellipsis.
    while (size.width > maxw && text.length > 1) {
        text = [text substringToIndex:text.length - 1];
        size = [[text stringByAppendingString:@"…"] sizeWithAttributes:attrs];
    }
    if (![text isEqualToString:_title]) {
        text = [text stringByAppendingString:@"…"];
        size = [text sizeWithAttributes:attrs];
    }
    [text drawAtPoint:NSMakePoint(10, (b.size.height - size.height) * 0.5)
       withAttributes:attrs];
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

// A glyph-only button with live hover + press feedback, so the transport and
// header chrome don't read as dead icons. Two styles:
//   chrome    — a soft rounded pad fades in behind the glyph on hover.
//   transport — an accent glow ring blooms behind the glyph on hover, matching
//               the key-grid's light language; `emphasis` makes it the hero
//               (used by play/pause) with a wider, warmer bloom.
// Both dip slightly on press so a click feels physical.
typedef NS_ENUM(NSInteger, GlyphButtonStyle) {
    GlyphButtonStyleChrome,
    GlyphButtonStyleTransport,
};

@interface GlyphButton : NSButton
@property(nonatomic) GlyphButtonStyle glyphStyle;
@property(nonatomic) BOOL emphasis;   // hero treatment (play/pause)
@end

@implementation GlyphButton {
    NSTrackingArea* _tracking;
    double _hover;    // 0→1 eased hover amount
    double _press;    // 0→1 eased press amount
    BOOL _hovering;
    BOOL _pressed;
    NSTimer* _anim;
}

- (BOOL)wantsUpdateLayer { return NO; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)startAnim {
    if (_anim != nil) {
        return;
    }
    _anim = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                             target:self
                                           selector:@selector(stepAnim)
                                           userInfo:nil
                                            repeats:YES];
}

- (void)stepAnim {
    const double hoverTarget = (_hovering && self.enabled) ? 1.0 : 0.0;
    const double pressTarget = _pressed ? 1.0 : 0.0;
    // Asymmetric easing: quick to light, slower to fade — reads as responsive.
    const double up = 0.28, down = 0.16;
    _hover += (hoverTarget - _hover) * (hoverTarget > _hover ? up : down);
    _press += (pressTarget - _press) * (pressTarget > _press ? 0.5 : 0.3);
    if (std::abs(_hover - hoverTarget) < 0.003) _hover = hoverTarget;
    if (std::abs(_press - pressTarget) < 0.003) _press = pressTarget;
    self.needsDisplay = YES;
    if (_hover == hoverTarget && _press == pressTarget) {
        [_anim invalidate];
        _anim = nil;
    }
}

- (void)mouseEntered:(NSEvent*)e { _hovering = YES; [self startAnim]; }
- (void)mouseExited:(NSEvent*)e { _hovering = NO; [self startAnim]; }

- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled) {
        return;
    }
    _pressed = YES;
    [self startAnim];
    // Track the drag so releasing outside the button cancels the click, like a
    // real AppKit button.
    BOOL inside = YES;
    NSEvent* e = event;
    while (e.type != NSEventTypeLeftMouseUp) {
        e = [self.window nextEventMatchingMask:
                NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        const NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
        inside = NSPointInRect(p, self.bounds);
        if ((inside ? 1 : 0) != (_pressed ? 1 : 0)) {
            _pressed = inside;
            [self startAnim];
        }
    }
    _pressed = NO;
    [self startAnim];
    if (inside) {
        [self sendAction:self.action to:self.target];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    const CGFloat cx = NSMidX(b), cy = NSMidY(b);
    NSColor* accent = gold();

    if (_glyphStyle == GlyphButtonStyleChrome) {
        // Soft rounded pad behind the glyph.
        if (_hover > 0.001) {
            const CGFloat inset = 1.5;
            NSRect pad = NSInsetRect(b, inset, inset);
            [[ink() colorWithAlphaComponent:0.10 * _hover] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pad xRadius:5 yRadius:5] fill];
        }
    } else {
        // Transport: an accent glow ring blooms on hover.
        const double h = _hover;
        if (h > 0.001) {
            const CGFloat baseR = std::min(b.size.width, b.size.height) * 0.5;
            const CGFloat r = baseR * (_emphasis ? 1.0 : 0.92);
            const CGFloat spread = (_emphasis ? 6.0 : 4.0) * h;
            [[accent colorWithAlphaComponent:(_emphasis ? 0.22 : 0.16) * h] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(cx - r - spread, cy - r - spread,
                           (r + spread) * 2, (r + spread) * 2)] fill];
            [[ink() colorWithAlphaComponent:0.08 * h] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(cx - r, cy - r, r * 2, r * 2)] fill];
        }
    }

    // Press dip: scale the glyph down a touch around center.
    const CGFloat scale = 1.0 - 0.10 * _press;
    NSImage* img = self.image;
    if (img == nil) {
        return;
    }
    const NSSize s = img.size;
    const CGFloat w = s.width * scale, hgt = s.height * scale;
    const CGFloat a = self.enabled ? (0.85 + 0.15 * _hover) : 0.4;
    [img drawInRect:NSMakeRect(cx - w * 0.5, cy - hgt * 0.5, w, hgt)
           fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver
           fraction:a];
}

@end

// Empty-state call-to-action. It keeps native NSButton semantics (including
// keyboard activation and accessibility) while drawing a larger, clearly
// interactive surface that still uses only the active theme's palette.
@interface EmptyStateButton : NSButton
@end

@implementation EmptyStateButton {
    NSTrackingArea* _tracking;
    BOOL _hovering;
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

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)mouseEntered:(NSEvent*)event {
    _hovering = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event {
    _hovering = NO;
    self.needsDisplay = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.needsDisplay = YES;
}

- (BOOL)becomeFirstResponder {
    const BOOL became = [super becomeFirstResponder];
    self.needsDisplay = YES;
    return became;
}

- (BOOL)resignFirstResponder {
    const BOOL resigned = [super resignFirstResponder];
    self.needsDisplay = YES;
    return resigned;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bounds = NSInsetRect(self.bounds, 1.0, 1.0);
    const CGFloat radius = 8.0;
    const BOOL focused = self.window != nil && self.window.firstResponder == self;
    const CGFloat hover = _hovering ? 1.0 : 0.0;
    const CGFloat pressed = self.highlighted ? 1.0 : 0.0;

    NSColor* accent = gold();
    NSColor* fill = [ink() colorWithAlphaComponent:0.07 + 0.07 * hover +
                                                   0.04 * pressed];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds
                                     xRadius:radius
                                     yRadius:radius] fill];

    NSColor* border = [accent colorWithAlphaComponent:0.32 + 0.42 * hover +
                                                        0.12 * pressed];
    [border setStroke];
    NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                              xRadius:radius
                                                              yRadius:radius];
    outline.lineWidth = 1.0 + hover;
    [outline stroke];

    if (focused) {
        [[accent colorWithAlphaComponent:0.9] setStroke];
        NSBezierPath* focus = [NSBezierPath bezierPathWithRoundedRect:
            NSInsetRect(self.bounds, 0.5, 0.5) xRadius:radius + 1.0 yRadius:radius + 1.0];
        focus.lineWidth = 2.0;
        [focus stroke];
    }

    [super drawRect:dirtyRect];
}

@end

@interface PlayerWindowController () <PanelMouseDelegate, NSWindowDelegate>
- (void)loadQueueIndex:(NSInteger)index
           sourceIndex:(NSInteger)sourceIndex
              autoplay:(BOOL)autoplay;
- (void)practiceKeyPressed:(NSNumber*)value;
- (void)toggleTempoPractice:(id)sender;
- (void)toggleAutoPracticeSpeed:(id)sender;
- (void)setSpeedRamp:(NSMenuItem*)sender;
- (void)setPracticeDifficulty:(NSMenuItem*)sender;
- (void)toggleShowSummary:(id)sender;
- (PracticeDashboardController*)practiceDashboard;
- (void)toggleUpcomingNote:(id)sender;
- (void)toggleReducedMotion:(id)sender;
- (void)setMetronomeMode:(NSMenuItem*)sender;
- (void)applyMetronome;
- (void)metronomeTick:(NSTimer*)timer;
- (void)startDrill:(id)sender;
- (void)stopDrill:(id)sender;
- (void)loadDrillItem;
- (void)flashHint:(NSString*)message;
- (void)toggleHighContrast:(id)sender;
- (void)toggleFavoritesOnly:(id)sender;
- (void)setCountIn:(NSMenuItem*)sender;
- (void)setLatencyOffset:(NSMenuItem*)sender;
- (void)restartPracticePhrase:(id)sender;
- (void)showPracticeDashboard:(id)sender;
- (void)moveCurrentSong:(NSMenuItem*)sender;
- (void)removeSongFromQueue:(NSMenuItem*)sender;
- (void)clearQueue:(id)sender;
- (void)toggleFavoriteForSong:(NSMenuItem*)sender;
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
    SongPicker* _songPicker;
    NSButton* _collapseButton;
    NSStackView* _controls;
    NSButton* _speedButton;
    MiniProgress* _miniProgress;   // thin bar shown when collapsed
    NSTimer* _uiTimer;
    NSTimer* _focusTimer;
    PracticeDashboardController* _practiceDashboard;
    BOOL _dashboardHiddenForBlur;  // dashboard was open when Genshin lost focus
    id _hotkeyMonitor;
    CGFloat _target_alpha;
    pid_t _genshin_pid;

    BOOL _collapsed;
    BOOL _dragging;
    NSPoint _dragStartMouse;
    NSPoint _dragStartOrigin;
    BOOL _pointerInside;
    // Bring Genshin to the front once, when we first locate its window at launch.
    BOOL _didActivateGenshin;
    // Once the user drags the HUD, remember its position as an offset from the
    // game window's top-right corner so it still follows the game but no longer
    // snaps back to the default dock.
    BOOL _hasUserOffset;
    NSSize _userOffset;

    BOOL _autoPauseOnBlur;         // auto-pause when Genshin loses focus
    BOOL _playInBackground;
    BOOL _showUpcoming;
    BOOL _reducedMotion;
    NSInteger _metronomeMode;      // 0 off, 1 note cues, 2 steady beat
    NSInteger _songBpm;            // current song's BPM (0 = unknown)
    NSTimer* _metronomeTimer;      // high-rate poll for the steady beat
    std::size_t _lastMetronomeTick;
    std::vector<DrillItem> _drill; // active drill queue (empty = no drill)
    std::size_t _drillPos;
    BOOL _drillLoading;            // suppress drill checks while switching items
    NSString* _flashHint;          // short-lived status line override
    NSTimeInterval _flashHintUntil;
    BOOL _highContrast;
    BOOL _favoritesOnly;
    NSInteger _countInSeconds;
    NSInteger _latencyOffsetMs;
    NSInteger _rampStartPct;       // speed ramp start (0 = current speed)
    NSInteger _difficulty;         // 0 easy, 1 normal, 2 strict
    std::size_t _lastMetronomeBeat;
    BOOL _wasFocused;              // edge-detect focus loss
    BOOL _openPanelActive;         // keep HUD up while the file picker is open
    NSInteger _menuTrackingDepth;  // AppKit menus temporarily take focus/input
    NSView* _tintView;            // panel background tint (re-colored on theme change)
    NSButton* _hideButton;        // × close button (kept for localization)
    NSButton* _settingsButton;    // gear — opens the same menu as right-click
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
    _playInBackground = settings::get_bool(kSettingPlayInBackground, true);
    _keyboard->set_play_in_background(_playInBackground);
    _showUpcoming = settings::get_bool(kSettingShowUpcoming, true);
    _reducedMotion = settings::get_bool(kSettingReducedMotion, false);
    _metronomeMode = std::clamp(settings::get_int(kSettingMetronomeMode,
        settings::get_bool(kSettingMetronome, false) ? 1 : 0), 0, 2);
    _songBpm = bpm;
    _lastMetronomeTick = 0;
    _drillPos = 0;
    _drillLoading = NO;
    _flashHintUntil = 0.0;
    _highContrast = settings::get_bool(kSettingHighContrast, false);
    _favoritesOnly = settings::get_bool(kSettingFavoritesOnly, false);
    _countInSeconds = std::clamp(settings::get_int(kSettingCountIn, 3), 0, 5);
    _latencyOffsetMs = std::clamp(settings::get_int(kSettingLatencyOffset, 0), -300, 300);
    _lastMetronomeBeat = 0;
    _wasFocused = NO;

    // Restore theme + language before building the UI so colors and strings are
    // correct from the first frame.
    themes::set_current(settings::get_string(kSettingTheme, "naberius"));
    strings::set_current(settings::get_string(kSettingLang, "en") == "zh"
        ? Lang::chinese : Lang::english);

    _playback->set_countdown(std::chrono::seconds(_countInSeconds));
    _playback->set_practice_mode(settings::get_bool(kSettingLearn, false));
    _playback->set_practice_tempo(settings::get_bool(kSettingTempoPractice, false));
    _playback->set_practice_auto_speed(settings::get_bool(kSettingAutoSpeed, false));
    _playback->set_practice_lock_until_mastered(
        settings::get_bool(kSettingLockMastered, false));
    _rampStartPct = std::clamp(settings::get_int(kSettingRampStart, 0), 0, 100);
    _playback->set_practice_ramp_start(_rampStartPct / 100.0);
    _playback->set_metronome_bpm(_metronomeMode == 2 ? static_cast<int>(_songBpm) : 0);
    _difficulty = std::clamp(settings::get_int(kSettingDifficulty, 1), 0, 2);
    _playback->set_practice_timing_windows(timing_windows_for_difficulty(_difficulty));
    _playback->set_practice_latency_offset(std::chrono::milliseconds(_latencyOffsetMs));

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
    window.delegate = self;
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
    _panel.layer.borderColor = themes::current().border.CGColor;

    // Tint the blur toward the theme's dark ground tone.
    _tintView = [[NSView alloc] initWithFrame:_panel.bounds];
    _tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _tintView.wantsLayer = YES;
    _tintView.layer.backgroundColor = themes::current().panel_tint.CGColor;
    [_panel addSubview:_tintView];

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
                            tooltip:strings::get(Str::tip_add)];
    _addButton.hidden = YES;
    _settingsButton = [self chromeButton:@"gearshape.fill" action:@selector(showSettingsMenu:)
                                 tooltip:strings::get(Str::tip_settings)];
    _collapseButton = [self chromeButton:@"chevron.up" action:@selector(toggleCollapse)
                                 tooltip:strings::get(Str::tip_collapse)];
    _hideButton = [self chromeButton:@"xmark" action:@selector(hideHud)
                             tooltip:strings::get(Str::tip_close)];
    NSButton* hide = _hideButton;

    NSStackView* title_col = [NSStackView stackViewWithViews:@[_titleLabel, _metaLabel]];
    title_col.orientation = NSUserInterfaceLayoutOrientationVertical;
    title_col.spacing = 2;
    title_col.alignment = NSLayoutAttributeLeading;

    NSStackView* chrome = [NSStackView stackViewWithViews:@[
        _addButton, _settingsButton, _collapseButton, hide]];
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
    _openButton = [EmptyStateButton buttonWithTitle:strings::get(Str::open_songs)
                                              target:self
                                              action:@selector(openSongs:)];
    _openButton.buttonType = NSButtonTypeMomentaryPushIn;
    _openButton.bezelStyle = NSBezelStyleInline;
    _openButton.bordered = NO;
    _openButton.refusesFirstResponder = NO;
    _openButton.focusRingType = NSFocusRingTypeExterior;
    _openButton.alignment = NSTextAlignmentCenter;
    _openButton.imagePosition = NSImageLeft;
    _openButton.imageHugsTitle = YES;
    _openButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _openButton.contentTintColor = gold();
    [_openButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [self styleOpenButton];

    _songPicker = [[SongPicker alloc] initWithFrame:NSZeroRect];
    _songPicker.toolTip = strings::get(Str::tip_playlist);
    _songPicker.hidden = YES;

    _libraryRow = [NSStackView stackViewWithViews:@[_openButton, _songPicker]];
    _libraryRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _libraryRow.spacing = 8;
    _libraryRow.distribution = NSStackViewDistributionFillEqually;
    _libraryRow.alignment = NSLayoutAttributeCenterY;
    NSStackView* library_row = _libraryRow;

    // ---- Hero: the lyre grid, large. ----
    _key_grid = [[LyreKeyGridView alloc] initWithFrame:NSMakeRect(0, 0, kW - 32, 96)];
    _key_grid.keyboard = keyboard;
    _key_grid.practiceMode = _playback->practice_mode();
    _key_grid.reducedMotion = _reducedMotion;
    _key_grid.highContrast = _highContrast;
    _key_grid.practiceTarget = self;
    _key_grid.practiceAction = @selector(practiceKeyPressed:);
    _key_grid.translatesAutoresizingMaskIntoConstraints = NO;
    [_key_grid.heightAnchor constraintEqualToConstant:96].active = YES;

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
    _speedButton.toolTip = strings::get(Str::tip_speed);
    _speedButton.contentTintColor = ink_soft();
    [_speedButton.widthAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;

    // ---- Transport: flat, quiet. Play is a gold glyph, no disc/ring. ----
    _prevButton = [self transportButton:@"backward.fill" size:12 gold:NO
                                 action:@selector(previousSong) tooltip:strings::get(Str::tip_previous)];
    _prevButton.hidden = YES;
    _loopButton = [self transportButton:@"repeat" size:12 gold:NO
                                 action:@selector(toggleLoop) tooltip:strings::get(Str::tip_loop)];
    _playPause = [self transportButton:@"play.fill" size:18 gold:YES
                                action:@selector(togglePlayPause:) tooltip:strings::get(Str::tip_playpause)];
    _stopButton = [self transportButton:@"stop.fill" size:12 gold:NO
                                 action:@selector(stopPlayback:) tooltip:strings::get(Str::tip_stop)];
    _nextButton = [self transportButton:@"forward.fill" size:12 gold:NO
                                 action:@selector(nextSong) tooltip:strings::get(Str::tip_next)];
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
    expanded.spacing = 7;
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
    // Focus and placement must continue to reconcile while AppKit is tracking
    // a menu or running an NSOpenPanel. A default-mode timer pauses in those
    // run-loop modes, leaving the HUD in whichever visibility state it had
    // before the interaction began.
    _focusTimer = [NSTimer timerWithTimeInterval:0.1
                                           target:self
                                         selector:@selector(updateFocusAppearance)
                                         userInfo:nil
                                          repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_focusTimer forMode:NSRunLoopCommonModes];

    NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self
                       selector:@selector(menuDidBeginTracking:)
                           name:NSMenuDidBeginTrackingNotification
                         object:nil];
    [notifications addObserver:self
                       selector:@selector(menuDidEndTracking:)
                           name:NSMenuDidEndTrackingNotification
                         object:nil];

    // React the instant the frontmost app changes instead of waiting for the
    // next focus-timer tick; the timer stays as a backstop.
    NSNotificationCenter* workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidActivateApplicationNotification,
                                      NSWorkspaceDidDeactivateApplicationNotification,
                                      NSWorkspaceDidHideApplicationNotification,
                                      NSWorkspaceDidUnhideApplicationNotification]) {
        [workspace addObserver:self
                      selector:@selector(workspaceFocusChanged:)
                          name:name
                        object:nil];
    }

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
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    if (_hotkeyMonitor != nil) {
        [NSEvent removeMonitor:_hotkeyMonitor];
    }
    _playback->set_on_finished(nullptr);
    [_uiTimer invalidate];
    [_focusTimer invalidate];
    [_metronomeTimer invalidate];
}

#pragma mark - Small builders

- (NSButton*)chromeButton:(NSString*)name action:(SEL)action tooltip:(NSString*)tip {
    GlyphButton* b = [GlyphButton buttonWithImage:tinted_symbol(name, 10, NSFontWeightSemibold, ink_soft())
                                           target:self action:action];
    b.glyphStyle = GlyphButtonStyleChrome;
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip = tip;
    // Give the hover pad a bit of room around the small glyph.
    [b.widthAnchor constraintEqualToConstant:22].active = YES;
    [b.heightAnchor constraintEqualToConstant:22].active = YES;
    return b;
}

- (NSButton*)transportButton:(NSString*)name size:(CGFloat)size gold:(BOOL)isGold
                      action:(SEL)action tooltip:(NSString*)tip {
    NSColor* color = isGold ? gold() : ink_soft();
    GlyphButton* b = [GlyphButton buttonWithImage:tinted_symbol(name, size, NSFontWeightMedium, color)
                                           target:self action:action];
    b.glyphStyle = GlyphButtonStyleTransport;
    b.emphasis = isGold;   // play/pause is the hero
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip = tip;
    b.accessibilityLabel = tip;
    // Room for the hover glow ring; the play glyph gets a larger hit target.
    const CGFloat side = isGold ? 34 : 28;
    [b.widthAnchor constraintEqualToConstant:side].active = YES;
    [b.heightAnchor constraintEqualToConstant:side].active = YES;
    return b;
}

#pragma mark - Transport

- (void)startPlayback {
    if (_playback->note_count() == 0) {
        [self openSongs:nil];
        return;
    }
    if (!_playInBackground) {
        _genshin->activate_application();
    }
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

- (void)practiceKeyPressed:(NSNumber*)value {
    const NSInteger raw = value.integerValue;
    if (raw < 0 || raw >= 21) {
        return;
    }
    _playback->practice_key(static_cast<Key>(raw));
    [self refresh];
}

- (void)restartPracticePhrase:(id)sender {
    _playback->practice_restart_phrase();
    [self refresh];
}

// Created on first use (the HUD's first refresh) and kept alive, so practice
// history and session summaries are recorded even if Insights is never opened.
- (PracticeDashboardController*)practiceDashboard {
    if (_practiceDashboard == nil) {
        _practiceDashboard = [[PracticeDashboardController alloc]
            initWithPlayback:_playback];
        [_practiceDashboard.window center];
    }
    return _practiceDashboard;
}

- (void)showPracticeDashboard:(id)sender {
    [[self practiceDashboard] setSongKey:_titleLabel.stringValue];
    [_practiceDashboard refresh];
    [_practiceDashboard showWindow:self];
    [_practiceDashboard.window orderFrontRegardless];
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

- (void)togglePlayInBackground:(id)sender {
    _playInBackground = !_playInBackground;
    settings::set_bool(kSettingPlayInBackground, _playInBackground);
    _keyboard->set_play_in_background(_playInBackground);
    if (!_playInBackground) {
        _genshin->activate_application();
    }
    [self refresh];
}

- (void)toggleLearnMode:(id)sender {
    const BOOL enabled = !_playback->practice_mode();
    _playback->set_practice_mode(enabled);
    settings::set_bool(kSettingLearn, enabled);
    [self reloadQueueMetadata];
    [self refresh];
}

- (void)toggleTempoPractice:(id)sender {
    const BOOL enabled = !_playback->practice_tempo();
    if (!_playback->practice_mode()) {
        _playback->set_practice_mode(true);
        settings::set_bool(kSettingLearn, true);
    }
    _playback->set_practice_tempo(enabled);
    settings::set_bool(kSettingTempoPractice, enabled);
    [self refresh];
}

- (void)toggleAutoPracticeSpeed:(id)sender {
    const BOOL enabled = !_playback->practice_auto_speed();
    if (!_playback->practice_mode()) {
        _playback->set_practice_mode(true);
        settings::set_bool(kSettingLearn, true);
    }
    if (!_playback->practice_tempo()) {
        _playback->set_practice_tempo(true);
        settings::set_bool(kSettingTempoPractice, true);
    }
    _playback->set_practice_auto_speed(enabled);
    settings::set_bool(kSettingAutoSpeed, enabled);
    [self refresh];
}

- (void)setSpeedRamp:(NSMenuItem*)sender {
    const NSInteger pct = [(NSNumber*)sender.representedObject integerValue];
    const BOOL enabled = pct >= 0;
    if (enabled) {
        if (!_playback->practice_mode()) {
            _playback->set_practice_mode(true);
            settings::set_bool(kSettingLearn, true);
        }
        if (!_playback->practice_tempo()) {
            _playback->set_practice_tempo(true);
            settings::set_bool(kSettingTempoPractice, true);
        }
        _rampStartPct = pct;
        settings::set_int(kSettingRampStart, static_cast<int>(pct));
        _playback->set_practice_ramp_start(pct / 100.0);
    }
    _playback->set_practice_auto_speed(enabled);
    settings::set_bool(kSettingAutoSpeed, enabled);
    [self refresh];
}

- (void)setPracticeDifficulty:(NSMenuItem*)sender {
    _difficulty = std::clamp([(NSNumber*)sender.representedObject integerValue], 0L, 2L);
    settings::set_int(kSettingDifficulty, static_cast<int>(_difficulty));
    _playback->set_practice_timing_windows(timing_windows_for_difficulty(_difficulty));
    [self refresh];
}

- (void)toggleShowSummary:(id)sender {
    settings::set_bool(kSettingShowSummary, !settings::get_bool(kSettingShowSummary, true));
}

- (void)toggleLockUntilMastered:(id)sender {
    const BOOL enabled = !_playback->practice_lock_until_mastered();
    if (!_playback->practice_mode()) {
        _playback->set_practice_mode(true);
        settings::set_bool(kSettingLearn, true);
    }
    _playback->set_practice_lock_until_mastered(enabled);
    settings::set_bool(kSettingLockMastered, enabled);
    [self refresh];
}

- (void)toggleUpcomingNote:(id)sender {
    _showUpcoming = !_showUpcoming;
    settings::set_bool(kSettingShowUpcoming, _showUpcoming);
    [self refresh];
}

- (void)toggleReducedMotion:(id)sender {
    _reducedMotion = !_reducedMotion;
    settings::set_bool(kSettingReducedMotion, _reducedMotion);
    _key_grid.reducedMotion = _reducedMotion;
    [self refresh];
}

- (void)setMetronomeMode:(NSMenuItem*)sender {
    _metronomeMode = std::clamp([(NSNumber*)sender.representedObject integerValue], 0L, 2L);
    // Ignore already-emitted beats so switching modes never plays a stray click.
    _lastMetronomeBeat = _playback->snapshot().practice_beat_sequence;
    _lastMetronomeTick = _playback->practice_metronome().first;
    settings::set_int(kSettingMetronomeMode, static_cast<int>(_metronomeMode));
    _playback->set_metronome_bpm(_metronomeMode == 2 ? static_cast<int>(_songBpm) : 0);
    [self refresh];
}

// The steady beat needs tighter timing than the 30 fps UI refresh, so a fast
// timer runs only while a timed practice run is active with the beat on.
- (void)applyMetronome {
    const PlaybackState state = _playback->snapshot().state;
    const BOOL want = _metronomeMode == 2 && _songBpm > 0 &&
        _playback->practice_mode() && _playback->practice_tempo() &&
        (state == PlaybackState::playing || state == PlaybackState::countdown);
    if (want && _metronomeTimer == nil) {
        _lastMetronomeTick = _playback->practice_metronome().first;
        _metronomeTimer = [NSTimer timerWithTimeInterval:0.004
                                                  target:self
                                                selector:@selector(metronomeTick:)
                                                userInfo:nil
                                                 repeats:YES];
        _metronomeTimer.tolerance = 0.001;
        [[NSRunLoop mainRunLoop] addTimer:_metronomeTimer forMode:NSRunLoopCommonModes];
    } else if (!want && _metronomeTimer != nil) {
        [_metronomeTimer invalidate];
        _metronomeTimer = nil;
    }
}

- (void)metronomeTick:(NSTimer*)timer {
    _playback->practice_tick();
    const auto [ticks, downbeat] = _playback->practice_metronome();
    if (ticks == _lastMetronomeTick) {
        return;
    }
    _lastMetronomeTick = ticks;
    static NSSound* beat = [NSSound soundNamed:@"Tink"];
    static NSSound* accent = [NSSound soundNamed:@"Pop"];
    NSSound* sound = downbeat ? accent : beat;
    [sound stop];
    [sound play];
}

- (void)toggleHighContrast:(id)sender {
    _highContrast = !_highContrast;
    settings::set_bool(kSettingHighContrast, _highContrast);
    _key_grid.highContrast = _highContrast;
    [self refresh];
}

- (void)toggleFavoritesOnly:(id)sender {
    _favoritesOnly = !_favoritesOnly;
    settings::set_bool(kSettingFavoritesOnly, _favoritesOnly);
    [self reloadQueuePicker];
}

- (void)setCountIn:(NSMenuItem*)sender {
    const NSInteger seconds = std::clamp(
        [(NSNumber*)sender.representedObject integerValue], 0L, 5L);
    _countInSeconds = seconds;
    _playback->set_countdown(std::chrono::seconds(seconds));
    settings::set_int(kSettingCountIn, static_cast<int>(seconds));
    [self refresh];
}

- (void)setLatencyOffset:(NSMenuItem*)sender {
    const NSInteger offset = std::clamp(
        [(NSNumber*)sender.representedObject integerValue], -300L, 300L);
    _latencyOffsetMs = offset;
    _playback->set_practice_latency_offset(std::chrono::milliseconds(offset));
    settings::set_int(kSettingLatencyOffset, static_cast<int>(offset));
    [self refresh];
}

- (NSMenu*)panelContextMenu {
    NSMenu* menu = [[NSMenu alloc] init];

    // Keep the menu scannable by grouping related controls. These are still
    // ordinary NSMenuItems, so keyboard navigation and state checkmarks work
    // exactly as before while the HUD remains compact.
    NSMenuItem* practiceItem = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_practice) action:nil keyEquivalent:@""];
    NSMenu* practiceMenu = [[NSMenu alloc] initWithTitle:practiceItem.title];

    NSMenuItem* learn = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_learn)
                                                   action:@selector(toggleLearnMode:)
                                            keyEquivalent:@""];
    learn.target = self;
    learn.state = _playback->practice_mode()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [practiceMenu addItem:learn];

    if (_playback->practice_mode()) {
        NSMenuItem* safety = [[NSMenuItem alloc]
            initWithTitle:strings::get(Str::menu_safety)
                   action:nil keyEquivalent:@""];
        safety.enabled = NO;
        [practiceMenu addItem:safety];
    }

    NSMenuItem* tempo = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_tempo_practice)
               action:@selector(toggleTempoPractice:)
        keyEquivalent:@""];
    tempo.target = self;
    tempo.state = _playback->practice_tempo()
        ? NSControlStateValueOn : NSControlStateValueOff;
    tempo.enabled = _playback->practice_mode();
    [practiceMenu addItem:tempo];

    NSMenuItem* metronome = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_metronome) action:nil keyEquivalent:@""];
    NSMenu* metronomeMenu = [[NSMenu alloc] init];
    for (NSInteger mode = 0; mode <= 2; ++mode) {
        NSString* title = mode == 0 ? strings::get(Str::option_off)
            : mode == 1 ? strings::get(Str::metronome_note_cues)
            : (_songBpm > 0
                ? [NSString stringWithFormat:strings::get(Str::metronome_steady_bpm), (long)_songBpm]
                : strings::get(Str::metronome_steady));
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:title action:@selector(setMetronomeMode:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(mode);
        item.state = mode == _metronomeMode ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = mode != 2 || _songBpm > 0;
        [metronomeMenu addItem:item];
    }
    metronome.submenu = metronomeMenu;
    metronome.enabled = _playback->practice_mode() && _playback->practice_tempo();
    [practiceMenu addItem:metronome];

    // Speed ramp: Off, climb from the current speed, or restart each run slow.
    NSMenuItem* autoSpeed = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_auto_speed) action:nil keyEquivalent:@""];
    NSMenu* rampMenu = [[NSMenu alloc] init];
    const BOOL rampOn = _playback->practice_auto_speed();
    for (NSNumber* value in @[@(-1), @(0), @(50), @(60), @(75)]) {
        const NSInteger pct = value.integerValue;
        NSString* title = pct < 0 ? strings::get(Str::option_off)
            : pct == 0 ? strings::get(Str::ramp_from_current)
            : [NSString stringWithFormat:strings::get(Str::ramp_from_percent), (long)pct];
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:title action:@selector(setSpeedRamp:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = value;
        const BOOL selected = pct < 0 ? !rampOn : (rampOn && pct == _rampStartPct);
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        [rampMenu addItem:item];
    }
    autoSpeed.submenu = rampMenu;
    autoSpeed.enabled = _playback->practice_mode();
    [practiceMenu addItem:autoSpeed];

    NSMenuItem* difficulty = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_difficulty) action:nil keyEquivalent:@""];
    NSMenu* difficultyMenu = [[NSMenu alloc] init];
    const Str difficultyNames[3] = {Str::difficulty_easy, Str::difficulty_normal,
                                    Str::difficulty_strict};
    for (NSInteger level = 0; level < 3; ++level) {
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:strings::get(difficultyNames[level])
                   action:@selector(setPracticeDifficulty:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(level);
        item.state = level == _difficulty ? NSControlStateValueOn : NSControlStateValueOff;
        [difficultyMenu addItem:item];
    }
    difficulty.submenu = difficultyMenu;
    difficulty.enabled = _playback->practice_mode() && _playback->practice_tempo();
    [practiceMenu addItem:difficulty];

    NSMenuItem* lockMastered = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_lock_mastered)
               action:@selector(toggleLockUntilMastered:)
        keyEquivalent:@""];
    lockMastered.target = self;
    lockMastered.state = _playback->practice_lock_until_mastered()
        ? NSControlStateValueOn : NSControlStateValueOff;
    lockMastered.enabled = _playback->practice_mode();
    [practiceMenu addItem:lockMastered];

    NSMenuItem* upcoming = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_show_upcoming)
               action:@selector(toggleUpcomingNote:)
        keyEquivalent:@""];
    upcoming.target = self;
    upcoming.state = _showUpcoming ? NSControlStateValueOn : NSControlStateValueOff;
    upcoming.enabled = _playback->practice_mode();
    [practiceMenu addItem:upcoming];

    NSMenuItem* countIn = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_count_in) action:nil keyEquivalent:@""];
    NSMenu* countInMenu = [[NSMenu alloc] init];
    for (NSInteger seconds = 0; seconds <= 5; ++seconds) {
        NSString* title = seconds == 0
            ? strings::get(Str::option_off)
            : [NSString stringWithFormat:strings::get(Str::seconds_format), (long)seconds];
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:title action:@selector(setCountIn:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(seconds);
        item.state = seconds == _countInSeconds
            ? NSControlStateValueOn : NSControlStateValueOff;
        [countInMenu addItem:item];
    }
    countIn.submenu = countInMenu;
    [practiceMenu addItem:countIn];

    NSMenuItem* offset = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_latency_offset)
               action:nil keyEquivalent:@""];
    NSMenu* offsetMenu = [[NSMenu alloc] init];
    for (NSNumber* value in @[@(-150), @(-75), @(0), @(75), @(150)]) {
        const NSInteger ms = value.integerValue;
        NSString* title = ms == 0
            ? @"0 ms"
            : [NSString stringWithFormat:@"%@%ld ms", ms > 0 ? @"+" : @"", (long)ms];
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:title action:@selector(setLatencyOffset:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = value;
        item.state = ms == _latencyOffsetMs
            ? NSControlStateValueOn : NSControlStateValueOff;
        [offsetMenu addItem:item];
    }
    offset.submenu = offsetMenu;
    offset.enabled = _playback->practice_mode();
    [practiceMenu addItem:offset];

    NSMenuItem* drill = [[NSMenuItem alloc]
        initWithTitle:strings::get(_drill.empty() ? Str::menu_drill : Str::menu_stop_drill)
               action:_drill.empty() ? @selector(startDrill:) : @selector(stopDrill:)
        keyEquivalent:@""];
    drill.target = self;
    drill.enabled = self.queueDelegate != nil && [self.queueDelegate queueCount] > 0;
    [practiceMenu addItem:drill];

    NSMenuItem* restartPhrase = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_restart_phrase)
               action:@selector(restartPracticePhrase:)
        keyEquivalent:@""];
    restartPhrase.target = self;
    restartPhrase.enabled = _playback->practice_mode();
    [practiceMenu addItem:restartPhrase];

    NSMenuItem* summary = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_show_summary)
               action:@selector(toggleShowSummary:)
        keyEquivalent:@""];
    summary.target = self;
    summary.state = settings::get_bool(kSettingShowSummary, true)
        ? NSControlStateValueOn : NSControlStateValueOff;
    summary.enabled = _playback->practice_mode();
    [practiceMenu addItem:summary];

    NSMenuItem* insights = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_practice_insights)
               action:@selector(showPracticeDashboard:)
        keyEquivalent:@""];
    insights.target = self;
    insights.enabled = _playback->practice_mode();
    [practiceMenu addItem:insights];

    practiceItem.submenu = practiceMenu;
    [menu addItem:practiceItem];

    NSMenuItem* playbackItem = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_playback) action:nil keyEquivalent:@""];
    NSMenu* playbackMenu = [[NSMenu alloc] initWithTitle:playbackItem.title];
    NSMenuItem* reset = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_reset_speed)
                                                   action:@selector(resetSpeed:)
                                            keyEquivalent:@""];
    NSMenuItem* background = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_play_background)
               action:@selector(togglePlayInBackground:) keyEquivalent:@""];
    background.target = self;
    background.state = _playInBackground
        ? NSControlStateValueOn : NSControlStateValueOff;
    [playbackMenu addItem:background];

    NSMenuItem* ap = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_autopause)
                                                action:@selector(toggleAutoPause:)
                                         keyEquivalent:@""];
    ap.target = self;
    ap.state = _autoPauseOnBlur ? NSControlStateValueOn : NSControlStateValueOff;
    [playbackMenu addItem:ap];

    reset.target = self;
    [playbackMenu addItem:reset];
    playbackItem.submenu = playbackMenu;
    [menu addItem:playbackItem];

    NSMenuItem* accessibilityItem = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_accessibility) action:nil keyEquivalent:@""];
    NSMenu* accessibilityMenu =
        [[NSMenu alloc] initWithTitle:accessibilityItem.title];
    NSMenuItem* motion = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_reduced_motion)
               action:@selector(toggleReducedMotion:) keyEquivalent:@""];
    motion.target = self;
    motion.state = _reducedMotion ? NSControlStateValueOn : NSControlStateValueOff;
    [accessibilityMenu addItem:motion];
    NSMenuItem* highContrast = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_high_contrast)
               action:@selector(toggleHighContrast:) keyEquivalent:@""];
    highContrast.target = self;
    highContrast.state = _highContrast
        ? NSControlStateValueOn : NSControlStateValueOff;
    [accessibilityMenu addItem:highContrast];
    accessibilityItem.submenu = accessibilityMenu;
    [menu addItem:accessibilityItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Theme submenu — one item per registered theme, current one checked.
    NSMenuItem* themeItem = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_theme)
                                                       action:nil keyEquivalent:@""];
    NSMenu* themeMenu = [[NSMenu alloc] init];
    const std::string curTheme = themes::current().id;
    const BOOL zhThemes = strings::current() == Lang::chinese;
    for (const Theme& t : themes::all()) {
        const std::string& label = (zhThemes && !t.name_zh.empty()) ? t.name_zh : t.name;
        NSMenuItem* it = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithUTF8String:label.c_str()]
                   action:@selector(selectTheme:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = [NSString stringWithUTF8String:t.id.c_str()];
        it.state = (t.id == curTheme) ? NSControlStateValueOn : NSControlStateValueOff;
        [themeMenu addItem:it];
    }
    themeItem.submenu = themeMenu;
    [menu addItem:themeItem];

    // Language submenu.
    NSMenuItem* langItem = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_language)
                                                      action:nil keyEquivalent:@""];
    NSMenu* langMenu = [[NSMenu alloc] init];
    const BOOL zh = strings::current() == Lang::chinese;
    NSMenuItem* en = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_lang_english)
                                                action:@selector(selectLanguage:) keyEquivalent:@""];
    en.target = self; en.representedObject = @"en";
    en.state = zh ? NSControlStateValueOff : NSControlStateValueOn;
    [langMenu addItem:en];
    NSMenuItem* cn = [[NSMenuItem alloc] initWithTitle:strings::get(Str::menu_lang_chinese)
                                                action:@selector(selectLanguage:) keyEquivalent:@""];
    cn.target = self; cn.representedObject = @"zh";
    cn.state = zh ? NSControlStateValueOn : NSControlStateValueOff;
    [langMenu addItem:cn];
    langItem.submenu = langMenu;
    [menu addItem:langItem];

    return menu;
}

- (void)resetSpeed:(id)sender {
    _playback->set_speed(1.0);
    [self refresh];
}

// Gear button — pops the same menu the right-click gesture shows, anchored
// just under the button.
- (void)showSettingsMenu:(id)sender {
    // A grid click posts key-down immediately and normally releases it on the
    // matching mouse-up. Opening a menu can move that mouse-up into AppKit's
    // menu tracking loop, so release defensively before changing focus.
    [_key_grid releaseHeldKey];
    NSButton* button = _settingsButton;
    NSMenu* menu = [self panelContextMenu];
    const NSPoint origin = NSMakePoint(0, NSHeight(button.bounds) + 4);
    [menu popUpMenuPositioningItem:nil atLocation:origin inView:button];
    // Return keyboard note input to the grid after the menu is dismissed, but
    // do not steal focus from another window opened by a menu action.
    if (self.window.isKeyWindow) {
        [self.window makeFirstResponder:_key_grid];
    }
}

- (void)selectTheme:(NSMenuItem*)sender {
    NSString* id = sender.representedObject;
    if (id == nil) {
        return;
    }
    themes::set_current(id.UTF8String);
    settings::set_string(kSettingTheme, id.UTF8String);
    [self applyTheme];
}

- (void)selectLanguage:(NSMenuItem*)sender {
    NSString* code = sender.representedObject;
    if (code == nil) {
        return;
    }
    strings::set_current([code isEqualToString:@"zh"] ? Lang::chinese : Lang::english);
    settings::set_string(kSettingLang, code.UTF8String);
    [self applyLocalization];
}

// Keep the empty-state CTA's title, icon, tooltip, and accessibility metadata
// together so theme and language changes update the complete control.
- (void)styleOpenButton {
    NSMutableParagraphStyle* p = [[NSMutableParagraphStyle alloc] init];
    p.alignment = NSTextAlignmentCenter;
    _openButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:strings::get(Str::open_songs)
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: gold(),
                NSParagraphStyleAttributeName: p,
            }];
    NSString* preferredIcon =
        symbol(@"folder.badge.plus", 16, NSFontWeightMedium) != nil
            ? @"folder.badge.plus" : @"folder";
    _openButton.image = tinted_symbol(preferredIcon, 16, NSFontWeightMedium, gold());
    _openButton.imagePosition = NSImageLeft;
    _openButton.imageHugsTitle = YES;
    _openButton.toolTip = strings::get(Str::open_button_help);
    _openButton.accessibilityRole = NSAccessibilityButtonRole;
    _openButton.accessibilityLabel = strings::get(Str::open_songs_accessibility);
    _openButton.accessibilityHelp = strings::get(Str::open_button_help);
}

// Re-color everything that caches a theme color, then force a redraw.
- (void)applyTheme {
    [self styleOpenButton];
    _panel.layer.borderColor = themes::current().border.CGColor;
    _tintView.layer.backgroundColor = themes::current().panel_tint.CGColor;
    _titleLabel.textColor = ink();
    _metaLabel.textColor = ink_soft();
    _time.textColor = ink_soft();
    _duration.textColor = ink_faint();
    _openButton.contentTintColor = gold();
    // Re-tint the header chrome glyphs.
    _addButton.image = tinted_symbol(@"plus", 10, NSFontWeightSemibold, ink_soft());
    _settingsButton.image = tinted_symbol(@"gearshape.fill", 10, NSFontWeightSemibold, ink_soft());
    _collapseButton.image = tinted_symbol(_collapsed ? @"chevron.down" : @"chevron.up",
                                          10, NSFontWeightSemibold, ink_soft());
    _hideButton.image = tinted_symbol(@"xmark", 10, NSFontWeightSemibold, ink_soft());
    _key_grid.needsDisplay = YES;
    _progress.needsDisplay = YES;
    _miniProgress.needsDisplay = YES;
    [_statusPill setNeedsDisplay:YES];
    [self reloadQueuePicker];  // re-colors the popup's item titles
    [self refresh];  // re-applies accent-driven button glyphs + status
}

// Re-string every static label/tooltip after a language change.
- (void)applyLocalization {
    _addButton.toolTip = strings::get(Str::tip_add);
    _settingsButton.toolTip = strings::get(Str::tip_settings);
    _collapseButton.toolTip = strings::get(Str::tip_collapse);
    _hideButton.toolTip = strings::get(Str::tip_close);
    [self styleOpenButton];
    _openButton.toolTip = strings::get(Str::open_button_help);
    _songPicker.toolTip = strings::get(Str::tip_playlist);
    _prevButton.toolTip = strings::get(Str::tip_previous);
    _loopButton.toolTip = strings::get(Str::tip_loop);
    _playPause.toolTip = strings::get(Str::tip_playpause);
    _stopButton.toolTip = strings::get(Str::tip_stop);
    _nextButton.toolTip = strings::get(Str::tip_next);
    _speedButton.toolTip = strings::get(Str::tip_speed);
    [self reloadQueueMetadata];  // title/meta strings
    [self refresh];              // status/hint strings
}

- (void)handleGlobalKey:(NSEvent*)event {
    const NSEventModifierFlags flags =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

    if (_playback->practice_mode() &&
        (flags & NSEventModifierFlagCommand) != 0 && event.keyCode == 36) {
        [self restartPracticePhrase:nil];
        return;
    }
    if (_playback->practice_mode() && flags == 0 && event.keyCode == 53) {
        [self stopPlayback:nil];
        return;
    }

    // In learn mode, observe the same 21 note keys the game receives and let
    // the practice controller advance only after the expected note/chord is
    // played. The event is only observed here; it still reaches Genshin.
    if (_playback->practice_mode() &&
        (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                  NSEventModifierFlagControl)) == 0) {
        const std::optional<Key> key = key_from_event(event);
        if (key.has_value()) {
            [self practiceKeyPressed:@(static_cast<NSInteger>(*key))];
        }
    }

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
        _songPicker.title = @"";
        _songPicker.menu_ = nil;
        return;
    }

    NSInteger idx = [q queueCurrentIndex];
    if (idx < 0) {
        idx = 0;
    }

    // Build the playlist menu; the current song is checked.
    NSMenu* menu = [[NSMenu alloc] init];
    const NSInteger currentIndex = [q queueCurrentIndex];
    NSMenuItem* favoritesOnly = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_favorites_only)
               action:@selector(toggleFavoritesOnly:) keyEquivalent:@""];
    favoritesOnly.target = self;
    favoritesOnly.state = _favoritesOnly
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:favoritesOnly];

    if (currentIndex >= 0 && currentIndex < count) {
        const BOOL favorite = [q queueIsFavoriteAtIndex:currentIndex];
        NSMenuItem* favoriteItem = [[NSMenuItem alloc]
            initWithTitle:favorite
                ? strings::get(Str::menu_queue_unfavorite)
                : strings::get(Str::menu_queue_favorite)
                   action:@selector(toggleFavoriteForSong:)
            keyEquivalent:@""];
        favoriteItem.target = self;
        favoriteItem.representedObject = @{@"songIndex": @(currentIndex)};
        [menu addItem:favoriteItem];
    }

    NSArray<NSNumber*>* recentIndexes = [q queueRecentIndexes];
    NSMutableArray<NSNumber*>* visibleRecentIndexes = [NSMutableArray array];
    for (NSNumber* number in recentIndexes) {
        const NSInteger recentIndex = number.integerValue;
        if (!_favoritesOnly || [q queueIsFavoriteAtIndex:recentIndex]) {
            [visibleRecentIndexes addObject:number];
        }
    }
    if (visibleRecentIndexes.count > 0) {
        NSMenuItem* recent = [[NSMenuItem alloc]
            initWithTitle:strings::get(Str::menu_recent)
                   action:nil keyEquivalent:@""];
        NSMenu* recentMenu = [[NSMenu alloc] initWithTitle:recent.title];
        for (NSNumber* number in visibleRecentIndexes) {
            const NSInteger recentIndex = number.integerValue;
            NSString* title = [q queueTitleAtIndex:recentIndex] ?: @"";
            NSMenuItem* recentItem = [[NSMenuItem alloc]
                initWithTitle:title action:@selector(songMenuPicked:)
                 keyEquivalent:@""];
            recentItem.target = self;
            recentItem.representedObject = @{
                @"songIndex": @(recentIndex),
                @"sourceIndex": @(-1),
            };
            [recentMenu addItem:recentItem];
        }
        recent.submenu = recentMenu;
        [menu addItem:recent];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* moveUp = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_queue_move_up)
               action:@selector(moveCurrentSong:) keyEquivalent:@""];
    moveUp.target = self;
    moveUp.tag = -1;
    moveUp.enabled = currentIndex > 0;
    [menu addItem:moveUp];

    NSMenuItem* moveDown = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_queue_move_down)
               action:@selector(moveCurrentSong:) keyEquivalent:@""];
    moveDown.target = self;
    moveDown.tag = 1;
    moveDown.enabled = currentIndex >= 0 && currentIndex + 1 < count;
    [menu addItem:moveDown];

    NSMenuItem* remove = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_queue_remove)
               action:@selector(removeSongFromQueue:) keyEquivalent:@""];
    remove.target = self;
    remove.representedObject = @{@"songIndex": @(currentIndex)};
    remove.enabled = currentIndex >= 0;
    [menu addItem:remove];

    NSMenuItem* clear = [[NSMenuItem alloc]
        initWithTitle:strings::get(Str::menu_queue_clear)
               action:@selector(clearQueue:) keyEquivalent:@""];
    clear.target = self;
    [menu addItem:clear];
    [menu addItem:[NSMenuItem separatorItem]];

    NSInteger visibleSongs = 0;
    for (NSInteger i = 0; i < count; ++i) {
        if (_favoritesOnly && ![q queueIsFavoriteAtIndex:i]) {
            continue;
        }
        ++visibleSongs;
        NSString* t = [q queueTitleAtIndex:i] ?: @"";
        if ([q queueIsFavoriteAtIndex:i]) {
            t = [NSString stringWithFormat:@"★ %@", t];
        }
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:t
                                                      action:@selector(songMenuPicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{@"songIndex": @(i), @"sourceIndex": @(-1)};
        item.state = (i == idx) ? NSControlStateValueOn : NSControlStateValueOff;

        const NSInteger sourceCount = [q queueSourceCountAtIndex:i];
        if (sourceCount > 1) {
            NSMenu* sources = [[NSMenu alloc] initWithTitle:t];
            const NSInteger selectedSource = [q queueSelectedSourceIndexAtIndex:i];
            for (NSInteger source = 0; source < sourceCount; ++source) {
                NSString* sourceTitle = [q queueSourceTitleAtIndex:i sourceIndex:source];
                NSMenuItem* sourceItem = [[NSMenuItem alloc] initWithTitle:sourceTitle
                                                                       action:@selector(songMenuPicked:)
                                                                keyEquivalent:@""];
                sourceItem.target = self;
                sourceItem.representedObject = @{
                    @"songIndex": @(i),
                    @"sourceIndex": @(source),
                };
                sourceItem.state = (i == idx && source == selectedSource)
                    ? NSControlStateValueOn
                    : NSControlStateValueOff;
                [sources addItem:sourceItem];
            }
            item.submenu = sources;
        }
        [menu addItem:item];
    }
    if (visibleSongs == 0) {
        NSString* title = _favoritesOnly
            ? strings::get(Str::menu_no_favorites) : strings::get(Str::no_song_selected);
        NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:title
                                                        action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
    }
    _songPicker.menu_ = menu;
    _songPicker.title = (idx < count) ? ([q queueTitleAtIndex:idx] ?: @"") : @"";
    _songPicker.needsDisplay = YES;
}

- (void)songMenuPicked:(NSMenuItem*)sender {
    NSDictionary* selection = sender.representedObject;
    if (selection == nil) {
        return;
    }
    const NSInteger songIndex = [selection[@"songIndex"] integerValue];
    const NSInteger sourceIndex = [selection[@"sourceIndex"] integerValue];
    [self loadQueueIndex:songIndex sourceIndex:sourceIndex autoplay:NO];
}

- (void)moveCurrentSong:(NSMenuItem*)sender {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q != nil && [q queueMoveCurrentBy:sender.tag]) {
        [self reloadQueuePicker];
        [self reloadQueueMetadata];
        [self refresh];
    }
}

- (void)toggleFavoriteForSong:(NSMenuItem*)sender {
    NSDictionary* selection = sender.representedObject;
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil || selection == nil) {
        return;
    }
    [q queueToggleFavoriteAtIndex:[selection[@"songIndex"] integerValue]];
    [self reloadQueuePicker];
}

- (void)removeSongFromQueue:(NSMenuItem*)sender {
    NSDictionary* selection = sender.representedObject;
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil || selection == nil) {
        return;
    }
    const NSInteger index = [selection[@"songIndex"] integerValue];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Remove “%@” from the queue?",
        [q queueTitleAtIndex:index] ?: @""];
    alert.informativeText = @"The file will not be deleted.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    if ([q queueRemoveIndex:index]) {
        [self reloadQueuePicker];
        [self reloadQueueMetadata];
        [self refresh];
    }
}

- (void)clearQueue:(id)sender {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil || [q queueCount] == 0) {
        return;
    }
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Clear the playlist?";
    alert.informativeText = @"The files will not be deleted.";
    [alert addButtonWithTitle:@"Clear"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    [q queueClear];
    [self reloadQueuePicker];
    [self reloadQueueMetadata];
    [self refresh];
}

- (void)reloadQueueMetadata {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    const NSInteger count = [q queueCount];
    if (count == 0) {
        _titleLabel.stringValue = strings::get(Str::no_song_selected);
        _titleLabel.toolTip = strings::get(Str::no_song_selected);
        _metaLabel.stringValue = strings::get(Str::open_to_begin);
        return;
    }
    const NSInteger idx = [q queueCurrentIndex];
    NSString* title = idx >= 0 ? ([q queueTitleAtIndex:idx] ?: @"Untitled")
                               : strings::get(Str::no_song_selected);
    const NSInteger bpm = idx >= 0 ? [q queueBpmAtIndex:idx] : 0;
    _songBpm = bpm;
    _playback->set_metronome_bpm(_metronomeMode == 2 ? static_cast<int>(bpm) : 0);
    _titleLabel.stringValue = title;
    _titleLabel.toolTip = title;
    NSString* mode = _playback->practice_mode()
        ? strings::get(Str::mode_practice) : strings::get(Str::mode_automatic);
    NSString* meta = bpm > 0
        ? [NSString stringWithFormat:@"%@ · %ld BPM", mode, (long)bpm]
        : [NSString stringWithFormat:@"%@ · %@", mode, strings::get(Str::lyre)];
    if (count > 1 && idx >= 0) {
        meta = [NSString stringWithFormat:@"%@   %ld/%ld", meta,
                (long)(idx + 1), (long)count];
    } else if (idx < 0) {
        meta = [NSString stringWithFormat:@"%ld %@", (long)count,
                strings::get(Str::songs_suffix)];
    }
    _metaLabel.stringValue = meta;
}

- (void)loadQueueIndex:(NSInteger)index autoplay:(BOOL)autoplay {
    [self loadQueueIndex:index sourceIndex:-1 autoplay:autoplay];
}

- (void)loadQueueIndex:(NSInteger)index
           sourceIndex:(NSInteger)sourceIndex
              autoplay:(BOOL)autoplay {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil || index < 0 || index >= [q queueCount]) {
        return;
    }
    _playback->stop();
    if (![q queueLoadIndex:index sourceIndex:sourceIndex]) {
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
    const NSInteger count = [q queueCount];
    if (count == 0) {
        return;
    }
    const BOOL wasPlaying = _playback->snapshot().state != PlaybackState::stopped;
    // Wrap: stepping back past the first song lands on the last.
    const NSInteger prev = ([q queueCurrentIndex] - 1 + count) % count;
    [self loadQueueIndex:prev autoplay:wasPlaying];
}

- (void)nextSong {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    const NSInteger count = [q queueCount];
    if (count == 0) {
        return;
    }
    const BOOL wasPlaying = _playback->snapshot().state != PlaybackState::stopped;
    // Wrap: stepping forward past the last song lands on the first.
    const NSInteger next = ([q queueCurrentIndex] + 1) % count;
    [self loadQueueIndex:next autoplay:wasPlaying];
}

- (void)songPickerChanged:(NSPopUpButton*)sender {
    [self loadQueueIndex:sender.indexOfSelectedItem autoplay:NO];
}

- (void)openSongs:(id)sender {
    if (_openPanelActive) {
        return;
    }
    // Bring this app forward so the file picker takes keyboard focus and comes
    // to the front (the HUD normally runs as a non-activating accessory).
    [NSApp activateIgnoringOtherApps:YES];

    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"genshinsheet"],
        [UTType typeWithFilenameExtension:@"mid"],
        [UTType typeWithFilenameExtension:@"midi"]
    ];
    panel.message = strings::get(Str::panel_message);
    panel.prompt = strings::get(Str::panel_add);
    // A standalone (non-sheet) panel is a normal, movable window — the user can
    // drag it anywhere, unlike a sheet glued to the HUD. Raise it above the
    // HUD's screen-saver-level window so it isn't hidden behind it.
    panel.level = NSScreenSaverWindowLevel + 1;

    // Keep the HUD on-screen while the picker is up (opening it focuses this
    // app, not Genshin, which would otherwise hide the HUD).
    _openPanelActive = YES;
    if (!self.window.isVisible) {
        [self.window orderFrontRegardless];
    }

    [panel beginWithCompletionHandler:^(NSInteger result) {
        _openPanelActive = NO;
        if (result != NSModalResponseOK) {
            [self.window makeFirstResponder:_openButton];
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
        // New songs are appended to the end of the queue. Jump to the first of
        // them so the freshly-added song becomes the current one, ready to play.
        const NSInteger firstAdded = [q queueCount];
        const NSInteger added = [q queueAddPaths:paths];
        if (added == 0) {
            // The files may have been added as alternate sources to an
            // existing song; refresh the menu even though no new song row was
            // created.
            [self reloadQueuePicker];
            if ([q queueCount] == 0) {
                NSAlert* alert = [[NSAlert alloc] init];
                alert.messageText = strings::get(Str::open_no_compatible);
                alert.informativeText = strings::get(Str::open_button_help);
                [alert addButtonWithTitle:strings::get(Str::panel_ok)];
                [alert runModal];
            }
            return;
        }
        [self loadQueueIndex:firstAdded autoplay:NO];
    }];
}

#pragma mark - Collapse / drag

- (void)toggleCollapse {
    _collapsed = !_collapsed;
    settings::set_bool(kSettingCollapsed, _collapsed);
    [self applyCollapseState:YES];
}

- (void)applyCollapseState:(BOOL)animated {
    if (_reducedMotion) {
        animated = NO;
    }
    _miniProgress.hidden = !_collapsed;
    _collapseButton.image = tinted_symbol(_collapsed ? @"chevron.down" : @"chevron.up",
                                          10, NSFontWeightSemibold, ink_soft());
    const CGFloat target_h = _collapsed ? kMiniH : kH;
    NSRect frame = self.window.frame;
    frame.origin.y = NSMaxY(frame) - target_h;
    frame.size.height = target_h;

    if (!animated) {
        _expandedSection.hidden = _collapsed;
        _expandedSection.alphaValue = _collapsed ? 0.0 : 1.0;
        [self.window setFrame:frame display:YES];
        return;
    }

    if (_collapsed) {
        // Collapsing: fade the body out first, then slide the panel closed so the
        // content dissolves instead of clipping mid-slide.
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
            ctx.duration = 0.12;
            _expandedSection.animator.alphaValue = 0.0;
        } completionHandler:^{
            _expandedSection.hidden = YES;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
                ctx.duration = 0.18;
                ctx.timingFunction = [CAMediaTimingFunction
                    functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [self.window.animator setFrame:frame display:YES];
            } completionHandler:nil];
        }];
    } else {
        // Expanding: open the panel first (body still hidden), then fade it in as
        // the space appears.
        _expandedSection.alphaValue = 0.0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
            ctx.duration = 0.18;
            ctx.timingFunction = [CAMediaTimingFunction
                functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.window.animator setFrame:frame display:YES];
        } completionHandler:^{
            _expandedSection.hidden = NO;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
                ctx.duration = 0.14;
                _expandedSection.animator.alphaValue = 1.0;
            } completionHandler:nil];
        }];
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
        // Bring the game forward once at launch so it's ready to receive keys and
        // the HUD (which only shows while Genshin is focused) is actually
        // visible. Done regardless of the background-play setting: that setting
        // governs whether playback needs focus, not this one-time launch focus.
        if (!_didActivateGenshin) {
            _didActivateGenshin = YES;
            _genshin->activate_application();
        }
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
    [_key_grid releaseHeldKey];
    _dragging = YES;
    _dragStartMouse = NSEvent.mouseLocation;
    _dragStartOrigin = self.window.frame.origin;
}

- (void)windowDidResignKey:(NSNotification*)notification {
    // Never leave a synthetic key held when AppKit transfers focus to a menu,
    // file picker, dashboard, or another application.
    [_key_grid releaseHeldKey];
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
    // The focus timer intentionally ignores active drags. Reconcile once the
    // drag ends so a moved HUD cannot remain at stale visibility/placement.
    [self updateFocusAppearance];
}

- (void)menuDidBeginTracking:(NSNotification*)notification {
    ++_menuTrackingDepth;
    [self updateFocusAppearance];
}

- (void)menuDidEndTracking:(NSNotification*)notification {
    _menuTrackingDepth = std::max<NSInteger>(0, _menuTrackingDepth - 1);
    [self updateFocusAppearance];
}

- (void)workspaceFocusChanged:(NSNotification*)notification {
    [self updateFocusAppearance];
}

#pragma mark - Refresh

// Follow the Genshin window and show/hide the HUD with focus. Runs on a timer
// so the HUD travels with the game and vanishes cleanly when Genshin isn't
// frontmost (no faint ghost hovering over other apps).
- (void)updateFocusAppearance {
    if (_dragging) {
        return;  // don't fight an active drag
    }
    std::optional<NSRect> game;
    if (_genshin_pid != 0) {
        game = game_frame(_genshin_pid, nullptr);
    }
    if (_genshin_pid == 0 ||
        [NSRunningApplication runningApplicationWithProcessIdentifier:_genshin_pid] == nil ||
        !game.has_value()) {
        _genshin_pid = genshin_pid();
        if (_genshin_pid != 0) {
            game = game_frame(_genshin_pid, nullptr);
        }
    }
    // Keystrokes go straight to this pid, so playback reaches the game even
    // while it is in the background.
    _keyboard->set_target_pid(_genshin_pid);
    const BOOL focused = genshin_is_focused(_genshin_pid);

    // Treat "we're driving our own UI" (pointer over the HUD, or the file
    // picker open) as not-a-real-blur, so those interactions don't hide the HUD
    // or pause playback.
    const BOOL hudVisible = self.window.isVisible;
    const BOOL pointerOverHud = hudVisible &&
        NSPointInRect(NSEvent.mouseLocation, self.window.frame);
    const BOOL selfInteracting = (hudVisible &&
        (_pointerInside || pointerOverHud)) ||
        _openPanelActive || _menuTrackingDepth > 0;

    const PlaybackState playbackState = _playback->snapshot().state;

    // Auto-pause when Genshin loses focus to ANOTHER app — but not for the
    // brief blur caused by interacting with the HUD itself, otherwise pressing
    // play would instantly pause playback.
    if (!_playInBackground && _autoPauseOnBlur && _wasFocused && !focused && !selfInteracting &&
        playbackState == PlaybackState::playing) {
        _playback->pause();
    }
    // Only update the focus edge-tracker once we're done with our own UI, so a
    // HUD click / picker doesn't register as a focus loss on the next real blur.
    if (!selfInteracting) {
        _wasFocused = focused;
    }

    // Visibility follows Genshin focus. The HUD shows only when:
    //   - Genshin is the frontmost app, or
    //   - our own process is frontmost (file picker / dashboard in use), or
    //   - Genshin isn't running at all (so the HUD is reachable to load songs).
    // A running-but-hidden game (minimized, ⌘H, another Space) counts as
    // unfocused — the HUD must never float over some other app.
    NSRunningApplication* frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    const BOOL ownAppFrontmost = frontmost != nil &&
        frontmost.processIdentifier == NSProcessInfo.processInfo.processIdentifier;
    const BOOL genshinRunning = _genshin_pid != 0;
    const BOOL shouldShow = focused || ownAppFrontmost || !genshinRunning;

    // The practice dashboard floats too; hide and restore it alongside the HUD.
    NSWindow* dashboard = _practiceDashboard.window;
    if (!shouldShow) {
        if (self.window.isVisible) {
            [self.window orderOut:nil];
        }
        if (dashboard.isVisible) {
            [dashboard orderOut:nil];
            _dashboardHiddenForBlur = YES;
        }
        return;
    }
    if (_dashboardHiddenForBlur) {
        _dashboardHiddenForBlur = NO;
        [dashboard orderFrontRegardless];
    }

    // Follow the current game window position (keeping the user's dragged
    // offset, if any).
    if (_genshin_pid != 0 && game.has_value()) {
            const NSPoint want = [self hudOriginForGameFrame:*game];
            const NSPoint have = self.window.frame.origin;
            if (std::abs(want.x - have.x) > 0.5 || std::abs(want.y - have.y) > 0.5) {
                [self.window setFrameOrigin:want];
            }
    }

    self.window.alphaValue = 1.0;
    if (!self.window.isVisible) {
        [self.window orderFrontRegardless];
    }
}

- (void)refresh {
    _playback->practice_tick();
    const PlaybackSnapshot s = _playback->snapshot();
    if (_playback->practice_mode()) {
        [[self practiceDashboard] setSongKey:_titleLabel.stringValue];
    }
    // If the drill just moved on, the nested refresh it triggered has already
    // drawn the new phrase; don't overwrite it from this stale snapshot.
    if ([self updateDrill:s]) {
        return;
    }
    [self applyMetronome];
    [_key_grid decayPulse];
    [_statusPill tick];
    _key_grid.practiceMode = _playback->practice_mode();
    _key_grid.reducedMotion = _reducedMotion;
    _key_grid.highContrast = _highContrast;

    if (s.practice_beat_sequence != _lastMetronomeBeat) {
        const BOOL shouldPlayMetronome = _metronomeMode == 1 &&
            _playback->practice_mode() && _playback->practice_tempo();
        _lastMetronomeBeat = s.practice_beat_sequence;
        if (shouldPlayMetronome) {
            NSSound* sound = [NSSound soundNamed:@"Tink"];
            [sound play];
        }
    }

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
            _statusPill.pulsing = !_reducedMotion;
            _statusPill.toolTip = strings::get(Str::counting_in);
            _playPause.image = tinted_symbol(@"pause.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::playing:
            _statusPill.tint = gold();
            _statusPill.pulsing = !_reducedMotion;
            _statusPill.toolTip = strings::get(Str::playing);
            _playPause.image = tinted_symbol(@"pause.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::paused:
            _statusPill.tint = ink_soft();
            _statusPill.pulsing = NO;
            _statusPill.toolTip = strings::get(Str::paused);
            _playPause.image = tinted_symbol(@"play.fill", 18, NSFontWeightMedium, gold());
            break;
        case PlaybackState::stopped:
            _statusPill.tint = ink_faint();
            _statusPill.pulsing = NO;
            _statusPill.toolTip = empty ? strings::get(Str::no_song) : strings::get(Str::idle);
            _playPause.image = tinted_symbol(@"play.fill", 18, NSFontWeightMedium, gold());
            break;
    }

    // Dim the transport/seek when there is nothing loaded.
    const CGFloat controlsAlpha = empty ? 0.35 : 1.0;
    _controls.alphaValue = controlsAlpha;
    _progress.alphaValue = controlsAlpha;

    NSString* phraseLabel = s.practice_phrase_count > 0
        ? [NSString stringWithFormat:strings::get(Str::learn_phrase_of),
            static_cast<unsigned long>(s.practice_phrase_index + 1),
            static_cast<unsigned long>(s.practice_phrase_count)]
        : @"";
    if (!_drill.empty()) {
        phraseLabel = [NSString stringWithFormat:@"%@ · %@",
            [NSString stringWithFormat:strings::get(Str::drill_status),
                static_cast<unsigned long>(_drillPos + 1),
                static_cast<unsigned long>(_drill.size())],
            phraseLabel];
    }
    NSString* practiceFeedback = nil;
    switch (s.practice_feedback) {
        case PracticeInputResult::wrong:
            practiceFeedback = strings::get(Str::learn_wrong);
            break;
        case PracticeInputResult::partial:
            practiceFeedback = s.practice_expected_count > 0
                ? [NSString stringWithFormat:@"%@ %lu/%lu",
                    strings::get(Str::learn_partial),
                    static_cast<unsigned long>(s.practice_pressed_count),
                    static_cast<unsigned long>(s.practice_expected_count)]
                : strings::get(Str::learn_partial);
            break;
        case PracticeInputResult::early:
            practiceFeedback = strings::get(Str::learn_early);
            break;
        case PracticeInputResult::late:
            practiceFeedback = strings::get(Str::learn_late);
            break;
        case PracticeInputResult::missed:
            practiceFeedback = strings::get(Str::learn_missed);
            break;
        default:
            break;
    }
    NSString* practiceCue = nil;
    if (!s.current_note.empty()) {
        NSString* current = [NSString stringWithUTF8String:s.current_note.c_str()];
        if (_showUpcoming && !s.next_note.empty()) {
            practiceCue = [NSString stringWithFormat:@"%@: %@  ·  %@: %@",
                strings::get(Str::learn_now), current,
                strings::get(Str::learn_next),
                [NSString stringWithUTF8String:s.next_note.c_str()]];
        } else {
            practiceCue = [NSString stringWithFormat:@"%@: %@",
                strings::get(Str::learn_now), current];
        }
    }
    if (_playback->practice_mode() && s.state == PlaybackState::playing) {
        _hint.textColor = gold();
        if (practiceCue == nil) {
            _hint.stringValue = strings::get(Str::learn_complete);
        } else {
            NSString* line = practiceFeedback != nil
                ? [NSString stringWithFormat:@"%@ · %@", practiceFeedback, practiceCue]
                : [NSString stringWithFormat:@"%@ · %@", phraseLabel, practiceCue];
            // Show the combo once it's worth celebrating.
            if (s.practice_stats.streak >= 5) {
                line = [NSString stringWithFormat:@"%@ · %@", line,
                    [NSString stringWithFormat:strings::get(Str::learn_streak),
                        static_cast<unsigned long>(s.practice_stats.streak)]];
            }
            _hint.stringValue = line;
        }
    } else if (_playback->practice_mode() && s.state == PlaybackState::paused) {
        _hint.textColor = ink_soft();
        _hint.stringValue = practiceCue == nil
            ? strings::get(Str::learn_complete)
            : [NSString stringWithFormat:@"%@ · %@ · %@",
                phraseLabel,
                strings::get(Str::paused),
                practiceCue];
    } else if (_playback->practice_mode() && s.progress >= 1.0 && !empty) {
        _hint.textColor = gold();
        _hint.stringValue = strings::get(Str::learn_complete);
    } else if (_playback->practice_mode() && !empty) {
        _hint.textColor = ink_faint();
        _hint.stringValue = [NSString stringWithFormat:@"%@ · %@",
            phraseLabel, strings::get(Str::learn_ready)];
    } else if (s.state == PlaybackState::countdown) {
        _hint.textColor = gold();
        _hint.stringValue = [NSString stringWithFormat:@"%@ %lld…",
            strings::get(Str::starting_in), countdown_secs];
    } else if (empty && s.state == PlaybackState::stopped) {
        _hint.textColor = ink_faint();
        _hint.stringValue = strings::get(Str::open_formats);
    } else {
        _hint.stringValue = @"";
    }
    if (_flashHint != nil && NSDate.timeIntervalSinceReferenceDate < _flashHintUntil) {
        _hint.textColor = gold();
        _hint.stringValue = _flashHint;
    } else {
        _flashHint = nil;
    }
}

#pragma mark - Drill weakest phrases

- (void)flashHint:(NSString*)message {
    _flashHint = [message copy];
    _flashHintUntil = NSDate.timeIntervalSinceReferenceDate + 4.0;
    [self refresh];
}

// Gather the weakest practiced phrases across the whole playlist from saved
// history (best accuracy below the solid threshold), weakest first.
- (void)startDrill:(id)sender {
    id<PlayerQueueDelegate> q = self.queueDelegate;
    if (q == nil) {
        return;
    }
    nlohmann::json history = nlohmann::json::object();
    try {
        history = nlohmann::json::parse(settings::get_json("practice_history", "{}"));
    } catch (...) {
    }
    std::vector<DrillItem> candidates;
    const NSInteger count = [q queueCount];
    for (NSInteger i = 0; i < count && history.is_object(); ++i) {
        const std::string title = [q queueResolvedTitleAtIndex:i].UTF8String ?: "";
        if (!history.contains(title) || !history[title].is_object()) {
            continue;
        }
        const nlohmann::json& song = history[title];
        if (!song.contains("phrase_best") || !song["phrase_best"].is_array()) {
            continue;
        }
        const nlohmann::json& bests = song["phrase_best"];
        for (std::size_t phrase = 0; phrase < bests.size(); ++phrase) {
            if (!bests[phrase].is_number()) {
                continue;
            }
            const double best = bests[phrase].get<double>();
            if (best > 0.0 && best < kDrillThreshold) {
                candidates.push_back({i, phrase, best});
            }
        }
    }
    std::stable_sort(candidates.begin(), candidates.end(),
                     [](const DrillItem& a, const DrillItem& b) { return a.best < b.best; });
    if (candidates.size() > kDrillLength) {
        candidates.resize(kDrillLength);
    }
    if (candidates.empty()) {
        [self flashHint:strings::get(Str::drill_none)];
        return;
    }
    _drill = std::move(candidates);
    _drillPos = 0;
    [self loadDrillItem];
}

- (void)loadDrillItem {
    if (_drillPos >= _drill.size()) {
        [self stopDrill:nil];
        [self flashHint:strings::get(Str::drill_done)];
        return;
    }
    const DrillItem item = _drill[_drillPos];
    id<PlayerQueueDelegate> q = self.queueDelegate;
    _drillLoading = YES;
    if (!_playback->practice_mode()) {
        _playback->set_practice_mode(true);
        settings::set_bool(kSettingLearn, true);
    }
    if (q != nil && [q queueCurrentIndex] != item.song) {
        [self loadQueueIndex:item.song autoplay:NO];
    }
    // Same song: jump in place (no stop, so no per-step session summary).
    _playback->practice_jump_to_phrase(item.phrase, true);
    [self startPlayback];
    _drillLoading = NO;
    [self refresh];
}

- (void)stopDrill:(id)sender {
    _drill.clear();
    _drillPos = 0;
    _playback->practice_unpin_phrase();
    [self refresh];
}

// Advance the drill when the pinned phrase is mastered; cancel it if the user
// leaves the drill (switches songs, unpins, or leaves Learn mode). Returns YES
// when it advanced (and therefore already refreshed the HUD).
- (BOOL)updateDrill:(const PlaybackSnapshot&)s {
    if (_drill.empty() || _drillLoading) {
        return NO;
    }
    const DrillItem& item = _drill[_drillPos];
    id<PlayerQueueDelegate> q = self.queueDelegate;
    const bool onItem = _playback->practice_mode() && q != nil &&
        [q queueCurrentIndex] == item.song &&
        s.practice_stats.pinned_phrase == item.phrase;
    if (!onItem) {
        _drill.clear();
        _drillPos = 0;
        return NO;
    }
    if (item.phrase < s.practice_stats.phrases.size() &&
        s.practice_stats.phrases[item.phrase].mastered) {
        ++_drillPos;
        [self loadDrillItem];
        return YES;
    }
    return NO;
}

@end
