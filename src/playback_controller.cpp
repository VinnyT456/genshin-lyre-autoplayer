#include "playback_controller.h"

#include <algorithm>
#include <array>
#include <sstream>
#include <utility>

namespace {

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
        typical_gap = gaps[gaps.size() / 2];
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
}

PlaybackController::PlaybackController(std::vector<Note> notes, Keyboard& keyboard)
    : notes_(std::move(notes)), keyboard_(keyboard) {
    rebuild_practice_phrases_locked();
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
        if (practice_index_ >= notes_.size()) {
            reset_practice_locked();
        }
        practice_pressed_.clear();
        stop_requested_ = false;
        completed_ = false;
        state_ = PlaybackState::playing;
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
    reset_practice_locked();
}

bool PlaybackController::practice_mode() const {
    std::lock_guard lock(mutex_);
    return practice_mode_;
}

PracticeInputResult PlaybackController::practice_key(Key key) {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || state_ != PlaybackState::playing ||
        practice_index_ >= notes_.size()) {
        return PracticeInputResult::ignored;
    }

    const std::vector<Key>& expected = notes_[practice_index_].keys;
    if (std::find(expected.begin(), expected.end(), key) == expected.end()) {
        return PracticeInputResult::wrong;
    }
    if (std::find(practice_pressed_.begin(), practice_pressed_.end(), key) ==
        practice_pressed_.end()) {
        practice_pressed_.push_back(key);
    }
    if (practice_pressed_.size() < expected.size()) {
        return PracticeInputResult::partial;
    }

    practice_pressed_.clear();
    ++practice_index_;
    const auto [phrase_start, phrase_end] =
        practice_phrases_[practice_phrase_index_];
    if (practice_index_ < phrase_end) {
        return PracticeInputResult::advanced;
    }
    if (loop_) {
        practice_index_ = phrase_start;
        return PracticeInputResult::phrase_completed;
    }
    if (practice_phrase_index_ + 1 < practice_phrases_.size()) {
        ++practice_phrase_index_;
        practice_index_ = practice_phrases_[practice_phrase_index_].first;
        return PracticeInputResult::phrase_completed;
    }
    if (practice_index_ >= notes_.size()) {
        state_ = PlaybackState::stopped;
        completed_ = true;
        return PracticeInputResult::completed;
    }
    return PracticeInputResult::phrase_completed;
}

void PlaybackController::practice_restart_phrase() {
    std::lock_guard lock(mutex_);
    if (!practice_mode_ || practice_phrases_.empty()) {
        return;
    }
    practice_index_ = practice_phrases_[practice_phrase_index_].first;
    practice_pressed_.clear();
    completed_ = false;
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

PlaybackSnapshot PlaybackController::snapshot() const {
    std::lock_guard lock(mutex_);

    const auto duration = duration_locked();
    const auto elapsed = elapsed_locked();

    const double progress = practice_mode_ && !notes_.empty()
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

    return {state_, elapsed, duration, progress, current, next,
            std::move(active_keys), practice_phrase_index_,
            practice_phrases_.size(), loop_, speed_, countdown_remaining};
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
