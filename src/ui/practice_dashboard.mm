#import "practice_dashboard.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>

#include <nlohmann/json.hpp>

#include "playback_controller.h"
#include "settings.h"
#include "strings.h"
#include "theme.h"

static NSColor* dashboard_accent() { return themes::current().accent; }
static NSColor* dashboard_ink() { return themes::current().ink; }
static NSColor* dashboard_soft() { return themes::current().ink_soft; }
static NSColor* dashboard_faint() { return themes::current().ink_faint; }

// Semantic colors for the timing breakdown. On-time uses the theme accent;
// the rest are fixed hues so "late" / "missed" read the same in every theme.
static NSColor* timing_early_color() { return [NSColor systemTealColor]; }
static NSColor* timing_late_color() { return [NSColor systemOrangeColor]; }
static NSColor* timing_missed_color() { return [NSColor systemRedColor]; }

// Phrases need this many consecutive clean repetitions to count as mastered.
// Mirrors kMasteryCleanReps in playback_controller.cpp.
static constexpr std::size_t kCleanRunsToMaster = 3;

static NSString* percent(double value) {
    return [NSString stringWithFormat:@"%.0f%%", value * 100.0];
}

static NSString* count_value(std::size_t value) {
    return [NSString stringWithFormat:@"%lu", static_cast<unsigned long>(value)];
}

static NSString* phrase_name(std::size_t zeroBasedIndex) {
    return [NSString stringWithFormat:strings::get(Str::dashboard_phrase),
        static_cast<unsigned long>(zeroBasedIndex + 1)];
}

// Map a practice run to a Genshin-flavored letter grade. Accuracy is the
// backbone; a run with many mistimed inputs is nudged down one tier so a
// sloppy-but-lucky pass never reads as flawless. Returns "—" before any notes.
static NSString* grade_letter(const PracticeStatsSnapshot& stats) {
    if (stats.notes_completed == 0) {
        return @"—";
    }
    double score = std::clamp(stats.accuracy, 0.0, 1.0);
    const std::size_t mistimed = stats.early_inputs + stats.late_inputs;
    const double mistimed_ratio =
        static_cast<double>(mistimed) / stats.notes_completed;
    // Shave up to ~8% for chronic rushing/dragging; leaves accuracy in charge.
    score -= std::min(0.08, mistimed_ratio * 0.15);
    if (score >= 0.98) return @"S";
    if (score >= 0.92) return @"A";
    if (score >= 0.82) return @"B";
    if (score >= 0.70) return @"C";
    return @"D";
}

static NSColor* grade_color(NSString* letter) {
    if ([letter isEqualToString:@"S"]) {
        return [NSColor systemYellowColor];   // gold — flawless
    }
    if ([letter isEqualToString:@"A"] || [letter isEqualToString:@"B"]) {
        return dashboard_accent();
    }
    if ([letter isEqualToString:@"—"]) {
        return dashboard_faint();
    }
    return dashboard_soft();
}

static NSTextField* make_label(NSString* text, CGFloat size, NSFontWeight weight,
                               NSColor* color) {
    NSTextField* label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSTextField* make_number(CGFloat size, NSColor* color) {
    NSTextField* label = [NSTextField labelWithString:@"—"];
    label.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSTextField* make_section_title(NSString* text) {
    NSTextField* label = make_label(text.uppercaseString, 9, NSFontWeightSemibold,
                                    dashboard_faint());
    // Letter-spaced small caps read as a section header, distinct from values.
    label.attributedStringValue = [[NSAttributedString alloc]
        initWithString:text.uppercaseString
            attributes:@{NSFontAttributeName: label.font,
                         NSForegroundColorAttributeName: dashboard_faint(),
                         NSKernAttributeName: @0.8}];
    return label;
}

// A quiet rounded surface that groups related numbers.
@interface PracticeCardView : NSView
@end

@implementation PracticeCardView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 9.0;
        self.layer.backgroundColor =
            [dashboard_ink() colorWithAlphaComponent:0.055].CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor =
            [dashboard_ink() colorWithAlphaComponent:0.07].CGColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return self;
}
@end

// Thin horizontal progress track (mastery).
@interface PracticeProgressTrack : NSView
@property(nonatomic) double fraction;
@end

@implementation PracticeProgressTrack
- (void)setFraction:(double)fraction {
    _fraction = std::clamp(fraction, 0.0, 1.0);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    const CGFloat r = NSHeight(b) * 0.5;
    [[dashboard_ink() colorWithAlphaComponent:0.10] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r] fill];
    if (_fraction > 0.0) {
        NSRect fill = b;
        fill.size.width = std::max(NSHeight(b), NSWidth(b) * _fraction);
        [dashboard_accent() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:r yRadius:r] fill];
    }
}
@end

// Stacked bar: on time | early | late | missed.
@interface PracticeTimingBar : NSView
- (void)setOnTime:(std::size_t)onTime early:(std::size_t)early
             late:(std::size_t)late missed:(std::size_t)missed;
@end

@implementation PracticeTimingBar {
    std::size_t _counts[4];
}

