#include "playback_controller.h"

#include <algorithm>
#include <array>
#include <sstream>
#include <utility>

namespace {

constexpr std::chrono::milliseconds kPracticeEarlyWindow{220};
constexpr std::chrono::milliseconds kPracticeMissWindow{450};

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
}

void PlaybackController::start_practice_target_locked() {
    practice_target_started_at_ = std::chrono::steady_clock::now();
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
    } else {
        ++practice_missed_notes_;
        ++practice_wrong_keys_;
        ++practice_rep_wrong_;
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].wrong_keys;
        }
    }

    practice_pressed_.clear();
    ++practice_index_;
    const auto [phrase_start, phrase_end] =
        practice_phrases_[practice_phrase_index_];
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
        if (practice_rep_wrong_ == 0) {
            ++practice_clean_repetitions_;
        } else {
            practice_clean_repetitions_ = 0;
        }
        stats.clean_repetitions = practice_clean_repetitions_;
        stats.mastered = practice_clean_repetitions_ >= 3;
    }
    ++practice_phrases_completed_;
    practice_rep_completed_ = 0;
    practice_rep_wrong_ = 0;
    practice_rep_partial_ = 0;
    if (loop_) {
        practice_index_ = phrase_start;
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
            practice_target_started_at_ += now - paused_at_;
            if (practice_tempo_) {
                origin_ += now - paused_at_;
            }
            state_ = PlaybackState::playing;
            return;
        }
        if (practice_index_ >= notes_.size()) {
            reset_practice_locked();
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
        origin_ += std::chrono::steady_clock::now() - paused_at_;
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
    origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
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
    origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double, std::milli>(pos.count() / speed_));
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

void PlaybackController::set_practice_mode(bool enabled) {
    stop();
    std::lock_guard lock(mutex_);
    practice_mode_ = enabled;
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

void PlaybackController::practice_tick() {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || !practice_tempo_ || practice_index_ >= notes_.size()) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
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
    while (practice_index_ < notes_.size() &&
           elapsed > notes_[practice_index_].timestamp + kPracticeMissWindow) {
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
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].wrong_keys;
        }
        practice_feedback_ = PracticeInputResult::wrong;
        return PracticeInputResult::wrong;
    }
    PracticeInputResult timing_feedback = PracticeInputResult::advanced;
    if (practice_tempo_ && practice_pressed_.empty()) {
        const auto actual = practice_tempo_elapsed_locked();
        const auto difference = actual - notes_[practice_index_].timestamp;
        if (difference < -kPracticeEarlyWindow) {
            ++practice_early_inputs_;
            practice_feedback_ = PracticeInputResult::early;
            return PracticeInputResult::early;
        }
        if (difference > kPracticeMissWindow) {
            return advance_practice_note_locked(
                false, PracticeInputResult::missed,
                std::chrono::steady_clock::now());
        }
        if (difference > kPracticeEarlyWindow) {
            practice_late_current_ = true;
            timing_feedback = PracticeInputResult::late;
        }
    }
    if (std::find(practice_pressed_.begin(), practice_pressed_.end(), key) ==
        practice_pressed_.end()) {
        practice_pressed_.push_back(key);
    }
    if (practice_pressed_.size() < expected.size()) {
        ++practice_partial_chords_;
        ++practice_rep_partial_;
        if (practice_phrase_index_ < practice_stats_.size()) {
            ++practice_stats_[practice_phrase_index_].partial_chords;
        }
        practice_feedback_ = PracticeInputResult::partial;
        return PracticeInputResult::partial;
    }
    const auto now = std::chrono::steady_clock::now();
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
    if (practice_tempo_) {
        const auto now = std::chrono::steady_clock::now();
        const auto timestamp = notes_[practice_index_].timestamp;
        origin_ = now - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
            std::chrono::duration<double, std::milli>(timestamp.count() / speed_));
    }
    start_practice_target_locked();
    practice_feedback_ = PracticeInputResult::ignored;
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

    const std::size_t expected_count =
        practice_mode_ && practice_index_ < notes_.size()
            ? notes_[practice_index_].keys.size()
            : 0;
    return {state_, elapsed, duration, progress, current, next,
            std::move(active_keys), practice_phrase_index_,
            practice_phrases_.size(), practice_feedback_,
            practice_pressed_.size(), expected_count, std::move(practice_stats),
            loop_, speed_, countdown_remaining};
}

void PlaybackController::run() {
    // Count-in: hold until the countdown window elapses (interruptible).
    {
        std::unique_lock lock(mutex_);
        while (state_ == PlaybackState::countdown && !stop_requested_) {
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
        if (now >= target) {
            return true;
        }

        const auto wake = std::min(target, now + std::chrono::milliseconds(10));
        lock.unlock();
        std::this_thread::sleep_until(wake);
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
