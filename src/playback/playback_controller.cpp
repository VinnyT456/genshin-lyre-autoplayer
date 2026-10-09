#include "playback_controller.h"

#include <algorithm>
#include <cmath>
#include <array>
#include <sstream>
#include <utility>

namespace {

// A phrase counts as mastered after this many consecutive clean repetitions.
// Shared by the mastery flag and the loop-until-mastered auto-advance gate.
constexpr std::size_t kMasteryCleanReps = 3;

// Breathing room before the first note when a phrase repeats or is jumped to
// during song-speed practice.
constexpr std::chrono::milliseconds kPhraseLeadIn{800};

const char* key_name(Key key) {
    static constexpr std::array<const char*, 21> names = {
        "Q", "W", "E", "R", "T", "Y", "U",
        "A", "S", "D", "F", "G", "H", "J",
        "Z", "X", "C", "V", "B", "N", "M"
    };
    return names.at(static_cast<std::size_t>(key));
}

}  // namespace

void PlaybackController::rebuild_practice_phrases_locked() {
    practice_phrases_.clear();
    if (notes_.empty()) {
        return;
    }

    std::vector<long long> gaps;
    gaps.reserve(notes_.size() > 1 ? notes_.size() - 1 : 0);
    for (std::size_t i = 1; i < notes_.size(); ++i) {
        const long long gap = (notes_[i].timestamp - notes_[i - 1].timestamp).count();
        if (gap > 0) {
            gaps.push_back(gap);
        }
    }

    long long typical_gap = 0;
    if (!gaps.empty()) {
        std::sort(gaps.begin(), gaps.end());
        typical_gap = gaps[(gaps.size() - 1) / 2];
    }
    // A phrase boundary is a noticeably longer rest than the song's normal
    // note spacing. Keep a floor so fast passages do not split constantly.
    const long long phrase_gap = std::max(750LL, typical_gap * 4);

    std::size_t start = 0;
    for (std::size_t i = 1; i < notes_.size(); ++i) {
        const long long gap = (notes_[i].timestamp - notes_[i - 1].timestamp).count();
        if (gap >= phrase_gap) {
            practice_phrases_.push_back({start, i});
            start = i;
        }
    }
    practice_phrases_.push_back({start, notes_.size()});
}

void PlaybackController::reset_practice_locked() {
    practice_phrase_index_ = 0;
    practice_index_ = practice_phrases_.empty() ? 0 : practice_phrases_[0].first;
    practice_pressed_.clear();
    practice_clean_repetitions_ = 0;
    practice_rep_completed_ = 0;
    practice_rep_wrong_ = 0;
    practice_rep_partial_ = 0;
    practice_feedback_ = PracticeInputResult::ignored;
    start_practice_target_locked();
}

void PlaybackController::reset_practice_stats_locked() {
    practice_stats_.clear();
    practice_stats_.reserve(practice_phrases_.size());
    for (const auto [start, end] : practice_phrases_) {
        PracticePhraseSnapshot stats;
        stats.note_count = end - start;
        practice_stats_.push_back(stats);
    }
    practice_notes_completed_ = 0;
    practice_wrong_keys_ = 0;
    practice_partial_chords_ = 0;
    practice_chords_completed_ = 0;
    practice_phrases_completed_ = 0;
    practice_early_inputs_ = 0;
    practice_late_inputs_ = 0;
    practice_missed_notes_ = 0;
    practice_response_total_ = std::chrono::milliseconds(0);
    practice_last_response_ = std::chrono::milliseconds(0);
    practice_streak_ = 0;
    practice_best_streak_ = 0;
    practice_offsets_.clear();
    practice_pending_offset_.reset();
    ++practice_session_;
}

void PlaybackController::rewind_timeline_locked(std::size_t index,
                                                std::chrono::milliseconds lead_in) {
    if (!practice_tempo_ || index >= notes_.size()) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    origin_ = now + lead_in - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double, std::milli>(notes_[index].timestamp.count() / speed_));
    metronome_last_beat_.reset();
}

void PlaybackController::start_practice_target_locked() {
    practice_target_started_at_ = std::chrono::steady_clock::now();
    practice_chord_started_at_ = practice_target_started_at_;
    practice_beat_emitted_ = false;
    practice_late_current_ = false;
}

