#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <optional>
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

struct PracticeTimingWindows {
    std::chrono::milliseconds early{220};
    std::chrono::milliseconds miss{450};
    // Zero preserves the historical behavior: a chord may be assembled until
    // the normal miss window. A positive value limits the assembly interval.
    std::chrono::milliseconds chord{0};
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
    // Consecutive notes played without a wrong key or miss, and the session max.
    std::size_t streak = 0;
    std::size_t best_streak = 0;
    // Song-speed practice only: signed offset of each accepted input from its
    // target (negative = early/rushing, positive = late/dragging), binned over
    // [offset_min_ms, offset_max_ms] for the dashboard histogram.
    std::size_t offset_samples = 0;
    std::chrono::milliseconds average_offset{0};
    int offset_min_ms = 0;
    int offset_max_ms = 0;
    std::vector<std::size_t> offset_bins;
    // Increments whenever stats reset, so observers can spot a new session.
    std::size_t session = 0;
    // Phrase pinned for looping (jump-to-phrase / drills), or kNoPhrase.
    std::size_t pinned_phrase = static_cast<std::size_t>(-1);
};

constexpr std::size_t kNoPhrase = static_cast<std::size_t>(-1);

// Cheap per-frame state for the falling-notes view (no stats work).
struct HighwayClock {
    // Continuous song position in ms. Negative during a count-in, so notes
    // can fall in before the song starts. In wait-for-input practice it is the
    // timestamp of the note being waited on.
    double song_ms = 0.0;
    PlaybackState state = PlaybackState::stopped;
    bool practice = false;
    bool tempo = false;              // song-speed practice
    std::size_t practice_index = 0;  // note being waited on (practice)
    double speed = 1.0;
    std::size_t notes_revision = 0;  // changes whenever the note list changes
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
    std::size_t practice_beat_sequence;
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
    std::chrono::milliseconds countdown_duration() const;

    // Learn mode: the song advances only when the user supplies the expected
    // key or chord. It never posts automatic keystrokes.
    void set_practice_mode(bool enabled);
    bool practice_mode() const;
    void set_practice_tempo(bool enabled);
    bool practice_tempo() const;
    void set_practice_auto_speed(bool enabled);
    bool practice_auto_speed() const;
    // Loop-until-mastered: a phrase repeats in place until it is played
    // cleanly enough to count as mastered, then playback advances to the next
    // phrase automatically. Disabled = phrases advance on every completion.
    void set_practice_lock_until_mastered(bool enabled);
    bool practice_lock_until_mastered() const;
    // Speed ramp: when auto speed is on, a fresh practice run starts at this
    // speed (e.g. 0.5) and climbs 0.05x per clean phrase. 0 = keep current speed.
    void set_practice_ramp_start(double speed);
    double practice_ramp_start() const;
    // Jump straight to a phrase. With pin = true the phrase then repeats in
    // place until unpinned. If stopped, the next run starts there.
    void practice_jump_to_phrase(std::size_t phrase, bool pin);
    void practice_unpin_phrase();
    // Steady metronome on the song's beat during song-speed practice (count-in
    // included). 0 BPM disables it. practice_metronome() is cheap to poll:
    // returns the tick counter and whether the latest tick was a downbeat.
    void set_metronome_bpm(int bpm);
    std::pair<std::size_t, bool> practice_metronome() const;
    void set_practice_latency_offset(std::chrono::milliseconds offset);
    std::chrono::milliseconds practice_latency_offset() const;
    void set_practice_timing_windows(PracticeTimingWindows windows);
    PracticeTimingWindows practice_timing_windows() const;
    void practice_tick();
    PracticeInputResult practice_key(Key key);
    void practice_restart_phrase();

    // Called (on the worker thread) when a song finishes naturally — not on
    // stop/pause/seek, and not when looping. Used for queue auto-advance.
    void set_on_finished(std::function<void()> callback);

    PlaybackSnapshot snapshot() const;
    HighwayClock highway_clock() const;
    std::vector<Note> notes() const;  // copy; refetch when notes_revision changes
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
    bool paused_from_countdown_ = false;
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
    std::chrono::steady_clock::time_point practice_chord_started_at_;
    std::size_t practice_beat_sequence_ = 0;
    bool practice_beat_emitted_ = false;
    bool practice_tempo_ = false;
    bool practice_auto_speed_ = false;
    bool practice_lock_until_mastered_ = false;
    double practice_ramp_start_ = 0.0;
    std::size_t practice_streak_ = 0;
    std::size_t practice_best_streak_ = 0;
    std::vector<int> practice_offsets_;
    std::optional<int> practice_pending_offset_;
    std::size_t practice_session_ = 0;
    std::size_t notes_revision_ = 1;
    std::size_t practice_pinned_phrase_ = kNoPhrase;
    std::chrono::milliseconds metronome_interval_{0};
    std::optional<long long> metronome_last_beat_;
    std::size_t metronome_ticks_ = 0;
    bool metronome_downbeat_ = false;
    std::chrono::milliseconds practice_latency_offset_{0};
    PracticeTimingWindows practice_timing_windows_;
    bool practice_late_current_ = false;
    PracticeInputResult practice_feedback_ = PracticeInputResult::ignored;
    double speed_ = 1.0;
    std::function<void()> on_finished_;

    void rebuild_practice_phrases_locked();
    void reset_practice_locked();
    void reset_practice_stats_locked();
    void start_practice_target_locked();
    // Re-anchor the song-speed timeline so note `index` is due after `lead_in`.
    void rewind_timeline_locked(std::size_t index, std::chrono::milliseconds lead_in);
    PracticeInputResult advance_practice_note_locked(
        bool completed, PracticeInputResult feedback,
        std::chrono::steady_clock::time_point now);
};