- (void)setOnTime:(std::size_t)onTime early:(std::size_t)early
             late:(std::size_t)late missed:(std::size_t)missed {
    _counts[0] = onTime;
    _counts[1] = early;
    _counts[2] = late;
    _counts[3] = missed;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    const CGFloat r = NSHeight(b) * 0.5;
    NSBezierPath* track = [NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r];
    [[dashboard_ink() colorWithAlphaComponent:0.10] setFill];
    [track fill];

    const std::size_t total = _counts[0] + _counts[1] + _counts[2] + _counts[3];
    if (total == 0) {
        return;
    }
    NSColor* colors[4] = {dashboard_accent(), timing_early_color(),
                          timing_late_color(), timing_missed_color()};
    [NSGraphicsContext saveGraphicsState];
    [track addClip];
    CGFloat x = NSMinX(b);
    std::size_t drawn = 0;
    for (int i = 0; i < 4; ++i) {
        if (_counts[i] == 0) {
            continue;
        }
        // Hairline gap between segments so adjacent hues stay distinct.
        if (drawn > 0) {
            [[themes::current().panel_tint colorWithAlphaComponent:0.9] setFill];
            NSRectFill(NSMakeRect(x - 0.75, NSMinY(b), 1.5, NSHeight(b)));
        }
        const CGFloat w = NSWidth(b) * static_cast<CGFloat>(_counts[i]) / total;
        [colors[i] setFill];
        NSRectFill(NSMakeRect(x + (drawn > 0 ? 0.75 : 0.0), NSMinY(b),
                              w - (drawn > 0 ? 0.75 : 0.0), NSHeight(b)));
        x += w;
        ++drawn;
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

@interface PracticeChartView : NSView
// Called with the phrase index when a column is clicked.
@property(nonatomic, copy) void (^onSelectPhrase)(std::size_t phrase);
@property(nonatomic) std::size_t pinned;  // looping phrase, or kNoPhrase
- (void)setPhraseStats:(const std::vector<PracticePhraseSnapshot>&)stats
                 ghost:(const std::vector<double>&)ghost
               current:(std::size_t)current
                 focus:(std::size_t)focus;
@end

@implementation PracticeChartView {
    std::vector<PracticePhraseSnapshot> _stats;
    std::vector<double> _ghost;  // best accuracy per phrase before this session
    std::size_t _current;        // phrase being practiced now
    std::size_t _focus;          // weakest unmastered phrase
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)setPinned:(std::size_t)pinned {
    if (_pinned != pinned) {
        _pinned = pinned;
        self.needsDisplay = YES;
    }
}

// Same horizontal layout as drawRect: 26 pt left gutter, 4 pt right.
- (void)mouseDown:(NSEvent*)event {
    if (_stats.empty() || self.onSelectPhrase == nil) {
        return;
    }
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat left = 26.0;
    const CGFloat width = std::max(1.0, NSWidth(self.bounds) - left - 4.0);
    if (p.x < left || p.x > left + width) {
        return;
    }
    const std::size_t index = std::min(_stats.size() - 1, static_cast<std::size_t>(
        (p.x - left) / (width / static_cast<CGFloat>(_stats.size()))));
    self.onSelectPhrase(index);
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)setPhraseStats:(const std::vector<PracticePhraseSnapshot>&)stats
                 ghost:(const std::vector<double>&)ghost
               current:(std::size_t)current
                 focus:(std::size_t)focus {
    _stats = stats;
    _ghost = ghost;
    _current = current;
    _focus = focus;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bounds = self.bounds;
    const CGFloat left = 26.0;    // room for the 50/100 guide labels
    const CGFloat right = 4.0;
    const CGFloat top = 16.0;     // room for value labels above full bars
    const CGFloat bottom = 20.0;
    const CGFloat chartHeight = std::max(1.0, NSHeight(bounds) - top - bottom);
    const CGFloat chartWidth = std::max(1.0, NSWidth(bounds) - left - right);
    const CGFloat baseY = top + chartHeight;

    NSDictionary* axisAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8
                                                              weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: dashboard_faint()
    };

    // Guide lines at 50% and 100%, plus the baseline.
    for (double level : {0.5, 1.0}) {
        const CGFloat y = baseY - chartHeight * level;
        [[dashboard_faint() colorWithAlphaComponent:0.22] setStroke];
        NSBezierPath* guide = [NSBezierPath bezierPath];
        [guide moveToPoint:NSMakePoint(left, y)];
        [guide lineToPoint:NSMakePoint(left + chartWidth, y)];
        guide.lineWidth = 1.0;
        const CGFloat dash[2] = {1.0, 3.0};
        [guide setLineDash:dash count:2 phase:0.0];
        [guide stroke];
        NSString* label = level >= 1.0 ? @"100" : @"50";
        const NSSize size = [label sizeWithAttributes:axisAttrs];
        [label drawAtPoint:NSMakePoint(left - 5.0 - size.width, y - size.height * 0.5)
            withAttributes:axisAttrs];
    }
    [[dashboard_faint() colorWithAlphaComponent:0.35] setStroke];
    NSBezierPath* baseline = [NSBezierPath bezierPath];
    [baseline moveToPoint:NSMakePoint(left, baseY)];
    [baseline lineToPoint:NSMakePoint(left + chartWidth, baseY)];
    baseline.lineWidth = 1.0;
    [baseline stroke];

    bool hasData = false;
    for (const PracticePhraseSnapshot& stats : _stats) {
        if (stats.completed_notes > 0 || stats.wrong_keys > 0) {
            hasData = true;
            break;
        }
    }
    for (double g : _ghost) {
        hasData = hasData || g > 0.0;
    }
    if (_stats.empty() || !hasData) {
        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: dashboard_faint()
        };
        NSString* empty = strings::get(Str::dashboard_no_data);
        const NSSize size = [empty sizeWithAttributes:attrs];
        [empty drawAtPoint:NSMakePoint(left + (chartWidth - size.width) * 0.5,
                                       top + (chartHeight - size.height) * 0.5)
            withAttributes:attrs];
        return;
    }

    const CGFloat slot = chartWidth / static_cast<CGFloat>(_stats.size());
    const CGFloat barWidth = std::clamp(slot * 0.62, 3.0, 34.0);
    // Dense songs get too many phrases to label every column legibly.
    const std::size_t labelStride = slot >= 16.0 ? 1 : (slot >= 8.0 ? 2 : 5);
    for (std::size_t i = 0; i < _stats.size(); ++i) {
        const PracticePhraseSnapshot& stats = _stats[i];
        const CGFloat x = left + slot * static_cast<CGFloat>(i) +
            (slot - barWidth) * 0.5;
        const bool played = stats.completed_notes > 0 || stats.wrong_keys > 0;
        const bool isCurrent = i == _current;

        // Current phrase: a soft column wash so it is findable at a glance.
        if (isCurrent) {
            [[dashboard_ink() colorWithAlphaComponent:0.045] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:
                NSMakeRect(left + slot * i + 1.0, top - 12.0, slot - 2.0, chartHeight + 12.0)
                xRadius:4.0 yRadius:4.0] fill];
        }

        if (i == _pinned) {
            [dashboard_accent() setStroke];
            NSBezierPath* ring = [NSBezierPath bezierPathWithRoundedRect:
                NSInsetRect(NSMakeRect(left + slot * i + 1.0, top - 12.0, slot - 2.0,
                                       chartHeight + 12.0), 0.75, 0.75)
                xRadius:4.0 yRadius:4.0];
            ring.lineWidth = 1.5;
            [ring stroke];
            NSDictionary* loopAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: dashboard_accent()
            };
            const NSSize loopSize = [@"↻" sizeWithAttributes:loopAttrs];
            [@"↻" drawAtPoint:NSMakePoint(left + slot * i + (slot - loopSize.width) * 0.5,
                                         top - 12.0)
               withAttributes:loopAttrs];
        }

        const double value = std::clamp(stats.accuracy, 0.0, 1.0);
        const CGFloat valueHeight = played ? std::max(3.0, chartHeight * value) : 0.0;
        if (valueHeight > 0.0) {
            const NSRect bar = NSMakeRect(x, baseY - valueHeight, barWidth, valueHeight);
            // Heatmap: mastered = solid accent; otherwise colored by accuracy so
            // trouble spots stand out across the whole song.
            NSColor* color = stats.mastered ? dashboard_accent()
                : value >= 0.9 ? [dashboard_accent() colorWithAlphaComponent:0.6]
                : value >= 0.7 ? [timing_late_color() colorWithAlphaComponent:0.75]
                : [timing_missed_color() colorWithAlphaComponent:0.75];
            [color setFill];
            const CGFloat radius = std::min(3.0, barWidth * 0.3);
            [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:radius yRadius:radius] fill];
        }

        // Ghost target: dashed cap at the best accuracy from before this
        // session, so a bar that rises past it visibly beats a personal best.
        const double ghost = i < _ghost.size() ? std::clamp(_ghost[i], 0.0, 1.0) : 0.0;
        if (ghost > 0.001) {
            const CGFloat ghostY = baseY - chartHeight * ghost;
            [[dashboard_ink() colorWithAlphaComponent:0.55] setStroke];
            NSBezierPath* cap = [NSBezierPath bezierPath];
            [cap moveToPoint:NSMakePoint(x - 2.0, ghostY)];
            [cap lineToPoint:NSMakePoint(x + barWidth + 2.0, ghostY)];
            cap.lineWidth = 1.5;
            const CGFloat dash[2] = {3.0, 2.0};
            [cap setLineDash:dash count:2 phase:0.0];
            [cap stroke];
        }

        // Value label above played bars (only when columns are wide enough).
        if (played && slot >= 22.0) {
            NSString* text = stats.mastered ? @"✓" :
                [NSString stringWithFormat:@"%.0f", value * 100.0];
            NSDictionary* attrs = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5
                                                                      weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: stats.mastered
                    ? dashboard_accent() : dashboard_soft()
            };
            const NSSize size = [text sizeWithAttributes:attrs];
            const CGFloat labelY = std::max(0.0, baseY - valueHeight - size.height - 1.0);
            [text drawAtPoint:NSMakePoint(x + (barWidth - size.width) * 0.5, labelY)
                withAttributes:attrs];
        }

        // Phrase number: current in ink, focus in accent, others faint.
        if (i % labelStride == 0 || isCurrent || i == _focus) {
            NSString* label = [NSString stringWithFormat:@"%lu",
                static_cast<unsigned long>(i + 1)];
            NSColor* color = isCurrent ? dashboard_ink()
                : (i == _focus ? dashboard_accent() : dashboard_faint());
            NSDictionary* attrs = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9
                    weight:(isCurrent || i == _focus) ? NSFontWeightBold
                                                      : NSFontWeightMedium],
                NSForegroundColorAttributeName: color
            };
            const NSSize size = [label sizeWithAttributes:attrs];
            [label drawAtPoint:NSMakePoint(left + slot * i + (slot - size.width) * 0.5,
                                           baseY + 5.0)
                withAttributes:attrs];
        }
    }
}