PracticeInputResult PlaybackController::advance_practice_note_locked(
    bool completed, PracticeInputResult feedback,
    std::chrono::steady_clock::time_point now) {
    const std::vector<Key>& expected = notes_[practice_index_].keys;
    if (completed) {
        const auto response = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - practice_target_started_at_);
        practice_last_response_ = std::max(std::chrono::milliseconds(0), response);
        practice_response_total_ += practice_last_response_;
        ++practice_notes_completed_;
        ++practice_rep_completed_;
        if (expected.size() > 1) {
            ++practice_chords_completed_;
        }
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].completed_notes;
        }
        if (feedback == PracticeInputResult::late) {
            ++practice_late_inputs_;
        }
        ++practice_streak_;
        practice_best_streak_ = std::max(practice_best_streak_, practice_streak_);
        if (practice_pending_offset_.has_value()) {
            practice_offsets_.push_back(*practice_pending_offset_);
        }
    } else {
        practice_streak_ = 0;
        ++practice_missed_notes_;
        ++practice_wrong_keys_;
        ++practice_rep_wrong_;
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].wrong_keys;
        }
        // A chord that was started but never finished is a partial chord.
        // Counted here, not per key, so a chord played together is never
        // penalized just because its keys arrive a few milliseconds apart.
        if (expected.size() > 1 && !practice_pressed_.empty()) {
            ++practice_partial_chords_;
            ++practice_rep_partial_;
            if (practice_phrase_index_ < practice_stats_.size()) {
                ++practice_stats_[practice_phrase_index_].partial_chords;
            }
        }
    }

    practice_pressed_.clear();
    practice_pending_offset_.reset();
    ++practice_index_;
    const std::size_t phrase_end = practice_phrases_[practice_phrase_index_].second;
    if (practice_index_ < phrase_end) {
        start_practice_target_locked();
        practice_feedback_ = feedback;
        return feedback;
    }

    if (practice_phrase_index_ < practice_stats_.size()) {
        PracticePhraseSnapshot& stats = practice_stats_[practice_phrase_index_];
        ++stats.repetitions;
        const std::size_t denominator = stats.completed_notes + stats.wrong_keys;
        stats.accuracy = denominator > 0
            ? static_cast<double>(stats.completed_notes) / denominator
            : 0.0;
        stats.best_accuracy = std::max(stats.best_accuracy, stats.accuracy);
        const bool clean_phrase = practice_rep_wrong_ == 0;
        if (clean_phrase) {
            ++practice_clean_repetitions_;
        } else {
            practice_clean_repetitions_ = 0;
        }
        stats.clean_repetitions = practice_clean_repetitions_;
        stats.mastered = practice_clean_repetitions_ >= kMasteryCleanReps;

        if (practice_auto_speed_ && practice_tempo_ && clean_phrase && speed_ < 1.0) {
            // Gently increase the tempo after a clean phrase while preserving
            // the current song-time position.
            const auto position = practice_tempo_elapsed_locked();
            speed_ = std::min(1.0, speed_ + 0.05);
            const auto speed_now = std::chrono::steady_clock::now();
            origin_ = speed_now -
                std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                    std::chrono::duration<double, std::milli>(
                        position.count() / speed_));
        }
    }
    ++practice_phrases_completed_;
    practice_rep_completed_ = 0;
    practice_rep_wrong_ = 0;
    practice_rep_partial_ = 0;

    // Loop-until-mastered: hold on the current phrase until it is mastered.
    // Repeat it in place (keeping the clean-repetition streak intact) instead
    // of advancing. Only kicks in when there is a next phrase to gate.
    // A pinned phrase (jump-to-phrase / drill) repeats unconditionally.
    const bool pinned_here = practice_pinned_phrase_ == practice_phrase_index_;
    if (pinned_here ||
        (practice_lock_until_mastered_ &&
         practice_clean_repetitions_ < kMasteryCleanReps &&
         practice_phrase_index_ + 1 < practice_phrases_.size())) {
        practice_index_ = practice_phrases_[practice_phrase_index_].first;
        rewind_timeline_locked(practice_index_, kPhraseLeadIn);
        start_practice_target_locked();
        practice_feedback_ = PracticeInputResult::phrase_completed;
        return PracticeInputResult::phrase_completed;
    }

    if (practice_phrase_index_ + 1 < practice_phrases_.size()) {
        ++practice_phrase_index_;
        practice_index_ = practice_phrases_[practice_phrase_index_].first;
        practice_clean_repetitions_ = 0;
        start_practice_target_locked();
        practice_feedback_ = PracticeInputResult::phrase_completed;
        return PracticeInputResult::phrase_completed;
    }
    // The loop control is a song-level transport option. In Learn mode it
    // should not turn into an implicit phrase loop: finish the final phrase,
    // then restart at the first note of the loaded song.
    if (loop_ && !practice_phrases_.empty()) {
        practice_phrase_index_ = 0;
        practice_index_ = practice_phrases_[0].first;
        practice_clean_repetitions_ = 0;
        start_practice_target_locked();
        practice_feedback_ = PracticeInputResult::phrase_completed;
        return PracticeInputResult::phrase_completed;
    }
    if (practice_index_ >= notes_.size()) {
        state_ = PlaybackState::stopped;
        completed_ = true;
        practice_feedback_ = completed
            ? PracticeInputResult::completed : PracticeInputResult::missed;
        return practice_feedback_;
    }
    practice_feedback_ = feedback;
    return feedback;
}

PlaybackController::PlaybackController(std::vector<Note> notes, Keyboard& keyboard)
    : notes_(std::move(notes)), keyboard_(keyboard) {
    rebuild_practice_phrases_locked();
    reset_practice_stats_locked();
    reset_practice_locked();
}

PlaybackController::~PlaybackController() {
    stop();
}

