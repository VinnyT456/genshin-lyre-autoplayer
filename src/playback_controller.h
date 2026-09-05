#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "keyboard.h"
#include "note.h"

enum class PlaybackState { stopped, countdown, playing, paused };

enum class PracticeInputResult {
    ignored,
    wrong,
    partial,
    early,
    late,
    missed,
    advanced,
    phrase_completed,
    completed
};

struct PracticePhraseSnapshot {
    std::size_t note_count = 0;
    std::size_t completed_notes = 0;
    std::size_t wrong_keys = 0;
    std::size_t partial_chords = 0;
    std::size_t repetitions = 0;
    std::size_t clean_repetitions = 0;
    double accuracy = 0.0;
    double best_accuracy = 0.0;
    bool mastered = false;
};

struct PracticeStatsSnapshot {
    std::size_t notes_completed = 0;
    std::size_t wrong_keys = 0;
    std::size_t partial_chords = 0;
    std::size_t chords_completed = 0;
    std::size_t phrases_completed = 0;
    double accuracy = 0.0;
    std::chrono::milliseconds average_response{0};
    std::chrono::milliseconds last_response{0};
    std::vector<PracticePhraseSnapshot> phrases;
    std::size_t early_inputs = 0;
    std::size_t late_inputs = 0;
    std::size_t missed_notes = 0;
};

struct PlaybackSnapshot {
    PlaybackState state;
    std::chrono::milliseconds elapsed;
    std::chrono::milliseconds duration;
    double progress;
    std::string current_note;
    std::string next_note;
    std::vector<Key> active_keys;
    std::size_t practice_phrase_index;
    std::size_t practice_phrase_count;
    PracticeInputResult practice_feedback;
    std::size_t practice_pressed_count;
    std::size_t practice_expected_count;
    PracticeStatsSnapshot practice_stats;
    bool loop;                                        // whole-song loop enabled
    double speed;                                     // playback rate multiplier
    std::chrono::milliseconds countdown_remaining;    // > 0 while counting in
};

class PlaybackController {
public:
    PlaybackController(std::vector<Note> notes, Keyboard& keyboard);
    ~PlaybackController();

    // Transport.
    void play();                    // starts a fresh run (with count-in) or resumes
    void pause();
    void stop();
    void seek(std::chrono::milliseconds position);
    void seek_fraction(double fraction);  // 0..1 over the song duration

    // Looping.
    void set_loop(bool loop);
    void toggle_loop();

    // Tempo. Multiplier clamped to [0.25, 3.0]; preserves current position.
    void set_speed(double speed);
    void nudge_speed(double delta);

    // Queue support: swap the active note set (stops playback first).
    void set_notes(std::vector<Note> notes);

    // Count-in length before playback actually fires keys.
    void set_countdown(std::chrono::milliseconds duration);

    // Learn mode: the song advances only when the user supplies the expected
    // key or chord. It never posts automatic keystrokes.
    void set_practice_mode(bool enabled);
    bool practice_mode() const;
    void set_practice_tempo(bool enabled);
    bool practice_tempo() const;
    void practice_tick();
    PracticeInputResult practice_key(Key key);
    void practice_restart_phrase();

    // Called (on the worker thread) when a song finishes naturally — not on
    // stop/pause/seek, and not when looping. Used for queue auto-advance.
    void set_on_finished(std::function<void()> callback);

    PlaybackSnapshot snapshot() const;
    std::size_t note_count() const;

private:
    void run();
    // Returns false if interrupted (stop / seek / notes swap). Sets *restart when
    // a seek repositioned the play head and the run loop must restart.
    bool wait_until(std::chrono::milliseconds timestamp, bool* restart);
    static std::string describe(const std::vector<Key>& keys);
    std::chrono::milliseconds duration_locked() const;
    std::chrono::milliseconds elapsed_locked() const;
    std::chrono::milliseconds practice_tempo_elapsed_locked() const;

    std::vector<Note> notes_;
    Keyboard& keyboard_;
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    std::thread worker_;
    PlaybackState state_ = PlaybackState::stopped;
    bool stop_requested_ = false;
    bool completed_ = false;
    bool seek_requested_ = false;
    std::chrono::steady_clock::time_point origin_;
    std::chrono::steady_clock::time_point paused_at_;
    std::chrono::steady_clock::time_point countdown_end_;
    std::chrono::milliseconds paused_elapsed_{0};
    std::chrono::milliseconds countdown_{std::chrono::milliseconds(0)};
    bool loop_ = false;
    bool practice_mode_ = false;
    std::size_t practice_index_ = 0;
    std::size_t practice_phrase_index_ = 0;
    std::vector<std::pair<std::size_t, std::size_t>> practice_phrases_;
    std::vector<Key> practice_pressed_;
    std::vector<PracticePhraseSnapshot> practice_stats_;
    std::size_t practice_clean_repetitions_ = 0;
    std::size_t practice_rep_completed_ = 0;
    std::size_t practice_rep_wrong_ = 0;
    std::size_t practice_rep_partial_ = 0;
    std::size_t practice_notes_completed_ = 0;
    std::size_t practice_wrong_keys_ = 0;
    std::size_t practice_partial_chords_ = 0;
    std::size_t practice_chords_completed_ = 0;
    std::size_t practice_phrases_completed_ = 0;
    std::size_t practice_early_inputs_ = 0;
    std::size_t practice_late_inputs_ = 0;
    std::size_t practice_missed_notes_ = 0;
    std::chrono::milliseconds practice_response_total_{0};
    std::chrono::milliseconds practice_last_response_{0};
    std::chrono::steady_clock::time_point practice_target_started_at_;
    bool practice_tempo_ = false;
    bool practice_late_current_ = false;
    PracticeInputResult practice_feedback_ = PracticeInputResult::ignored;
    double speed_ = 1.0;
    std::function<void()> on_finished_;

    void rebuild_practice_phrases_locked();
    void reset_practice_locked();
    void reset_practice_stats_locked();
    void start_practice_target_locked();
    PracticeInputResult advance_practice_note_locked(
        bool completed, PracticeInputResult feedback,
        std::chrono::steady_clock::time_point now);
};
