#import "practice_dashboard.h"

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

static NSString* percent(double value) {
    return [NSString stringWithFormat:@"%.0f%%", value * 100.0];
}

static NSString* count_value(std::size_t value) {
    return [NSString stringWithFormat:@"%lu", static_cast<unsigned long>(value)];
}

@interface PracticeChartView : NSView
- (void)setPhraseStats:(const std::vector<PracticePhraseSnapshot>&)stats;
@end

@implementation PracticeChartView {
    std::vector<PracticePhraseSnapshot> _stats;
}

- (BOOL)isFlipped { return YES; }

- (void)setPhraseStats:(const std::vector<PracticePhraseSnapshot>&)stats {
    _stats = stats;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    const NSRect bounds = self.bounds;
    const CGFloat left = 14.0;
    const CGFloat right = 8.0;
    const CGFloat top = 10.0;
    const CGFloat bottom = 22.0;
    const CGFloat chartHeight = std::max(1.0, NSHeight(bounds) - top - bottom);
    const CGFloat chartWidth = std::max(1.0, NSWidth(bounds) - left - right);

    [[dashboard_faint() colorWithAlphaComponent:0.30] setStroke];
    NSBezierPath* baseline = [NSBezierPath bezierPath];
    [baseline moveToPoint:NSMakePoint(left, top + chartHeight)];
    [baseline lineToPoint:NSMakePoint(left + chartWidth, top + chartHeight)];
    baseline.lineWidth = 1.0;
    [baseline stroke];

    bool hasData = false;
    for (const PracticePhraseSnapshot& stats : _stats) {
        if (stats.completed_notes > 0 || stats.wrong_keys > 0) {
            hasData = true;
            break;
        }
    }
    if (_stats.empty() || !hasData) {
        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: dashboard_faint()
        };
        NSString* empty = strings::get(Str::dashboard_no_data);
        const NSSize size = [empty sizeWithAttributes:attrs];
        [empty drawAtPoint:NSMakePoint((NSWidth(bounds) - size.width) * 0.5,
                                       (NSHeight(bounds) - size.height) * 0.5)
            withAttributes:attrs];
        return;
    }

    const CGFloat slot = chartWidth / static_cast<CGFloat>(_stats.size());
    const CGFloat barWidth = std::max(4.0, slot - 6.0);
    for (std::size_t i = 0; i < _stats.size(); ++i) {
        const PracticePhraseSnapshot& stats = _stats[i];
        const CGFloat x = left + slot * static_cast<CGFloat>(i) +
            (slot - barWidth) * 0.5;
        const CGFloat valueHeight = chartHeight * std::clamp(stats.accuracy, 0.0, 1.0);
        const CGFloat minHeight = stats.completed_notes > 0 ? 3.0 : 0.0;
        const NSRect bar = NSMakeRect(x, top + chartHeight -
                                      std::max(minHeight, valueHeight),
                                      barWidth, std::max(minHeight, valueHeight));
        NSColor* color = stats.mastered
            ? dashboard_accent()
            : [dashboard_accent() colorWithAlphaComponent:
                stats.completed_notes > 0 ? 0.62 : 0.16];
        [color setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:3.0 yRadius:3.0] fill];

        NSString* label = [NSString stringWithFormat:@"%lu",
            static_cast<unsigned long>(i + 1)];
        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9
                                                             weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: dashboard_faint()
        };
        const NSSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(x + (barWidth - size.width) * 0.5,
                                       top + chartHeight + 6.0)
            withAttributes:attrs];
    }
}

@end

@interface PracticeDashboardController ()
- (NSStackView*)metricWithTitle:(NSString*)title value:(NSTextField**)value;
@end

@implementation PracticeDashboardController {
    PlaybackController* _playback;
    NSTextField* _accuracy;
    NSTextField* _notes;
    NSTextField* _wrong;
    NSTextField* _partials;
    NSTextField* _chords;
    NSTextField* _response;
    NSTextField* _summary;
    NSTextField* _phraseTitle;
    PracticeChartView* _chart;
    NSTimer* _timer;
    NSString* _songKey;
    double _historicalBest;
    std::vector<double> _historicalPhrases;
    bool _historySessionRecorded;
    std::size_t _lastSavedNotes;
    std::size_t _lastSavedWrong;
    std::size_t _lastSavedPhraseCompletions;
}