void PlaybackController::play() {
    std::unique_lock lock(mutex_);
    if (state_ == PlaybackState::playing || state_ == PlaybackState::countdown ||
        notes_.empty()) {
        return;
    }

    if (practice_mode_) {
        if (state_ == PlaybackState::paused) {
            const auto now = std::chrono::steady_clock::now();
            if (paused_from_countdown_) {
                const auto remaining = std::max(
                    std::chrono::milliseconds(0),
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        countdown_end_ - paused_at_));
                paused_from_countdown_ = false;
                if (remaining > std::chrono::milliseconds(0)) {
                    countdown_end_ = now + remaining;
                    state_ = PlaybackState::countdown;
                    const auto timestamp = notes_[practice_index_].timestamp;
                    origin_ = countdown_end_ -
                        std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                            std::chrono::duration<double, std::milli>(
                                timestamp.count() / speed_));
                    return;
                }
            }
            practice_target_started_at_ += now - paused_at_;
            if (practice_tempo_) {
                origin_ += now - paused_at_;
            }
            state_ = PlaybackState::playing;
            return;
        }
        // A fresh run after a stop/finish is a new session: the dashboard
        // summarizes and logs the previous one, then starts clean.
        if (practice_notes_completed_ > 0 || practice_wrong_keys_ > 0) {
            reset_practice_stats_locked();
            reset_practice_locked();
        }
        if (practice_index_ >= notes_.size()) {
            reset_practice_locked();
        }
        // A pinned phrase (jump-to-phrase / drill) is where the run starts.
        if (practice_pinned_phrase_ < practice_phrases_.size()) {
            practice_phrase_index_ = practice_pinned_phrase_;
            practice_index_ = practice_phrases_[practice_pinned_phrase_].first;
        }
        metronome_last_beat_.reset();
        // Speed ramp: begin slow and let clean phrases climb back to 1x.
        if (practice_tempo_ && practice_auto_speed_ && practice_ramp_start_ > 0.0) {
            speed_ = std::clamp(practice_ramp_start_, 0.25, 1.0);
        }
        practice_pressed_.clear();
        stop_requested_ = false;
        completed_ = false;
        const auto now = std::chrono::steady_clock::now();
        if (practice_tempo_) {
            const auto timestamp = notes_[practice_index_].timestamp;
            origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double, std::milli>(
                    timestamp.count() / speed_));
            if (countdown_ > std::chrono::milliseconds(0)) {
                state_ = PlaybackState::countdown;
                countdown_end_ = now + countdown_;
                origin_ = countdown_end_ -
                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                        std::chrono::duration<double, std::milli>(
                            timestamp.count() / speed_));
                return;
            }
        }
        state_ = PlaybackState::playing;
        start_practice_target_locked();
        return;
    }

    if (state_ == PlaybackState::paused) {
        const auto now = std::chrono::steady_clock::now();
        if (paused_from_countdown_) {
            const auto remaining = std::max(
                std::chrono::milliseconds(0),
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    countdown_end_ - paused_at_));
            paused_from_countdown_ = false;
            if (remaining > std::chrono::milliseconds(0)) {
                countdown_end_ = now + remaining;
                origin_ = countdown_end_;
                state_ = PlaybackState::countdown;
                condition_.notify_all();
                return;
            }
            origin_ = now;
        } else {
            origin_ += now - paused_at_;
        }
        state_ = PlaybackState::playing;
        condition_.notify_all();
        return;
    }

    if (worker_.joinable()) {
        lock.unlock();
        worker_.join();
        lock.lock();
    }

    stop_requested_ = false;
    completed_ = false;
    seek_requested_ = false;
    paused_elapsed_ = std::chrono::milliseconds(0);

    const auto now = std::chrono::steady_clock::now();
    if (countdown_ > std::chrono::milliseconds(0)) {
        state_ = PlaybackState::countdown;
        countdown_end_ = now + countdown_;
        // origin_ is set so that song-time 0 begins when the count-in ends.
        origin_ = now + countdown_;
    } else {
        state_ = PlaybackState::playing;
        origin_ = now;
    }
    worker_ = std::thread(&PlaybackController::run, this);
}

void PlaybackController::pause() {
    std::lock_guard lock(mutex_);
    if (state_ != PlaybackState::playing && state_ != PlaybackState::countdown) {
        return;
    }
    paused_at_ = std::chrono::steady_clock::now();
    paused_from_countdown_ = state_ == PlaybackState::countdown;
    paused_elapsed_ = elapsed_locked();
    state_ = PlaybackState::paused;
    condition_.notify_all();
}

void PlaybackController::stop() {
    {
        std::lock_guard lock(mutex_);
        stop_requested_ = true;
        state_ = PlaybackState::stopped;
        completed_ = false;
        paused_from_countdown_ = false;
        paused_elapsed_ = std::chrono::milliseconds(0);
        if (practice_mode_) {
            reset_practice_locked();
        }
    }
    condition_.notify_all();
    if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
        worker_.join();
    }
}