@end

// Histogram of input offsets from the beat: early on the left, late on the
// right, with the target (0 ms) marked. Shows rushing/dragging at a glance.
@interface PracticeOffsetHistogram : NSView
- (void)setBins:(const std::vector<std::size_t>&)bins minMs:(int)minMs maxMs:(int)maxMs;
@end

@implementation PracticeOffsetHistogram {
    std::vector<std::size_t> _bins;
    int _minMs;
    int _maxMs;
}

- (BOOL)isFlipped { return YES; }

- (void)setBins:(const std::vector<std::size_t>&)bins minMs:(int)minMs maxMs:(int)maxMs {
    _bins = bins;
    _minMs = minMs;
    _maxMs = maxMs;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = self.bounds;
    const CGFloat labelH = 12.0;
    const CGFloat chartH = std::max(1.0, NSHeight(b) - labelH - 2.0);
    const CGFloat baseY = chartH;
    const int span = std::max(1, _maxMs - _minMs);
    auto xFor = [&](int ms) {
        return NSMinX(b) + NSWidth(b) * static_cast<CGFloat>(ms - _minMs) / span;
    };

    [[dashboard_faint() colorWithAlphaComponent:0.35] setStroke];
    NSBezierPath* baseline = [NSBezierPath bezierPath];
    [baseline moveToPoint:NSMakePoint(NSMinX(b), baseY)];
    [baseline lineToPoint:NSMakePoint(NSMaxX(b), baseY)];
    [baseline stroke];

    std::size_t peak = 0;
    for (std::size_t v : _bins) {
        peak = std::max(peak, v);
    }
    if (peak > 0) {
        const CGFloat slot = NSWidth(b) / static_cast<CGFloat>(_bins.size());
        for (std::size_t i = 0; i < _bins.size(); ++i) {
            if (_bins[i] == 0) {
                continue;
            }
            // Brightest at the beat, fading with distance. Teal/orange stay
            // reserved for the Early/Late categories in the bar above.
            const double centerMs = _minMs + (i + 0.5) * span / _bins.size();
            const double closeness = std::clamp(1.0 - std::abs(centerMs) / 120.0, 0.0, 1.0);
            NSColor* color = [dashboard_accent() colorWithAlphaComponent:0.35 + 0.65 * closeness];
            const CGFloat h = std::max(2.0, chartH * _bins[i] / static_cast<double>(peak));
            [color setFill];
            [[NSBezierPath bezierPathWithRoundedRect:
                NSMakeRect(NSMinX(b) + slot * i + 0.75, baseY - h, slot - 1.5, h)
                xRadius:1.5 yRadius:1.5] fill];
        }
    }

    // Beat marker at 0 ms.
    const CGFloat zeroX = xFor(0);
    [[dashboard_ink() colorWithAlphaComponent:0.6] setStroke];
    NSBezierPath* zero = [NSBezierPath bezierPath];
    [zero moveToPoint:NSMakePoint(zeroX, 0)];
    [zero lineToPoint:NSMakePoint(zeroX, baseY)];
    zero.lineWidth = 1.0;
    [zero stroke];

    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8
                                                              weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: dashboard_faint()
    };
    NSString* lo = [NSString stringWithFormat:@"%d ms", _minMs];
    NSString* hi = [NSString stringWithFormat:@"+%d ms", _maxMs];
    [lo drawAtPoint:NSMakePoint(NSMinX(b), baseY + 2.0) withAttributes:attrs];
    const NSSize zeroSize = [@"0" sizeWithAttributes:attrs];
    [@"0" drawAtPoint:NSMakePoint(zeroX - zeroSize.width * 0.5, baseY + 2.0) withAttributes:attrs];
    const NSSize hiSize = [hi sizeWithAttributes:attrs];
    [hi drawAtPoint:NSMakePoint(NSMaxX(b) - hiSize.width, baseY + 2.0) withAttributes:attrs];
}

@end

// Accuracy across recent sessions, oldest left. Dots mark each session; the
// latest is emphasized.
@interface PracticeProgressChart : NSView
- (void)setValues:(const std::vector<double>&)values;
@end

@implementation PracticeProgressChart {
    std::vector<double> _values;
}

- (BOOL)isFlipped { return YES; }

- (void)setValues:(const std::vector<double>&)values {
    _values = values;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect b = NSMakeRect(NSMinX(self.bounds) + 26.0, NSMinY(self.bounds) + 5.0,
                                NSWidth(self.bounds) - 30.0, NSHeight(self.bounds) - 10.0);
    // Scale to the user's actual range (rounded down to 10%) so progress is
    // visible instead of hugging the top of a 0-100% axis.
    double low = 1.0;
    for (double v : _values) {
        low = std::min(low, v);
    }
    low = std::clamp(std::floor((low - 0.05) * 10.0) / 10.0, 0.0, 0.9);
    auto yFor = [&](double v) {
        return NSMaxY(b) - NSHeight(b) * (std::clamp(v, low, 1.0) - low) / (1.0 - low);
    };
    NSDictionary* axisAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8
                                                              weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: dashboard_faint()
    };
    for (double level : {low, 1.0}) {
        const CGFloat y = yFor(level);
        NSString* label = [NSString stringWithFormat:@"%.0f", level * 100.0];
        const NSSize size = [label sizeWithAttributes:axisAttrs];
        [label drawAtPoint:NSMakePoint(NSMinX(b) - 5.0 - size.width, y - size.height * 0.5)
            withAttributes:axisAttrs];
        [[dashboard_faint() colorWithAlphaComponent:0.22] setStroke];
        NSBezierPath* guide = [NSBezierPath bezierPath];
        [guide moveToPoint:NSMakePoint(NSMinX(b), y)];
        [guide lineToPoint:NSMakePoint(NSMaxX(b), y)];
        const CGFloat dash[2] = {1.0, 3.0};
        [guide setLineDash:dash count:2 phase:0.0];
        [guide stroke];
    }
    if (_values.empty()) {
        return;
    }
    auto pointAt = [&](std::size_t i) {
        const CGFloat x = _values.size() == 1 ? NSMidX(b)
            : NSMinX(b) + NSWidth(b) * i / static_cast<CGFloat>(_values.size() - 1);
        return NSMakePoint(x, yFor(_values[i]));
    };
    if (_values.size() > 1) {
        NSBezierPath* line = [NSBezierPath bezierPath];
        [line moveToPoint:pointAt(0)];
        for (std::size_t i = 1; i < _values.size(); ++i) {
            [line lineToPoint:pointAt(i)];
        }
        line.lineWidth = 1.75;
        line.lineJoinStyle = NSLineJoinStyleRound;
        [[dashboard_accent() colorWithAlphaComponent:0.8] setStroke];
        [line stroke];
    }
    for (std::size_t i = 0; i < _values.size(); ++i) {
        const bool latest = i + 1 == _values.size();
        const CGFloat r = latest ? 3.5 : 2.0;
        const NSPoint p = pointAt(i);
        [(latest ? dashboard_accent() : [dashboard_accent() colorWithAlphaComponent:0.7]) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(p.x - r, p.y - r, r * 2, r * 2)] fill];
    }
}

