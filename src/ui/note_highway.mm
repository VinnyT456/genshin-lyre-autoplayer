#import "note_highway.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "playback_controller.h"
#include "settings.h"
#include "strings.h"
#include "theme.h"

namespace {

constexpr const char* kSettingLookahead = "highway_lookahead_ms";
constexpr double kDefaultLookaheadMs = 2400.0;   // wall-clock time a note is visible
constexpr double kMinLookaheadMs = 1000.0;
constexpr double kMaxLookaheadMs = 5000.0;
constexpr double kHitFlashMs = 180.0;            // key flash after a note lands
constexpr double kLaneCount = 21.0;

constexpr const char* kKeyLabels[21] = {
    "Q", "W", "E", "R", "T", "Y", "U",
    "A", "S", "D", "F", "G", "H", "J",
    "Z", "X", "C", "V", "B", "N", "M",
};

// Lanes run low → high pitch, left → right: Z-row, then A-row, then Q-row.
int lane_for(Key key) {
    const int k = static_cast<int>(key);
    return (2 - k / 7) * 7 + k % 7;
}

// Row 0 = low (Z…M), 1 = mid (A…J), 2 = high (Q…U), by lane.
int row_for_lane(int lane) { return lane / 7; }

NSColor* row_color(int row) {
    const Theme& t = themes::current();
    // High row is the pure accent; lower rows lean toward ink so the three
    // octaves read apart without leaving the theme's palette.
    const CGFloat toward_ink[3] = {0.42, 0.22, 0.0};
    return [t.accent blendedColorWithFraction:toward_ink[row] ofColor:t.ink] ?: t.accent;
}

// Blend (source-over) instead of NSRectFill's copy, so the theme's translucent
// colors layer correctly over the panel background.
void fill_rect(NSRect r) {
    NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
}

}  // namespace

@interface NoteHighwayView : NSView
@property(nonatomic) PlaybackController* playback;
@property(nonatomic) double lookaheadMs;
@end

@implementation NoteHighwayView {
    std::vector<Note> _notes;
    std::size_t _revision;
    double _displayMs;         // eased song position for wait-for-input practice
    CFTimeInterval _lastFrame;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)tick {
    if (_playback == nullptr || !self.window.isVisible) {
        return;
    }
    const HighwayClock clock = _playback->highway_clock();
    if (clock.notes_revision != _revision) {
        _notes = _playback->notes();
        _revision = clock.notes_revision;
        _displayMs = clock.song_ms;
    }
    const CFTimeInterval now = CACurrentMediaTime();
    const double dt = _lastFrame > 0 ? std::min(0.1, now - _lastFrame) : 0.0;
    _lastFrame = now;
    if (clock.practice && !clock.tempo && std::abs(clock.song_ms - _displayMs) < 4000.0) {
        // Waiting for input: glide to the next note instead of jumping.
        _displayMs += (clock.song_ms - _displayMs) * (1.0 - std::exp(-dt / 0.09));
    } else {
        _displayMs = clock.song_ms;
    }
    self.needsDisplay = YES;
}

- (void)scrollWheel:(NSEvent*)event {
    // Scroll to zoom: up shows further ahead (notes fall slower).
    const double factor = std::exp(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08));
    _lookaheadMs = std::clamp(_lookaheadMs * factor, kMinLookaheadMs, kMaxLookaheadMs);
    self.needsDisplay = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveLookahead) object:nil];
    [self performSelector:@selector(saveLookahead) withObject:nil afterDelay:0.6];
}