void PlaybackController::seek(std::chrono::milliseconds position) {
    std::lock_guard lock(mutex_);
    if (notes_.empty()) {
        return;
    }
    position = std::clamp(position, std::chrono::milliseconds(0), duration_locked());

    if (practice_mode_) {
        const double fraction = duration_locked().count() > 0
            ? static_cast<double>(position.count()) / duration_locked().count()
            : 0.0;
        practice_index_ = std::min(
            notes_.size(),
            static_cast<std::size_t>(fraction * notes_.size()));
        practice_phrase_index_ = 0;
        for (std::size_t i = 0; i < practice_phrases_.size(); ++i) {
            const auto [start, end] = practice_phrases_[i];
            if (practice_index_ < end || i + 1 == practice_phrases_.size()) {
                practice_phrase_index_ = i;
                if (practice_index_ < start) {
                    practice_index_ = start;
                }
                break;
            }
        }
        practice_pressed_.clear();
        completed_ = practice_index_ >= notes_.size();
        if (practice_tempo_) {
            const auto now = std::chrono::steady_clock::now();
            origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double, std::milli>(position.count() / speed_));
        }
        start_practice_target_locked();
        seek_requested_ = false;
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    const auto anchor = state_ == PlaybackState::countdown
        ? countdown_end_ : now;
    origin_ = anchor - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double, std::milli>(position.count() / speed_));

    if (state_ == PlaybackState::paused) {
        paused_at_ = now;
        paused_elapsed_ = position;
    }
    completed_ = false;
    seek_requested_ = true;
    condition_.notify_all();
}

void PlaybackController::seek_fraction(double fraction) {
    fraction = std::clamp(fraction, 0.0, 1.0);
    std::chrono::milliseconds target;
    {
        std::lock_guard lock(mutex_);
        target = std::chrono::milliseconds(
            static_cast<long long>(duration_locked().count() * fraction));
    }
    seek(target);
}

void PlaybackController::set_loop(bool loop) {
    std::lock_guard lock(mutex_);
    loop_ = loop;
}

void PlaybackController::toggle_loop() {
    std::lock_guard lock(mutex_);
    loop_ = !loop_;
}

void PlaybackController::set_speed(double speed) {
    std::lock_guard lock(mutex_);
    const double next = std::clamp(speed, 0.25, 3.0);
    if (next == speed_) {
        return;
    }
    // Preserve the current song position across the rate change.
    const auto pos = elapsed_locked();
    speed_ = next;
    const auto now = std::chrono::steady_clock::now();
    if (state_ != PlaybackState::countdown && !paused_from_countdown_) {
        origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
            std::chrono::duration<double, std::milli>(pos.count() / speed_));
    }
    if (state_ == PlaybackState::paused) {
        paused_at_ = now;
        paused_elapsed_ = pos;
    }
    seek_requested_ = true;  // make the worker recompute its deadline
    condition_.notify_all();
}

void PlaybackController::nudge_speed(double delta) {
    double current;
    {
        std::lock_guard lock(mutex_);
        current = speed_;
    }
    set_speed(current + delta);
}

void PlaybackController::set_on_finished(std::function<void()> callback) {
    std::lock_guard lock(mutex_);
    on_finished_ = std::move(callback);
}

void PlaybackController::set_notes(std::vector<Note> notes) {
    stop();
    std::lock_guard lock(mutex_);
    notes_ = std::move(notes);
    ++notes_revision_;
    practice_pinned_phrase_ = kNoPhrase;
    rebuild_practice_phrases_locked();
    reset_practice_stats_locked();
    reset_practice_locked();
    completed_ = false;
    paused_elapsed_ = std::chrono::milliseconds(0);
}

void PlaybackController::set_countdown(std::chrono::milliseconds duration) {
    std::lock_guard lock(mutex_);
    countdown_ = std::max(std::chrono::milliseconds(0), duration);
}

std::chrono::milliseconds PlaybackController::countdown_duration() const {
    std::lock_guard lock(mutex_);
    return countdown_;
}

void PlaybackController::set_practice_mode(bool enabled) {
    stop();
    std::lock_guard lock(mutex_);
    practice_mode_ = enabled;
    practice_pinned_phrase_ = kNoPhrase;
    reset_practice_stats_locked();
    reset_practice_locked();
}

bool PlaybackController::practice_mode() const {
    std::lock_guard lock(mutex_);
    return practice_mode_;
}

void PlaybackController::set_practice_tempo(bool enabled) {
    stop();
    std::lock_guard lock(mutex_);
    if (practice_tempo_ == enabled) {
        return;
    }
    practice_tempo_ = enabled;
    reset_practice_locked();
}

bool PlaybackController::practice_tempo() const {
    std::lock_guard lock(mutex_);
    return practice_tempo_;
}

void PlaybackController::set_practice_auto_speed(bool enabled) {
    std::lock_guard lock(mutex_);
    practice_auto_speed_ = enabled;
}

bool PlaybackController::practice_auto_speed() const {
    std::lock_guard lock(mutex_);
    return practice_auto_speed_;
}

void PlaybackController::set_practice_lock_until_mastered(bool enabled) {
    std::lock_guard lock(mutex_);
    practice_lock_until_mastered_ = enabled;
}

bool PlaybackController::practice_lock_until_mastered() const {
    std::lock_guard lock(mutex_);
    return practice_lock_until_mastered_;
}