@end

// A tiny color swatch + text, used by the timing and chart legends.
static NSStackView* legend_item(NSColor* color, BOOL dashed, NSTextField* __strong* text) {
    NSView* swatch = [[NSView alloc] init];
    swatch.wantsLayer = YES;
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    if (dashed) {
        CAShapeLayer* line = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, nullptr, 0, 3);
        CGPathAddLineToPoint(path, nullptr, 12, 3);
        line.path = path;
        CGPathRelease(path);
        line.strokeColor = [dashboard_ink() colorWithAlphaComponent:0.55].CGColor;
        line.lineWidth = 1.5;
        line.lineDashPattern = @[@3, @2];
        [swatch.layer addSublayer:line];
        [swatch.widthAnchor constraintEqualToConstant:12].active = YES;
    } else {
        swatch.layer.backgroundColor = color.CGColor;
        swatch.layer.cornerRadius = 2.0;
        [swatch.widthAnchor constraintEqualToConstant:8].active = YES;
    }
    [swatch.heightAnchor constraintEqualToConstant:dashed ? 6 : 8].active = YES;

    NSTextField* label = make_label(@"", 9.5, NSFontWeightMedium, dashboard_soft());
    *text = label;
    NSStackView* item = [NSStackView stackViewWithViews:@[swatch, label]];
    item.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    item.alignment = NSLayoutAttributeCenterY;
    item.spacing = 4;
    return item;
}

@interface PracticeDashboardController ()
- (NSView*)statCardWithTitle:(NSString*)title
                       value:(NSTextField* __strong*)value
                     caption:(NSTextField* __strong*)caption;
@end

@implementation PracticeDashboardController {
    PlaybackController* _playback;

    // Header
    NSTextField* _songLabel;
    NSView* _gradeTile;
    NSTextField* _grade;
    NSTextField* _gradeCaption;

    // Hero card
    NSTextField* _accuracy;
    NSTextField* _accuracyCaption;
    NSTextField* _bestLine;
    NSTextField* _masteredLine;
    PracticeProgressTrack* _masteredTrack;

    // Stat cards
    NSTextField* _notes;
    NSTextField* _wrong;
    NSTextField* _response;
    NSTextField* _streak;
    NSTextField* _streakCaption;
    NSTextField* _partials;
    NSTextField* _cleanRuns;
    NSTextField* _cleanRunsCaption;

    // Timing
    PracticeTimingBar* _timingBar;
    NSStackView* _timingLegend;
    NSTextField* _timingHint;
    NSTextField* _onTimeText;
    NSTextField* _earlyText;
    NSTextField* _lateText;
    NSTextField* _missedText;
    PracticeOffsetHistogram* _histogram;
    NSTextField* _offsetVerdict;

    // Progress over sessions
    PracticeProgressChart* _progressChart;
    NSTextField* _progressCaption;
    NSTextField* _progressHint;

    // End-of-session summary banner
    PracticeCardView* _summaryCard;
    NSTextField* _summaryHeadline;
    NSTextField* _summaryDetail;
    NSStackView* _content;

    // Phrase chart
    NSTextField* _focusLabel;
    PracticeChartView* _chart;
    NSTextField* _legendSession;
    NSTextField* _legendBest;
    NSTextField* _chartHint;

    NSTimer* _timer;
    NSString* _songKey;
    double _historicalBest;
    std::vector<double> _historicalPhrases;
    // Snapshot of the stored bests taken when the song was opened. The ghost
    // caps and "vs best" delta compare against these, not the live-updated
    // bests, so beating a personal record is actually visible.
    double _sessionStartBest;
    std::vector<double> _sessionStartPhrases;
    bool _historySessionRecorded;
    std::vector<double> _sessionLog;      // recent session accuracies, oldest first
    std::size_t _lastSession;             // stats.session seen on the last refresh
    PlaybackState _lastState;
    std::size_t _summarizedSession;       // session already logged + summarized
    std::size_t _lastSavedNotes;
    std::size_t _lastSavedWrong;
    std::size_t _lastSavedPhraseCompletions;
    NSTimeInterval _lastHistorySaveAt;
}