- (instancetype)initWithPlayback:(PlaybackController*)playback {
    NSPanel* window = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 390, 350)
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
    _historySessionRecorded = false;
    _lastSavedNotes = 0;
    _lastSavedWrong = 0;
    _lastSavedPhraseCompletions = 0;
    window.title = strings::get(Str::dashboard_title);
    window.level = NSFloatingWindowLevel;
    window.hidesOnDeactivate = NO;
    window.becomesKeyOnlyIfNeeded = YES;
    window.backgroundColor = themes::current().panel_tint;

    NSView* root = [[NSView alloc] init];
    root.wantsLayer = YES;
    root.layer.backgroundColor = themes::current().panel_tint.CGColor;
    window.contentView = root;

    NSTextField* title = [NSTextField labelWithString:strings::get(Str::dashboard_title)];
    title.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    title.textColor = dashboard_ink();

    _summary = [NSTextField labelWithString:@""];
    _summary.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];
    _summary.textColor = dashboard_soft();

    NSStackView* heading = [NSStackView stackViewWithViews:@[title, _summary]];
    heading.orientation = NSUserInterfaceLayoutOrientationVertical;
    heading.alignment = NSLayoutAttributeLeading;
    heading.spacing = 4;

    NSTextField* accuracy = nil;
    NSTextField* notes = nil;
    NSTextField* wrong = nil;
    NSStackView* rowOne = [NSStackView stackViewWithViews:@[
        [self metricWithTitle:strings::get(Str::dashboard_accuracy) value:&accuracy],
        [self metricWithTitle:strings::get(Str::dashboard_notes) value:&notes],
        [self metricWithTitle:strings::get(Str::dashboard_wrong) value:&wrong]]];
    _accuracy = accuracy;
    _notes = notes;
    _wrong = wrong;
    rowOne.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowOne.distribution = NSStackViewDistributionFillEqually;
    rowOne.spacing = 10;

    NSTextField* partials = nil;
    NSTextField* chords = nil;
    NSTextField* response = nil;
    NSStackView* rowTwo = [NSStackView stackViewWithViews:@[
        [self metricWithTitle:strings::get(Str::dashboard_partials) value:&partials],
        [self metricWithTitle:strings::get(Str::dashboard_chords) value:&chords],
        [self metricWithTitle:strings::get(Str::dashboard_response) value:&response]]];
    _partials = partials;
    _chords = chords;
    _response = response;
    rowTwo.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowTwo.distribution = NSStackViewDistributionFillEqually;
    rowTwo.spacing = 10;

    _phraseTitle = [NSTextField labelWithString:strings::get(Str::dashboard_phrases)];
    _phraseTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _phraseTitle.textColor = dashboard_ink();

    _chart = [[PracticeChartView alloc] init];
    _chart.translatesAutoresizingMaskIntoConstraints = NO;
    [_chart.heightAnchor constraintEqualToConstant:132].active = YES;

    NSStackView* content = [NSStackView stackViewWithViews:@[
        heading, rowOne, rowTwo, _phraseTitle, _chart]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-18],
        [content.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-18],
        [heading.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [rowOne.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [rowTwo.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_phraseTitle.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_chart.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    ]];

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                               target:self
                                             selector:@selector(refresh)
                                             userInfo:nil
                                              repeats:YES];
    [self refresh];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (NSStackView*)metricWithTitle:(NSString*)title value:(NSTextField**)value {
    NSTextField* number = [NSTextField labelWithString:@"—"];
    number.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
    number.textColor = dashboard_accent();
    number.alignment = NSTextAlignmentCenter;
    number.lineBreakMode = NSLineBreakByTruncatingTail;

    NSTextField* label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:9 weight:NSFontWeightMedium];
    label.textColor = dashboard_faint();
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingTail;

    NSStackView* card = [NSStackView stackViewWithViews:@[number, label]];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeCenterX;
    card.spacing = 3;
    *value = number;
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
    _historySessionRecorded = false;
    _lastSavedNotes = 0;
    _lastSavedWrong = 0;
    _lastSavedPhraseCompletions = 0;

    if (_songKey.length == 0) {
        return;
    }
    try {
        const nlohmann::json history =
            nlohmann::json::parse(settings::get_json("practice_history", "{}"));
        const std::string key = _songKey.UTF8String ?: "";
        if (!history.is_object() || !history.contains(key) ||
            !history[key].is_object()) {
            return;
        }
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
    } catch (...) {
        // A corrupt history should never prevent the dashboard from opening.
    }
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

    _lastSavedNotes = stats.notes_completed;
    _lastSavedWrong = stats.wrong_keys;
    _lastSavedPhraseCompletions = stats.phrases_completed;
}