void PlaybackController::set_practice_ramp_start(double speed) {
    std::lock_guard lock(mutex_);
    practice_ramp_start_ = speed <= 0.0 ? 0.0 : std::clamp(speed, 0.25, 1.0);
}

double PlaybackController::practice_ramp_start() const {
    std::lock_guard lock(mutex_);
    return practice_ramp_start_;
}

void PlaybackController::set_practice_latency_offset(std::chrono::milliseconds offset) {
    std::lock_guard lock(mutex_);
    practice_latency_offset_ = std::clamp(offset, std::chrono::milliseconds(-300),
                                          std::chrono::milliseconds(300));
}

void PlaybackController::set_practice_timing_windows(PracticeTimingWindows windows) {
    std::lock_guard lock(mutex_);
    windows.early = std::clamp(windows.early, std::chrono::milliseconds(0),
                               std::chrono::milliseconds(5000));
    windows.miss = std::clamp(windows.miss, std::chrono::milliseconds(1),
                              std::chrono::milliseconds(10000));
    windows.chord = std::clamp(windows.chord, std::chrono::milliseconds(0),
                               windows.miss);
    practice_timing_windows_ = windows;
}

PracticeTimingWindows PlaybackController::practice_timing_windows() const {
    std::lock_guard lock(mutex_);
    return practice_timing_windows_;
}

std::chrono::milliseconds PlaybackController::practice_latency_offset() const {
    std::lock_guard lock(mutex_);
    return practice_latency_offset_;
}

void PlaybackController::practice_tick() {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || !practice_tempo_ || practice_index_ >= notes_.size()) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    // Beat clock in song time (negative during the count-in, so the count-in
    // clicks too). Speed is already folded into origin_, so the wall-clock
    // interval follows the practice speed.
    if (metronome_interval_.count() > 0 &&
        (state_ == PlaybackState::playing || state_ == PlaybackState::countdown)) {
        const double song_ms =
            std::chrono::duration<double, std::milli>(now - origin_).count() * speed_;
        const long long beat = static_cast<long long>(
            std::floor(song_ms / metronome_interval_.count()));
        if (!metronome_last_beat_.has_value()) {
            metronome_last_beat_ = beat;
        } else if (beat != *metronome_last_beat_) {
            metronome_last_beat_ = beat;
            ++metronome_ticks_;
            metronome_downbeat_ = ((beat % 4) + 4) % 4 == 0;
        }
    }
    if (state_ == PlaybackState::countdown) {
        if (now < countdown_end_) {
            return;
        }
        state_ = PlaybackState::playing;
        origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
            std::chrono::duration<double, std::milli>(
                notes_[practice_index_].timestamp.count() / speed_));
        start_practice_target_locked();
        return;
    }
    if (state_ != PlaybackState::playing) {
        return;
    }
    const auto elapsed = practice_tempo_elapsed_locked();
    const auto target = notes_[practice_index_].timestamp + practice_latency_offset_;
    if (!practice_beat_emitted_ && elapsed >= target) {
        ++practice_beat_sequence_;
        practice_beat_emitted_ = true;
    }
    while (practice_index_ < notes_.size() &&
           elapsed > notes_[practice_index_].timestamp + practice_latency_offset_ +
               practice_timing_windows_.miss) {
        advance_practice_note_locked(false, PracticeInputResult::missed, now);
        if (state_ != PlaybackState::playing) {
            break;
        }
    }
}

PracticeInputResult PlaybackController::practice_key(Key key) {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || state_ != PlaybackState::playing ||
        practice_index_ >= notes_.size()) {
        return PracticeInputResult::ignored;
    }

    const std::vector<Key>& expected = notes_[practice_index_].keys;
    if (std::find(expected.begin(), expected.end(), key) == expected.end()) {
        ++practice_wrong_keys_;
        ++practice_rep_wrong_;
        practice_streak_ = 0;
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].wrong_keys;
        }
        practice_feedback_ = PracticeInputResult::wrong;
        return PracticeInputResult::wrong;
    }
    PracticeInputResult timing_feedback = PracticeInputResult::advanced;
    const auto now = std::chrono::steady_clock::now();
    if (!practice_pressed_.empty() && practice_timing_windows_.chord.count() > 0 &&
        now - practice_chord_started_at_ > practice_timing_windows_.chord) {
        // Do not let a stale first key combine with a later chord attempt.
        return advance_practice_note_locked(false, PracticeInputResult::missed, now);
    }
    if (practice_tempo_ && practice_pressed_.empty()) {
        const auto actual = practice_tempo_elapsed_locked();
        const auto target = notes_[practice_index_].timestamp + practice_latency_offset_;
        const auto difference = actual - target;
        if (difference < -practice_timing_windows_.early) {
            ++practice_early_inputs_;
            practice_feedback_ = PracticeInputResult::early;
            return PracticeInputResult::early;
        }
        if (difference > practice_timing_windows_.miss) {
            return advance_practice_note_locked(
                false, PracticeInputResult::missed,
                std::chrono::steady_clock::now());
        }
        if (difference > practice_timing_windows_.early) {
            practice_late_current_ = true;
            timing_feedback = PracticeInputResult::late;
        }
        // Committed to the timing histogram only if this note is completed.
        practice_pending_offset_ = static_cast<int>(difference.count());
    }
    if (std::find(practice_pressed_.begin(), practice_pressed_.end(), key) ==
        practice_pressed_.end()) {
        if (practice_pressed_.empty()) {
            practice_chord_started_at_ = now;
        }
        practice_pressed_.push_back(key);
    }
    if (practice_pressed_.size() < expected.size()) {
        // Still assembling the chord; stats are only charged if it is
        // abandoned (see advance_practice_note_locked).
        practice_feedback_ = PracticeInputResult::partial;
        return PracticeInputResult::partial;
    }
    if (practice_late_current_) {
        timing_feedback = PracticeInputResult::late;
    }
    return advance_practice_note_locked(true, timing_feedback, now);
}