- (instancetype)initWithPlayback:(PlaybackController*)playback {
    const CGFloat kWidth = 420.0;
    NSPanel* window = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, kWidth, 560)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self == nil) {
        return nil;
    }

    _playback = playback;
    _songKey = @"";
    _historicalBest = 0.0;
    _sessionStartBest = 0.0;
    _historySessionRecorded = false;
    _lastSession = 0;
    _lastState = PlaybackState::stopped;
    _summarizedSession = 0;
    _lastSavedNotes = 0;
    _lastSavedWrong = 0;
    _lastSavedPhraseCompletions = 0;
    _lastHistorySaveAt = 0.0;
    window.title = strings::get(Str::dashboard_title);
    window.level = NSFloatingWindowLevel;
    window.hidesOnDeactivate = NO;
    window.becomesKeyOnlyIfNeeded = YES;
    window.backgroundColor = themes::current().panel_tint;

    NSView* root = [[NSView alloc] init];
    root.wantsLayer = YES;
    root.layer.backgroundColor = themes::current().panel_tint.CGColor;
    window.contentView = root;

    // ---- Header: title + song, grade tile pinned right ----------------------
    NSTextField* title = make_label(strings::get(Str::dashboard_title), 17,
                                    NSFontWeightSemibold, dashboard_ink());
    _songLabel = make_label(@"", 11, NSFontWeightMedium, dashboard_soft());
    NSStackView* headingText = [NSStackView stackViewWithViews:@[title, _songLabel]];
    headingText.orientation = NSUserInterfaceLayoutOrientationVertical;
    headingText.alignment = NSLayoutAttributeLeading;
    headingText.spacing = 2;

    _grade = [NSTextField labelWithString:@"—"];
    _grade.font = [NSFont systemFontOfSize:26 weight:NSFontWeightHeavy];
    _grade.alignment = NSTextAlignmentCenter;
    _gradeCaption = make_label(strings::get(Str::dashboard_grade), 8,
                               NSFontWeightSemibold, dashboard_faint());
    _gradeCaption.alignment = NSTextAlignmentCenter;
    NSStackView* gradeStack = [NSStackView stackViewWithViews:@[_grade, _gradeCaption]];
    gradeStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    gradeStack.alignment = NSLayoutAttributeCenterX;
    gradeStack.spacing = -2;
    gradeStack.translatesAutoresizingMaskIntoConstraints = NO;
    _gradeTile = [[NSView alloc] init];
    _gradeTile.wantsLayer = YES;
    _gradeTile.layer.cornerRadius = 11.0;
    _gradeTile.layer.borderWidth = 1.5;
    _gradeTile.translatesAutoresizingMaskIntoConstraints = NO;
    [_gradeTile addSubview:gradeStack];

    NSView* header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    headingText.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headingText];
    [header addSubview:_gradeTile];

    // ---- Hero card: accuracy + best delta + mastery -------------------------
    _accuracy = make_number(34, dashboard_accent());
    _accuracyCaption = make_label(strings::get(Str::dashboard_accuracy), 10,
                                  NSFontWeightMedium, dashboard_faint());
    NSStackView* accuracyStack = [NSStackView stackViewWithViews:@[_accuracy, _accuracyCaption]];
    accuracyStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    accuracyStack.alignment = NSLayoutAttributeLeading;
    accuracyStack.spacing = 0;

    _bestLine = make_label(@"", 11, NSFontWeightSemibold, dashboard_soft());
    _masteredLine = make_label(@"", 10, NSFontWeightMedium, dashboard_faint());
    _masteredTrack = [[PracticeProgressTrack alloc] init];
    _masteredTrack.translatesAutoresizingMaskIntoConstraints = NO;
    [_masteredTrack.heightAnchor constraintEqualToConstant:5].active = YES;
    NSStackView* heroRight = [NSStackView stackViewWithViews:@[
        _bestLine, _masteredLine, _masteredTrack]];
    heroRight.orientation = NSUserInterfaceLayoutOrientationVertical;
    heroRight.alignment = NSLayoutAttributeLeading;
    heroRight.spacing = 5;
    [heroRight setCustomSpacing:9 afterView:_bestLine];

    PracticeCardView* hero = [[PracticeCardView alloc] init];
    accuracyStack.translatesAutoresizingMaskIntoConstraints = NO;
    heroRight.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:accuracyStack];
    [hero addSubview:heroRight];

    // ---- Stat cards (2 x 3) --------------------------------------------------
    NSTextField* unused = nil;
    NSView* notesCard = [self statCardWithTitle:strings::get(Str::dashboard_notes)
                                          value:&_notes caption:&unused];
    NSView* wrongCard = [self statCardWithTitle:strings::get(Str::dashboard_wrong)
                                          value:&_wrong caption:&unused];
    NSView* responseCard = [self statCardWithTitle:strings::get(Str::dashboard_response)
                                             value:&_response caption:&unused];
    NSView* chordsCard = [self statCardWithTitle:strings::get(Str::dashboard_streak)
                                           value:&_streak caption:&_streakCaption];
    NSView* partialsCard = [self statCardWithTitle:strings::get(Str::dashboard_partials)
                                             value:&_partials caption:&unused];
    NSView* cleanCard = [self statCardWithTitle:strings::get(Str::dashboard_clean_runs)
                                          value:&_cleanRuns caption:&_cleanRunsCaption];
    NSStackView* rowOne = [NSStackView stackViewWithViews:@[notesCard, wrongCard, responseCard]];
    NSStackView* rowTwo = [NSStackView stackViewWithViews:@[chordsCard, partialsCard, cleanCard]];
    for (NSStackView* row in @[rowOne, rowTwo]) {
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.distribution = NSStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    // ---- Timing --------------------------------------------------------------
    NSTextField* timingTitle = make_section_title(strings::get(Str::dashboard_timing));
    _timingBar = [[PracticeTimingBar alloc] init];
    _timingBar.translatesAutoresizingMaskIntoConstraints = NO;
    [_timingBar.heightAnchor constraintEqualToConstant:8].active = YES;
    _timingLegend = [NSStackView stackViewWithViews:@[
        legend_item(dashboard_accent(), NO, &_onTimeText),
        legend_item(timing_early_color(), NO, &_earlyText),
        legend_item(timing_late_color(), NO, &_lateText),
        legend_item(timing_missed_color(), NO, &_missedText)]];
    _timingLegend.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _timingLegend.spacing = 12;
    _timingHint = make_label(strings::get(Str::dashboard_timing_hint), 10,
                             NSFontWeightRegular, dashboard_faint());
    _histogram = [[PracticeOffsetHistogram alloc] init];
    _histogram.translatesAutoresizingMaskIntoConstraints = NO;
    [_histogram.heightAnchor constraintEqualToConstant:52].active = YES;
    _offsetVerdict = make_label(@"", 10.5, NSFontWeightSemibold, dashboard_soft());

    // ---- Progress across sessions ------------------------------------------
    NSTextField* progressTitle = make_section_title(strings::get(Str::dashboard_progress));
    _progressCaption = make_label(@"", 10, NSFontWeightMedium, dashboard_faint());
    _progressCaption.alignment = NSTextAlignmentRight;
    NSStackView* progressHeader = [NSStackView stackViewWithViews:@[progressTitle, _progressCaption]];
    progressHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    progressHeader.distribution = NSStackViewDistributionEqualSpacing;
    _progressChart = [[PracticeProgressChart alloc] init];
    _progressChart.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressChart.heightAnchor constraintEqualToConstant:54].active = YES;
    _progressHint = make_label(strings::get(Str::dashboard_progress_hint), 10,
                               NSFontWeightRegular, dashboard_faint());

    // ---- Session summary banner (shown when a run ends) ----------------------
    _summaryHeadline = make_label(@"", 13, NSFontWeightBold, dashboard_ink());
    _summaryDetail = make_label(@"", 10.5, NSFontWeightMedium, dashboard_soft());
    _summaryDetail.lineBreakMode = NSLineBreakByWordWrapping;
    _summaryDetail.maximumNumberOfLines = 2;
    NSStackView* summaryText = [NSStackView stackViewWithViews:@[_summaryHeadline, _summaryDetail]];
    summaryText.orientation = NSUserInterfaceLayoutOrientationVertical;
    summaryText.alignment = NSLayoutAttributeLeading;
    summaryText.spacing = 3;
    summaryText.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton* dismiss = [NSButton buttonWithImage:
        [NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Dismiss"]
                                           target:self action:@selector(dismissSummary:)];
    dismiss.bordered = NO;
    dismiss.contentTintColor = dashboard_faint();
    dismiss.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryCard = [[PracticeCardView alloc] init];
    _summaryCard.layer.backgroundColor = [dashboard_accent() colorWithAlphaComponent:0.12].CGColor;
    _summaryCard.layer.borderColor = [dashboard_accent() colorWithAlphaComponent:0.40].CGColor;
    [_summaryCard addSubview:summaryText];
    [_summaryCard addSubview:dismiss];
    [NSLayoutConstraint activateConstraints:@[
        [summaryText.leadingAnchor constraintEqualToAnchor:_summaryCard.leadingAnchor constant:12],
        [summaryText.topAnchor constraintEqualToAnchor:_summaryCard.topAnchor constant:9],
        [summaryText.bottomAnchor constraintEqualToAnchor:_summaryCard.bottomAnchor constant:-9],
        [summaryText.trailingAnchor constraintLessThanOrEqualToAnchor:dismiss.leadingAnchor constant:-6],
        [dismiss.trailingAnchor constraintEqualToAnchor:_summaryCard.trailingAnchor constant:-10],
        [dismiss.topAnchor constraintEqualToAnchor:_summaryCard.topAnchor constant:9],
        [_summaryDetail.widthAnchor constraintLessThanOrEqualToConstant:330],
    ]];
    _summaryCard.hidden = YES;

    // ---- Phrase chart --------------------------------------------------------
    NSTextField* phraseTitle = make_section_title(strings::get(Str::dashboard_phrases));
    _focusLabel = make_label(@"", 10, NSFontWeightSemibold, dashboard_accent());
    _focusLabel.alignment = NSTextAlignmentRight;
    NSStackView* chartHeader = [NSStackView stackViewWithViews:@[phraseTitle, _focusLabel]];
    chartHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chartHeader.distribution = NSStackViewDistributionEqualSpacing;

    _chart = [[PracticeChartView alloc] init];
    _chart.translatesAutoresizingMaskIntoConstraints = NO;
    _chart.pinned = kNoPhrase;
    [_chart.heightAnchor constraintEqualToConstant:128].active = YES;

    NSStackView* chartLegend = [NSStackView stackViewWithViews:@[
        legend_item([dashboard_accent() colorWithAlphaComponent:0.55], NO, &_legendSession),
        legend_item(nil, YES, &_legendBest)]];
    chartLegend.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chartLegend.spacing = 14;
    _chartHint = make_label(strings::get(Str::dashboard_chart_hint), 9.5,
                            NSFontWeightRegular, dashboard_faint());

    // Click a phrase column to jump there and loop it; click again to release.
    PlaybackController* playbackRef = _playback;
    __weak PracticeDashboardController* weakSelf = self;
    _chart.onSelectPhrase = ^(std::size_t phrase) {
        if (!playbackRef->practice_mode()) {
            return;
        }
        if (playbackRef->snapshot().practice_stats.pinned_phrase == phrase) {
            playbackRef->practice_unpin_phrase();
        } else {
            playbackRef->practice_jump_to_phrase(phrase, true);
        }
        [weakSelf refresh];
    };

    // ---- Assemble ------------------------------------------------------------
    NSStackView* content = [NSStackView stackViewWithViews:@[
        _summaryCard, header, hero, rowOne, rowTwo,
        timingTitle, _timingBar, _timingLegend, _histogram, _offsetVerdict, _timingHint,
        progressHeader, _progressChart, _progressHint,
        chartHeader, _chart, chartLegend, _chartHint]];
    _content = content;
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 8;
    [content setCustomSpacing:14 afterView:header];
    [content setCustomSpacing:8 afterView:hero];
    [content setCustomSpacing:18 afterView:rowTwo];
    [content setCustomSpacing:7 afterView:timingTitle];
    [content setCustomSpacing:12 afterView:_summaryCard];
    [content setCustomSpacing:10 afterView:_timingLegend];
    [content setCustomSpacing:4 afterView:_histogram];
    [content setCustomSpacing:18 afterView:_offsetVerdict];
    [content setCustomSpacing:18 afterView:_timingHint];
    [content setCustomSpacing:4 afterView:progressHeader];
    [content setCustomSpacing:18 afterView:_progressChart];
    [content setCustomSpacing:18 afterView:_progressHint];
    [content setCustomSpacing:4 afterView:chartHeader];
    [content setCustomSpacing:2 afterView:_chart];
    [content setCustomSpacing:4 afterView:chartLegend];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-18],
        [content.topAnchor constraintEqualToAnchor:root.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],
        [root.widthAnchor constraintEqualToConstant:kWidth],

        // Header: text on the left, grade tile hard-right.
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [headingText.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [headingText.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [headingText.trailingAnchor constraintLessThanOrEqualToAnchor:_gradeTile.leadingAnchor
                                                            constant:-10],
        [_gradeTile.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_gradeTile.topAnchor constraintEqualToAnchor:header.topAnchor],
        [_gradeTile.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_gradeTile.widthAnchor constraintEqualToConstant:52],
        [_gradeTile.heightAnchor constraintEqualToConstant:52],
        [gradeStack.centerXAnchor constraintEqualToAnchor:_gradeTile.centerXAnchor],
        [gradeStack.centerYAnchor constraintEqualToAnchor:_gradeTile.centerYAnchor],

        // Hero card: accuracy left, best/mastery right.
        [hero.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [accuracyStack.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:14],
        [accuracyStack.topAnchor constraintEqualToAnchor:hero.topAnchor constant:10],
        [accuracyStack.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-10],
        [accuracyStack.widthAnchor constraintEqualToConstant:112],
        [heroRight.leadingAnchor constraintEqualToAnchor:accuracyStack.trailingAnchor constant:8],
        [heroRight.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-14],
        [heroRight.centerYAnchor constraintEqualToAnchor:hero.centerYAnchor],
        [_masteredTrack.widthAnchor constraintEqualToAnchor:heroRight.widthAnchor],

        [rowOne.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [rowTwo.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_timingBar.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [chartHeader.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_chart.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_summaryCard.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_histogram.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [progressHeader.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_progressChart.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    ]];

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                               target:self
                                             selector:@selector(refresh)
                                             userInfo:nil
                                              repeats:YES];
    [self refresh];
    [self fitWindowToContent];
    return self;
}

// Size the panel to its content (sections show/hide as practice settings
// change), keeping the top edge fixed so the window grows downward.
- (void)fitWindowToContent {
    NSView* root = self.window.contentView;
    [root layoutSubtreeIfNeeded];
    const CGFloat height = std::ceil(root.fittingSize.height);
    NSRect frame = self.window.frame;
    const NSRect content = [self.window contentRectForFrameRect:frame];
    if (std::abs(NSHeight(content) - height) < 0.5) {
        return;
    }
    const CGFloat top = NSMaxY(frame);
    NSRect next = [self.window frameRectForContentRect:
        NSMakeRect(NSMinX(content), NSMinY(content), NSWidth(content), height)];
    next.origin.y = top - NSHeight(next);
    [self.window setFrame:next display:YES];
}

- (void)dismissSummary:(id)sender {
    _summaryCard.hidden = YES;
    [self fitWindowToContent];
}

- (void)dealloc {
    [_timer invalidate];
}

- (NSView*)statCardWithTitle:(NSString*)title
                       value:(NSTextField* __strong*)value
                     caption:(NSTextField* __strong*)caption {
    NSTextField* number = make_number(16, dashboard_ink());
    NSTextField* label = make_label(title, 9, NSFontWeightMedium, dashboard_faint());
    NSStackView* stack = [NSStackView stackViewWithViews:@[number, label]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 1;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    PracticeCardView* card = [[PracticeCardView alloc] init];
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
    ]];
    *value = number;
    *caption = label;
    return card;
}

- (void)setSongKey:(NSString*)songKey {
    NSString* next = songKey ?: @"";
    if ([_songKey isEqualToString:next]) {
        return;
    }
    _songKey = [next copy];
    _historicalBest = 0.0;
    _historicalPhrases.clear();
    _sessionLog.clear();
    _summaryCard.hidden = YES;
    _historySessionRecorded = false;
    _lastSavedNotes = 0;
    _lastSavedWrong = 0;
    _lastSavedPhraseCompletions = 0;
    _lastHistorySaveAt = 0.0;

    if (_songKey.length != 0) {
        try {
            const nlohmann::json history =
                nlohmann::json::parse(settings::get_json("practice_history", "{}"));
            const std::string key = _songKey.UTF8String ?: "";
            if (history.is_object() && history.contains(key) &&
                history[key].is_object()) {
                const nlohmann::json& song = history[key];
                if (song.contains("best_accuracy") && song["best_accuracy"].is_number()) {
                    _historicalBest = std::clamp(song["best_accuracy"].get<double>(), 0.0, 1.0);
                }
                if (song.contains("phrase_best") && song["phrase_best"].is_array()) {
                    for (const auto& value : song["phrase_best"]) {
                        if (value.is_number()) {
                            _historicalPhrases.push_back(
                                std::clamp(value.get<double>(), 0.0, 1.0));
                        }
                    }
                }
                if (song.contains("log") && song["log"].is_array()) {
                    for (const auto& entry : song["log"]) {
                        if (entry.is_object() && entry.contains("acc") &&
                            entry["acc"].is_number()) {
                            _sessionLog.push_back(
                                std::clamp(entry["acc"].get<double>(), 0.0, 1.0));
                        }
                    }
                }
            }
        } catch (...) {
            // A corrupt history should never prevent the dashboard from opening.
        }
    }
    _sessionStartBest = _historicalBest;
    _sessionStartPhrases = _historicalPhrases;
}

- (void)saveHistoryForStats:(const PracticeStatsSnapshot&)stats {
    if (_songKey.length == 0 || stats.notes_completed == 0) {
        return;
    }
    if (_lastSavedNotes == stats.notes_completed &&
        _lastSavedWrong == stats.wrong_keys &&
        _lastSavedPhraseCompletions == stats.phrases_completed) {
        return;
    }
    // The dashboard refreshes frequently so the chart feels live, but writing
    // the entire JSON history for every keystroke can make practice feel laggy.
    // Phrase completion is an intentional checkpoint and is saved immediately;
    // note-level changes are coalesced into at most one disk write per 750 ms.
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (_lastHistorySaveAt > 0.0 &&
        now - _lastHistorySaveAt < 0.75 &&
        _lastSavedPhraseCompletions == stats.phrases_completed) {
        return;
    }

    nlohmann::json history = nlohmann::json::object();
    try {
        history = nlohmann::json::parse(
            settings::get_json("practice_history", "{}"));
        if (!history.is_object()) {
            history = nlohmann::json::object();
        }
    } catch (...) {
        history = nlohmann::json::object();
    }

    const std::string key = _songKey.UTF8String ?: "";
    nlohmann::json& song = history[key];
    if (!song.is_object()) {
        song = nlohmann::json::object();
    }
    const double previousBest = song.value("best_accuracy", 0.0);
    _historicalBest = std::max(_historicalBest,
                               std::max(previousBest, stats.accuracy));
    song["best_accuracy"] = _historicalBest;
    song["last_accuracy"] = stats.accuracy;
    song["last_notes"] = stats.notes_completed;
    song["last_wrong_keys"] = stats.wrong_keys;
    if (!_historySessionRecorded) {
        song["sessions"] = song.value("sessions", 0ULL) + 1ULL;
        _historySessionRecorded = true;
    }

    if (_historicalPhrases.size() < stats.phrases.size()) {
        _historicalPhrases.resize(stats.phrases.size(), 0.0);
    }
    nlohmann::json phraseBest = nlohmann::json::array();
    for (std::size_t i = 0; i < stats.phrases.size(); ++i) {
        _historicalPhrases[i] = std::max(_historicalPhrases[i],
                                         stats.phrases[i].best_accuracy);
        phraseBest.push_back(_historicalPhrases[i]);
    }
    song["phrase_best"] = std::move(phraseBest);
    settings::set_json("practice_history", history.dump());
    _lastHistorySaveAt = now;

    _lastSavedNotes = stats.notes_completed;
    _lastSavedWrong = stats.wrong_keys;
    _lastSavedPhraseCompletions = stats.phrases_completed;
}

// A practice run just ended (stopped or finished): flush history, append the
// session to the progress log, and show the summary banner.
- (void)endSession:(const PracticeStatsSnapshot&)stats {
    _summarizedSession = stats.session;
    _lastHistorySaveAt = 0.0;  // bypass the write throttle for the final state
    [self saveHistoryForStats:stats];

    if (_songKey.length > 0 && stats.notes_completed > 0) {
        try {
            nlohmann::json history = nlohmann::json::parse(
                settings::get_json("practice_history", "{}"));
            if (!history.is_object()) {
                history = nlohmann::json::object();
            }
            nlohmann::json& song = history[_songKey.UTF8String ?: ""];
            if (!song.is_object()) {
                song = nlohmann::json::object();
            }
            nlohmann::json& log = song["log"];
            if (!log.is_array()) {
                log = nlohmann::json::array();
            }
            log.push_back({
                {"acc", stats.accuracy},
                {"notes", stats.notes_completed},
                {"streak", stats.best_streak},
                {"t", static_cast<long long>(NSDate.date.timeIntervalSince1970)},
            });
            constexpr std::size_t kMaxLog = 30;
            while (log.size() > kMaxLog) {
                log.erase(log.begin());
            }
            settings::set_json("practice_history", history.dump());
            _sessionLog.push_back(std::clamp(stats.accuracy, 0.0, 1.0));
            while (_sessionLog.size() > kMaxLog) {
                _sessionLog.erase(_sessionLog.begin());
            }
        } catch (...) {
            // Never let a corrupt history block the summary.
        }
    }

    // Weakest phrase actually played this session.
    std::size_t weakest = stats.phrases.size();
    for (std::size_t i = 0; i < stats.phrases.size(); ++i) {
        const PracticePhraseSnapshot& phrase = stats.phrases[i];
        if (phrase.completed_notes + phrase.wrong_keys == 0) {
            continue;
        }
        if (weakest == stats.phrases.size() ||
            phrase.accuracy < stats.phrases[weakest].accuracy) {
            weakest = i;
        }
    }

    _summaryHeadline.stringValue = [NSString stringWithFormat:@"%@ · %@ %@ · %@",
        strings::get(Str::summary_title), strings::get(Str::dashboard_grade),
        grade_letter(stats), percent(stats.accuracy)];
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    if (_sessionStartBest > 0.0 && stats.accuracy > _sessionStartBest + 0.0005) {
        [parts addObject:[NSString stringWithFormat:@"▲ %@ +%.0f%%",
            strings::get(Str::dashboard_new_best),
            (stats.accuracy - _sessionStartBest) * 100.0]];
    } else if (_sessionStartBest > 0.0) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@",
            strings::get(Str::dashboard_best), percent(_sessionStartBest)]];
    }
    [parts addObject:[NSString stringWithFormat:strings::get(Str::dashboard_best_streak),
        static_cast<unsigned long>(stats.best_streak)]];
    if (weakest < stats.phrases.size() && stats.phrases[weakest].accuracy < 0.999) {
        [parts addObject:[NSString stringWithFormat:strings::get(Str::summary_weakest),
            phrase_name(weakest)]];
    }
    _summaryDetail.stringValue = [parts componentsJoinedByString:@" · "];
    _summaryCard.hidden = NO;

    if (settings::get_bool("practice_show_summary", true)) {
        [self showWindow:nil];
        [self.window orderFrontRegardless];
    }
}