- (void)saveLookahead {
    settings::set_int(kSettingLookahead, static_cast<int>(std::lround(_lookaheadMs)));
}

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const NSRect b = self.bounds;
    const CGFloat W = NSWidth(b);
    const CGFloat H = NSHeight(b);
    const CGFloat keyH = 30.0;
    const CGFloat hitY = H - keyH - 8.0;
    const CGFloat laneW = W / kLaneCount;

    // Opaque base (the panel itself is opaque), then the theme's tint on top.
    [[NSColor colorWithCalibratedWhite:0.11 alpha:1.0] setFill];
    NSRectFill(b);
    [theme.panel_tint setFill];
    fill_rect(b);

    // Octave bands and lane separators.
    for (int row = 0; row < 3; ++row) {
        [[theme.ink colorWithAlphaComponent:row == 1 ? 0.045 : 0.02] setFill];
        fill_rect(NSMakeRect(row * 7 * laneW, 0, 7 * laneW, hitY));
    }
    for (int lane = 1; lane < 21; ++lane) {
        const bool rowEdge = lane % 7 == 0;
        [[theme.ink colorWithAlphaComponent:rowEdge ? 0.14 : 0.05] setFill];
        fill_rect(NSMakeRect(std::round(lane * laneW) - 0.5, 0, rowEdge ? 1.0 : 0.5, hitY));
    }

    if (_notes.empty()) {
        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: theme.ink_faint
        };
        NSString* text = strings::get(Str::highway_empty);
        const NSSize size = [text sizeWithAttributes:attrs];
        [text drawAtPoint:NSMakePoint((W - size.width) * 0.5, (hitY - size.height) * 0.5)
           withAttributes:attrs];
    }

    const HighwayClock clock = _playback != nullptr ? _playback->highway_clock() : HighwayClock{};
    const double speed = std::max(0.05, clock.speed);
    const double nowMs = _displayMs;
    const double pxPerWallMs = hitY / _lookaheadMs;
    auto yFor = [&](double t) { return hitY - (t - nowMs) / speed * pxPerWallMs; };

    // Visible song-time window: a little below the hit line up to the top.
    const double lowestMs = nowMs - (keyH + 8.0) / pxPerWallMs * speed;
    const double highestMs = nowMs + _lookaheadMs * speed;
    auto first = std::lower_bound(_notes.begin(), _notes.end(), lowestMs,
        [](const Note& n, double t) { return static_cast<double>(n.timestamp.count()) < t; });

    const bool waiting = clock.practice;          // practice highlights a target note
    const std::size_t target = clock.practice_index;
    const CGFloat pillH = std::clamp(laneW * 0.55, 8.0, 14.0);
    const CGFloat pillInset = std::max(1.5, laneW * 0.1);
    double keyGlow[21] = {0};

    NSDictionary* labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:std::clamp(laneW * 0.42, 7.0, 10.0)
                                                weight:NSFontWeightBold],
        NSForegroundColorAttributeName: theme.on_accent
    };

    // Hit line (under the notes, so a note sitting on it stays readable).
    [[theme.accent colorWithAlphaComponent:0.18] setFill];
    fill_rect(NSMakeRect(0, hitY - 3.0, W, 6.0));
    [[theme.accent colorWithAlphaComponent:0.85] setFill];
    fill_rect(NSMakeRect(0, hitY - 0.75, W, 1.5));

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(0, 0, W, H - keyH - 1.0));
    for (auto it = first; it != _notes.end(); ++it) {
        const double t = static_cast<double>(it->timestamp.count());
        if (t > highestMs) {
            break;
        }
        const std::size_t index = static_cast<std::size_t>(it - _notes.begin());
        const CGFloat y = yFor(t);
        const double sinceHitWall = (nowMs - t) / speed;   // > 0 once it has landed

        // Practice: notes before the target are done; the target glows.
        const bool isTarget = waiting && index == target;
        const bool done = waiting ? index < target : sinceHitWall > 0;
        CGFloat alpha = 1.0;
        if (done) {
            alpha = std::clamp(1.0 - std::max(0.0, sinceHitWall) / 260.0, 0.0, 1.0) * 0.55;
            if (waiting) alpha = 0.18;
            if (alpha <= 0.01) continue;
        } else if (waiting && index > target) {
            alpha = 0.78;
        }

        // Chord connector behind the pills.
        if (it->keys.size() > 1) {
            int lo = 21, hi = -1;
            for (Key k : it->keys) { lo = std::min(lo, lane_for(k)); hi = std::max(hi, lane_for(k)); }
            [[theme.accent colorWithAlphaComponent:0.35 * alpha] setFill];
            fill_rect(NSMakeRect((lo + 0.5) * laneW, y - 1.0, (hi - lo) * laneW, 2.0));
        }
        for (Key k : it->keys) {
            const int lane = lane_for(k);
            const NSRect pill = NSMakeRect(lane * laneW + pillInset, y - pillH * 0.5,
                                           laneW - pillInset * 2.0, pillH);
            if (isTarget) {
                [[theme.accent colorWithAlphaComponent:0.30] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, -3.0, -3.0)
                                                 xRadius:pillH * 0.5 + 3.0
                                                 yRadius:pillH * 0.5 + 3.0] fill];
                keyGlow[lane] = std::max(keyGlow[lane], 0.75);
            }
            [[row_color(row_for_lane(lane)) colorWithAlphaComponent:alpha] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:pillH * 0.5
                                             yRadius:pillH * 0.5] fill];
            if (laneW >= 15.0 && alpha > 0.5) {
                NSString* label = @(kKeyLabels[static_cast<int>(k)]);
                const NSSize size = [label sizeWithAttributes:labelAttrs];
                [label drawAtPoint:NSMakePoint(NSMidX(pill) - size.width * 0.5,
                                               NSMidY(pill) - size.height * 0.5)
                    withAttributes:labelAttrs];
            }
            // Autoplay / timed practice: flash the key as the note lands.
            if (!waiting || clock.tempo) {
                if (sinceHitWall >= 0.0 && sinceHitWall < kHitFlashMs) {
                    keyGlow[lane] = std::max(keyGlow[lane], 1.0 - sinceHitWall / kHitFlashMs);
                }
            }
        }
    }

    [NSGraphicsContext restoreGraphicsState];


    // Mini lyre keyboard.
    const CGFloat keyTop = H - keyH;
    NSDictionary* keyAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:std::clamp(laneW * 0.45, 7.0, 10.0)
                                                          weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: theme.ink_soft
    };
    for (int lane = 0; lane < 21; ++lane) {
        const NSRect key = NSInsetRect(NSMakeRect(lane * laneW, keyTop, laneW, keyH - 3.0), 1.0, 0.0);
        const double glow = keyGlow[lane];
        NSColor* fill = glow > 0.0
            ? [row_color(row_for_lane(lane)) colorWithAlphaComponent:0.25 + 0.65 * glow]
            : [theme.ink colorWithAlphaComponent:0.07];
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:key xRadius:3.0 yRadius:3.0] fill];
        [[theme.ink colorWithAlphaComponent:0.10] setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(key, 0.5, 0.5) xRadius:3.0 yRadius:3.0] stroke];

        // Lane index → Key: invert lane_for.
        const int keyIndex = (2 - lane / 7) * 7 + lane % 7;
        NSString* label = @(kKeyLabels[keyIndex]);
        NSMutableDictionary* attrs = [keyAttrs mutableCopy];
        if (glow > 0.4) attrs[NSForegroundColorAttributeName] = theme.on_accent;
        const NSSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMidX(key) - size.width * 0.5,
                                       NSMidY(key) - size.height * 0.5)
            withAttributes:attrs];
    }
}

@end

@implementation NoteHighwayController {
    NoteHighwayView* _view;
    NSTimer* _timer;
}

- (instancetype)initWithPlayback:(PlaybackController*)playback {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 420, 380)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:panel];
    if (self == nil) {
        return nil;
    }
    // Same layer as the HUD so it stays above the game window.
    panel.level = NSScreenSaverWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.contentMinSize = NSMakeSize(300, 220);

    _view = [[NoteHighwayView alloc] initWithFrame:panel.contentView.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.playback = playback;
    _view.lookaheadMs = std::clamp(
        static_cast<double>(settings::get_int(kSettingLookahead,
                                              static_cast<int>(kDefaultLookaheadMs))),
        kMinLookaheadMs, kMaxLookaheadMs);
    panel.contentView = _view;
    [self reloadStrings];

    _timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                     target:_view
                                   selector:@selector(tick)
                                   userInfo:nil
                                    repeats:YES];
    _timer.tolerance = 0.002;
    // Common modes: keep animating while a menu is open or the window is dragged.
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)reloadStrings {
    self.window.title = strings::get(Str::highway_title);
    _view.needsDisplay = YES;
}

@end