void PlaybackController::practice_restart_phrase() {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || practice_phrases_.empty()) {
        return;
    }
    practice_index_ = practice_phrases_[practice_phrase_index_].first;
    practice_pressed_.clear();
    practice_clean_repetitions_ = 0;
    practice_rep_completed_ = 0;
    practice_rep_wrong_ = 0;
    practice_rep_partial_ = 0;
    completed_ = false;
    rewind_timeline_locked(practice_index_, kPhraseLeadIn);
    start_practice_target_locked();
    practice_feedback_ = PracticeInputResult::ignored;
}

void PlaybackController::practice_jump_to_phrase(std::size_t phrase, bool pin) {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || phrase >= practice_phrases_.size()) {
        return;
    }
    practice_pinned_phrase_ = pin ? phrase : kNoPhrase;
    practice_phrase_index_ = phrase;
    practice_index_ = practice_phrases_[phrase].first;
    practice_pressed_.clear();
    practice_pending_offset_.reset();
    practice_clean_repetitions_ = 0;
    practice_rep_completed_ = 0;
    practice_rep_wrong_ = 0;
    practice_rep_partial_ = 0;
    if (state_ == PlaybackState::playing || state_ == PlaybackState::paused) {
        rewind_timeline_locked(practice_index_, kPhraseLeadIn);
        if (state_ == PlaybackState::paused) {
            paused_at_ = std::chrono::steady_clock::now();
        }
    }
    start_practice_target_locked();
    practice_feedback_ = PracticeInputResult::ignored;
}

void PlaybackController::practice_unpin_phrase() {
    std::lock_guard lock(mutex_);
    practice_pinned_phrase_ = kNoPhrase;
}

void PlaybackController::set_metronome_bpm(int bpm) {
    std::lock_guard lock(mutex_);
    metronome_interval_ = bpm > 0
        ? std::chrono::milliseconds(60000 / std::clamp(bpm, 20, 400))
        : std::chrono::milliseconds(0);
    metronome_last_beat_.reset();
}

std::pair<std::size_t, bool> PlaybackController::practice_metronome() const {
    std::lock_guard lock(mutex_);
    return {metronome_ticks_, metronome_downbeat_};
}

std::size_t PlaybackController::note_count() const {
    std::lock_guard lock(mutex_);
    return notes_.size();
}

std::chrono::milliseconds PlaybackController::duration_locked() const {
    return notes_.empty() ? std::chrono::milliseconds(0) : notes_.back().timestamp;
}

std::chrono::milliseconds PlaybackController::elapsed_locked() const {
    const auto duration = duration_locked();
    if (practice_mode_) {
        if (practice_tempo_) {
            return std::clamp(practice_tempo_elapsed_locked(),
                              std::chrono::milliseconds(0), duration);
        }
        if (practice_index_ >= notes_.size()) {
            return duration;
        }
        return notes_[practice_index_].timestamp;
    }
    std::chrono::milliseconds elapsed{0};
    const auto now = std::chrono::steady_clock::now();
    if (state_ == PlaybackState::playing) {
        const double ms =
            std::chrono::duration<double, std::milli>(now - origin_).count() * speed_;
        elapsed = std::chrono::milliseconds(static_cast<long long>(ms));
    } else if (state_ == PlaybackState::countdown) {
        elapsed = std::chrono::milliseconds(0);
    } else if (state_ == PlaybackState::paused) {
        elapsed = paused_elapsed_;
    } else if (completed_) {
        elapsed = duration;
    } else if (state_ == PlaybackState::stopped) {
        elapsed = paused_elapsed_;
    }
    return std::clamp(elapsed, std::chrono::milliseconds(0), duration);
}

std::chrono::milliseconds PlaybackController::practice_tempo_elapsed_locked() const {
    if (!practice_tempo_) {
        return elapsed_locked();
    }
    if (state_ == PlaybackState::playing) {
        const double ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - origin_).count() * speed_;
        return std::chrono::milliseconds(static_cast<long long>(ms));
    }
    if (state_ == PlaybackState::paused) {
        return paused_elapsed_;
    }
    if (completed_) {
        return duration_locked();
    }
    return std::chrono::milliseconds(0);
}