- (void)refresh {
    if (_playback == nullptr) {
        return;
    }
    const PlaybackSnapshot snapshot = _playback->snapshot();
    const PracticeStatsSnapshot& stats = snapshot.practice_stats;

    // A new session began (fresh run): compare against the bests as they stand
    // now, count it as a new session in history, and clear the old summary.
    if (stats.session != _lastSession) {
        if (_lastSession != 0) {
            _sessionStartBest = _historicalBest;
            _sessionStartPhrases = _historicalPhrases;
            _historySessionRecorded = false;
            _summaryCard.hidden = YES;
        }
        _lastSession = stats.session;
    }
    const bool wasRunning = _lastState == PlaybackState::playing ||
        _lastState == PlaybackState::paused || _lastState == PlaybackState::countdown;
    const bool hadInput = stats.notes_completed > 0 || stats.wrong_keys > 0;
    if (wasRunning && snapshot.state == PlaybackState::stopped && hadInput &&
        _summarizedSession != stats.session && _playback->practice_mode()) {
        [self endSession:stats];
    }
    _lastState = snapshot.state;

    [self saveHistoryForStats:stats];
    const bool started = stats.notes_completed > 0 || stats.wrong_keys > 0;

    // Header.
    _songLabel.stringValue = _songKey ?: @"";
    NSString* grade = grade_letter(stats);
    NSColor* gradeColor = grade_color(grade);
    _grade.stringValue = grade;
    _grade.textColor = gradeColor;
    _gradeCaption.stringValue = strings::get(Str::dashboard_grade);
    _gradeTile.layer.backgroundColor = [gradeColor colorWithAlphaComponent:0.12].CGColor;
    _gradeTile.layer.borderColor = [gradeColor colorWithAlphaComponent:0.45].CGColor;

    // Hero: accuracy vs the best stored before this session.
    _accuracy.stringValue = started ? percent(stats.accuracy) : @"—";
    _accuracyCaption.stringValue = strings::get(Str::dashboard_accuracy);
    if (_sessionStartBest <= 0.0) {
        _bestLine.stringValue = strings::get(Str::dashboard_first_session);
        _bestLine.textColor = dashboard_soft();
    } else if (started && stats.accuracy > _sessionStartBest + 0.0005) {
        _bestLine.stringValue = [NSString stringWithFormat:@"▲ %@ · +%.0f%%",
            strings::get(Str::dashboard_new_best),
            (stats.accuracy - _sessionStartBest) * 100.0];
        _bestLine.textColor = [NSColor systemGreenColor];
    } else if (started) {
        const double gap = (_sessionStartBest - stats.accuracy) * 100.0;
        NSString* delta = gap < 0.5 ? @"=" : [NSString stringWithFormat:@"▼ %.0f%%", gap];
        _bestLine.stringValue = [NSString stringWithFormat:
            strings::get(Str::dashboard_vs_best), delta, percent(_sessionStartBest)];
        _bestLine.textColor = dashboard_soft();
    } else {
        _bestLine.stringValue = [NSString stringWithFormat:@"%@ %@",
            strings::get(Str::dashboard_best), percent(_sessionStartBest)];
        _bestLine.textColor = dashboard_soft();
    }

    std::size_t mastered = 0;
    for (const PracticePhraseSnapshot& phrase : stats.phrases) {
        mastered += phrase.mastered ? 1 : 0;
    }
    _masteredLine.stringValue = [NSString stringWithFormat:
        strings::get(Str::dashboard_phrases_mastered),
        static_cast<unsigned long>(mastered),
        static_cast<unsigned long>(stats.phrases.size())];
    _masteredTrack.fraction = stats.phrases.empty() ? 0.0
        : static_cast<double>(mastered) / stats.phrases.size();

    // Stat cards.
    _notes.stringValue = [NSString stringWithFormat:@"%lu/%lu",
        static_cast<unsigned long>(stats.notes_completed),
        static_cast<unsigned long>(_playback->note_count())];
    _wrong.stringValue = count_value(stats.wrong_keys);
    _wrong.textColor = stats.wrong_keys > 0 ? timing_missed_color() : dashboard_ink();
    _response.stringValue = stats.notes_completed > 0
        ? [NSString stringWithFormat:@"%ld ms",
              static_cast<long>(stats.average_response.count())]
        : @"—";
    _streak.stringValue = count_value(stats.streak);
    _streak.textColor = stats.streak >= 10 ? dashboard_accent() : dashboard_ink();
    _streakCaption.stringValue = [NSString stringWithFormat:strings::get(Str::dashboard_best_streak),
        static_cast<unsigned long>(stats.best_streak)];
    _partials.stringValue = count_value(stats.partial_chords);
    const std::size_t current = snapshot.practice_phrase_index;
    const std::size_t clean = current < stats.phrases.size()
        ? stats.phrases[current].clean_repetitions : 0;
    const bool currentMastered = current < stats.phrases.size() &&
        stats.phrases[current].mastered;
    _cleanRuns.stringValue = currentMastered ? @"✓" : [NSString stringWithFormat:@"%lu/%lu",
        static_cast<unsigned long>(std::min(clean, kCleanRunsToMaster)),
        static_cast<unsigned long>(kCleanRunsToMaster)];
    _cleanRuns.textColor = currentMastered ? dashboard_accent() : dashboard_ink();
    _cleanRunsCaption.stringValue = [NSString stringWithFormat:@"%@ · %@",
        strings::get(Str::dashboard_clean_runs), phrase_name(current)];

    // Timing breakdown. Early/late only exist in song-speed practice; without
    // it every note would read "on time", so show a hint instead of a lie.
    const std::size_t late = stats.late_inputs;
    const std::size_t onTime = stats.notes_completed > late ? stats.notes_completed - late : 0;
    const bool timed = _playback->practice_tempo();
    _timingBar.hidden = !timed;
    _timingLegend.hidden = !timed;
    _timingHint.hidden = timed;
    const bool hasOffsets = timed && stats.offset_samples > 0;
    _histogram.hidden = !hasOffsets;
    _offsetVerdict.hidden = !hasOffsets;
    if (hasOffsets) {
        [_histogram setBins:stats.offset_bins minMs:stats.offset_min_ms
                      maxMs:stats.offset_max_ms];
        const long avg = static_cast<long>(stats.average_offset.count());
        constexpr long kSteadyMs = 20;
        if (avg < -kSteadyMs) {
            _offsetVerdict.stringValue = [NSString stringWithFormat:
                strings::get(Str::dashboard_rushing), -avg];
            _offsetVerdict.textColor = timing_early_color();
        } else if (avg > kSteadyMs) {
            _offsetVerdict.stringValue = [NSString stringWithFormat:
                strings::get(Str::dashboard_dragging), avg];
            _offsetVerdict.textColor = timing_late_color();
        } else {
            _offsetVerdict.stringValue = [NSString stringWithFormat:
                strings::get(Str::dashboard_steady), std::abs(avg)];
            _offsetVerdict.textColor = dashboard_accent();
        }
    }

    // Progress across sessions.
    const bool hasProgress = !_sessionLog.empty();
    _progressChart.hidden = !hasProgress;
    _progressHint.hidden = hasProgress;
    [_progressChart setValues:_sessionLog];
    _progressCaption.stringValue = hasProgress
        ? [NSString stringWithFormat:strings::get(Str::dashboard_sessions_count),
              static_cast<unsigned long>(_sessionLog.size())]
        : @"";
    [_timingBar setOnTime:onTime early:stats.early_inputs late:late
                   missed:stats.missed_notes];
    _onTimeText.stringValue = [NSString stringWithFormat:@"%@ %lu",
        strings::get(Str::dashboard_on_time), static_cast<unsigned long>(onTime)];
    _earlyText.stringValue = [NSString stringWithFormat:@"%@ %lu",
        strings::get(Str::learn_early), static_cast<unsigned long>(stats.early_inputs)];
    _lateText.stringValue = [NSString stringWithFormat:@"%@ %lu",
        strings::get(Str::learn_late), static_cast<unsigned long>(late)];
    _missedText.stringValue = [NSString stringWithFormat:@"%@ %lu",
        strings::get(Str::learn_missed), static_cast<unsigned long>(stats.missed_notes)];

    // Focus = weakest unmastered phrase, judged on its best-ever result.
    std::size_t focus = stats.phrases.size();
    double focusAccuracy = 2.0;
    for (std::size_t i = 0; i < stats.phrases.size(); ++i) {
        const PracticePhraseSnapshot& phrase = stats.phrases[i];
        if (phrase.mastered) {
            continue;
        }
        const double historical = i < _historicalPhrases.size()
            ? _historicalPhrases[i] : 0.0;
        const double value = std::max(phrase.accuracy, historical);
        if (value <= 0.0) {
            continue;  // never played: nothing to judge yet
        }
        if (focus == stats.phrases.size() || value < focusAccuracy) {
            focus = i;
            focusAccuracy = value;
        }
    }
    if (stats.pinned_phrase < stats.phrases.size()) {
        _focusLabel.stringValue = [NSString stringWithFormat:
            strings::get(Str::dashboard_looping), phrase_name(stats.pinned_phrase)];
    } else {
        _focusLabel.stringValue = focus < stats.phrases.size()
            ? [NSString stringWithFormat:@"%@ · %@", strings::get(Str::dashboard_focus),
                  phrase_name(focus)]
            : @"";
    }
    _chart.pinned = stats.pinned_phrase;
    _chartHint.stringValue = strings::get(Str::dashboard_chart_hint);

    // Live bars = this session; ghost = best from before this session.
    std::vector<PracticePhraseSnapshot> chartStats = stats.phrases;
    if (_sessionStartPhrases.size() > chartStats.size()) {
        chartStats.resize(_sessionStartPhrases.size());
    }
    [_chart setPhraseStats:chartStats ghost:_sessionStartPhrases
                   current:current focus:focus];
    _legendSession.stringValue = strings::get(Str::dashboard_legend_session);
    _legendBest.stringValue = strings::get(Str::dashboard_legend_best);
    self.window.title = strings::get(Str::dashboard_title);
    [self fitWindowToContent];
}

@end