- (void)refresh {
    if (_playback == nullptr) {
        return;
    }
    const PlaybackSnapshot snapshot = _playback->snapshot();
    const PracticeStatsSnapshot& stats = snapshot.practice_stats;
    [self saveHistoryForStats:stats];
    _accuracy.stringValue = percent(stats.accuracy);
    _notes.stringValue = [NSString stringWithFormat:@"%lu/%lu",
        static_cast<unsigned long>(stats.notes_completed),
        static_cast<unsigned long>(_playback->note_count())];
    _wrong.stringValue = count_value(stats.wrong_keys);
    _partials.stringValue = count_value(stats.partial_chords);
    _chords.stringValue = count_value(stats.chords_completed);
    _response.stringValue = [NSString stringWithFormat:@"%ld ms",
        static_cast<long>(stats.average_response.count())];

    std::size_t mastered = 0;
    std::size_t focus = stats.phrases.size();
    double focusAccuracy = 2.0;
    for (const PracticePhraseSnapshot& phrase : stats.phrases) {
        if (phrase.mastered) {
            ++mastered;
        }
    }
    for (std::size_t i = 0; i < stats.phrases.size(); ++i) {
        const PracticePhraseSnapshot& phrase = stats.phrases[i];
        if (phrase.mastered) {
            continue;
        }
        const double historical = i < _historicalPhrases.size()
            ? _historicalPhrases[i] : 0.0;
        const double value = std::max(phrase.accuracy, historical);
        if (focus == stats.phrases.size() || value < focusAccuracy) {
            focus = i;
            focusAccuracy = value;
        }
    }
    const double bestAccuracy = std::max(_historicalBest, stats.accuracy);
    _summary.stringValue = [NSString stringWithFormat:@"%@ · %lu/%lu %@ · %@ %@",
        [NSString stringWithFormat:strings::get(Str::dashboard_phrase),
            static_cast<unsigned long>(snapshot.practice_phrase_index + 1)],
        static_cast<unsigned long>(mastered),
        static_cast<unsigned long>(stats.phrases.size()),
        strings::get(Str::dashboard_mastered),
        strings::get(Str::dashboard_best),
        percent(bestAccuracy)];
    if (focus < stats.phrases.size()) {
        _phraseTitle.stringValue = [NSString stringWithFormat:@"%@ · %@ %@",
            strings::get(Str::dashboard_phrases),
            strings::get(Str::dashboard_focus),
            [NSString stringWithFormat:strings::get(Str::dashboard_phrase),
                static_cast<unsigned long>(focus + 1)]];
    } else {
        _phraseTitle.stringValue = strings::get(Str::dashboard_phrases);
    }
    std::vector<PracticePhraseSnapshot> chartStats = stats.phrases;
    if (_historicalPhrases.size() > chartStats.size()) {
        chartStats.resize(_historicalPhrases.size());
    }
    for (std::size_t i = 0; i < _historicalPhrases.size(); ++i) {
        chartStats[i].accuracy = std::max(chartStats[i].accuracy,
                                          _historicalPhrases[i]);
        chartStats[i].completed_notes = std::max<std::size_t>(
            chartStats[i].completed_notes,
            chartStats[i].accuracy > 0.0 ? 1 : 0);
    }
    [_chart setPhraseStats:chartStats];
    self.window.title = strings::get(Str::dashboard_title);
}

@end