HighwayClock PlaybackController::highway_clock() const {
    std::lock_guard lock(mutex_);
    HighwayClock clock;
    clock.state = state_;
    clock.practice = practice_mode_;
    clock.tempo = practice_tempo_;
    clock.practice_index = practice_index_;
    clock.speed = speed_;
    clock.notes_revision = notes_revision_;

    const auto now = std::chrono::steady_clock::now();
    const auto song_since_origin = [&] {
        return std::chrono::duration<double, std::milli>(now - origin_).count() * speed_;
    };
    if (practice_mode_ && !practice_tempo_) {
        clock.song_ms = practice_index_ < notes_.size()
            ? static_cast<double>(notes_[practice_index_].timestamp.count())
            : static_cast<double>(duration_locked().count());
    } else if (practice_mode_ &&
               (state_ == PlaybackState::playing || state_ == PlaybackState::countdown)) {
        // Song-speed practice anchors origin_ ahead of the count-in, so this is
        // naturally negative until the first note is due.
        clock.song_ms = song_since_origin();
    } else if (state_ == PlaybackState::playing) {
        clock.song_ms = song_since_origin();
    } else if (state_ == PlaybackState::countdown) {
        // Autoplay: song time 0 starts when the count-in ends.
        clock.song_ms = -std::chrono::duration<double, std::milli>(countdown_end_ - now).count() * speed_;
    } else {
        clock.song_ms = static_cast<double>(elapsed_locked().count());
    }
    return clock;
}

std::vector<Note> PlaybackController::notes() const {
    std::lock_guard lock(mutex_);
    return notes_;
}

PlaybackSnapshot PlaybackController::snapshot() const {
    std::lock_guard lock(mutex_);

    const auto duration = duration_locked();
    const auto elapsed = elapsed_locked();

    const double progress = practice_mode_ && !notes_.empty() && !practice_tempo_
        ? static_cast<double>(practice_index_) / notes_.size()
        : duration.count() > 0
            ? static_cast<double>(elapsed.count()) / duration.count()
            : 0.0;

    std::string current;
    std::string next;
    std::vector<Key> active_keys;

    if (!notes_.empty() && practice_mode_) {
        if (practice_index_ < notes_.size()) {
            current = describe(notes_[practice_index_].keys);
            if (practice_index_ + 1 < notes_.size()) {
                next = describe(notes_[practice_index_ + 1].keys);
            }
            if (state_ == PlaybackState::playing || state_ == PlaybackState::paused) {
                active_keys = notes_[practice_index_].keys;
            }
        }
    } else if (!notes_.empty()) {
        std::size_t index = 0;
        for (std::size_t i = 0; i < notes_.size(); ++i) {
            if (notes_[i].timestamp <= elapsed) {
                index = i;
            } else {
                break;
            }
        }
        current = describe(notes_[index].keys);
        if (index + 1 < notes_.size()) {
            next = describe(notes_[index + 1].keys);
        }
        if (state_ == PlaybackState::playing || state_ == PlaybackState::paused ||
            state_ == PlaybackState::countdown) {
            active_keys = notes_[index].keys;
        }
    }

    std::chrono::milliseconds countdown_remaining{0};
    if (state_ == PlaybackState::countdown) {
        const auto now = std::chrono::steady_clock::now();
        if (countdown_end_ > now) {
            countdown_remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                countdown_end_ - now);
        }
    }

    PracticeStatsSnapshot practice_stats;
    practice_stats.notes_completed = practice_notes_completed_;
    practice_stats.wrong_keys = practice_wrong_keys_;
    practice_stats.partial_chords = practice_partial_chords_;
    practice_stats.chords_completed = practice_chords_completed_;
    practice_stats.phrases_completed = practice_phrases_completed_;
    const std::size_t accuracy_denominator =
        practice_notes_completed_ + practice_wrong_keys_;
    practice_stats.accuracy = accuracy_denominator > 0
        ? static_cast<double>(practice_notes_completed_) / accuracy_denominator
        : 0.0;
    practice_stats.average_response = std::chrono::milliseconds(0);
    if (practice_notes_completed_ > 0) {
        practice_stats.average_response = std::chrono::milliseconds(
            practice_response_total_.count() /
            static_cast<long long>(practice_notes_completed_));
    }
    practice_stats.last_response = practice_last_response_;
    practice_stats.phrases = practice_stats_;
    practice_stats.early_inputs = practice_early_inputs_;
    practice_stats.late_inputs = practice_late_inputs_;
    practice_stats.missed_notes = practice_missed_notes_;
    practice_stats.streak = practice_streak_;
    practice_stats.best_streak = practice_best_streak_;
    practice_stats.session = practice_session_;
    practice_stats.pinned_phrase = practice_pinned_phrase_;
    practice_stats.offset_samples = practice_offsets_.size();
    practice_stats.offset_min_ms =
        -static_cast<int>(practice_timing_windows_.early.count());
    practice_stats.offset_max_ms =
        static_cast<int>(practice_timing_windows_.miss.count());
    if (!practice_offsets_.empty()) {
        constexpr std::size_t kBins = 24;
        practice_stats.offset_bins.assign(kBins, 0);
        const int lo = practice_stats.offset_min_ms;
        const int span = std::max(1, practice_stats.offset_max_ms - lo);
        long long total = 0;
        for (int offset : practice_offsets_) {
            total += offset;
            const int clamped = std::clamp(offset, lo, practice_stats.offset_max_ms);
            const std::size_t bin = std::min<std::size_t>(
                kBins - 1, static_cast<std::size_t>(
                    static_cast<long long>(clamped - lo) * kBins / span));
            ++practice_stats.offset_bins[bin];
        }
        practice_stats.average_offset = std::chrono::milliseconds(
            total / static_cast<long long>(practice_offsets_.size()));
    }

    const std::size_t expected_count =
        practice_mode_ && practice_index_ < notes_.size()
            ? notes_[practice_index_].keys.size()
            : 0;
    return {state_, elapsed, duration, progress, current, next,
            std::move(active_keys), practice_phrase_index_,
            practice_phrases_.size(), practice_feedback_,
            practice_pressed_.size(), expected_count, practice_beat_sequence_,
            std::move(practice_stats),
            loop_, speed_, countdown_remaining};
}

void PlaybackController::run() {
    // Count-in: hold until the countdown window elapses (interruptible).
    {
        std::unique_lock lock(mutex_);
        while (!stop_requested_) {
            if (state_ == PlaybackState::paused) {
                condition_.wait(lock, [this] {
                    return stop_requested_ || state_ != PlaybackState::paused;
                });
                continue;
            }
            if (state_ != PlaybackState::countdown) {
                break;
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= countdown_end_) {
                state_ = PlaybackState::playing;
                origin_ = now;  // song-time 0 starts exactly now
                break;
            }
            condition_.wait_until(lock, countdown_end_);
        }
        if (stop_requested_) {
            return;
        }
    }

    for (;;) {
        std::size_t i = 0;
        // Position i at the first note at or after the current play head.
        {
            std::lock_guard lock(mutex_);
            const auto here = elapsed_locked();
            while (i < notes_.size() && notes_[i].timestamp < here) {
                ++i;
            }
            seek_requested_ = false;
        }

        bool restart = false;
        for (; i < notes_.size(); ++i) {
            std::chrono::milliseconds fire;
            {
                std::lock_guard lock(mutex_);
                fire = notes_[i].timestamp;
            }

            if (!wait_until(fire, &restart)) {
                if (restart) {
                    break;  // seek → recompute index
                }
                return;     // stop / notes swap
            }

            std::vector<Key> keys;
            {
                std::lock_guard lock(mutex_);
                if (stop_requested_) {
                    return;
                }
                keys = notes_[i].keys;
            }
            if (!keys.empty()) {
                keyboard_.press(keys);
            }
        }

        if (restart) {
            continue;  // re-derive index from the new play head
        }

        // Reached the end. Loop if requested, else finish.
        std::unique_lock lock(mutex_);
        if (stop_requested_) {
            return;
        }
        if (loop_) {
            origin_ = std::chrono::steady_clock::now();
            completed_ = false;
            continue;
        }

        state_ = PlaybackState::stopped;
        completed_ = true;
        // Notify outside the lock — the callback may re-enter (e.g. load the
        // next song and call play()), which would deadlock under mutex_.
        std::function<void()> finished = on_finished_;
        lock.unlock();
        if (finished) {
            finished();
        }
        return;
    }
}

bool PlaybackController::wait_until(std::chrono::milliseconds timestamp, bool* restart) {
    *restart = false;
    for (;;) {
        std::unique_lock lock(mutex_);
        if (stop_requested_) {
            return false;
        }
        if (seek_requested_) {
            *restart = true;
            return false;
        }
        if (state_ == PlaybackState::paused) {
            condition_.wait(lock, [this] {
                return stop_requested_ || seek_requested_ ||
                       state_ != PlaybackState::paused;
            });
            continue;
        }

        const auto target = origin_ +
            std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double, std::milli>(timestamp.count() / speed_));
        const auto now = std::chrono::steady_clock::now();
        // A delayed worker wake (typically after app/system backgrounding)
        // must not drain every overdue note at once. Re-derive the play head;
        // run() will skip notes that are already behind it and resume from the
        // current musical position.
        constexpr auto kMaxSchedulerLateness = std::chrono::milliseconds(100);
        if (now > target + kMaxSchedulerLateness) {
            *restart = true;
            return false;
        }
        if (now >= target) {
            return true;
        }

        // Sleep directly until the musical deadline, but remain interruptible
        // for pause, seek, speed changes, and stop. Polling in short slices
        // adds avoidable jitter to closely spaced notes.
        condition_.wait_until(lock, target, [this] {
            return stop_requested_ || seek_requested_ ||
                   state_ == PlaybackState::paused;
        });
    }
}

std::string PlaybackController::describe(const std::vector<Key>& keys) {
    if (keys.empty()) {
        return "—";
    }
    std::ostringstream text;
    for (std::size_t i = 0; i < keys.size(); ++i) {
        if (i != 0) {
            text << '+';
        }
        text << key_name(keys[i]);
    }
    return text.str();
}
