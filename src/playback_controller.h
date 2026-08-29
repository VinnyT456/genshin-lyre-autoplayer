#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "keyboard.h"
#include "note.h"

enum class PlaybackState { stopped, countdown, playing, paused };

struct PlaybackSnapshot {
    PlaybackState state;
    std::chrono::milliseconds elapsed;
    std::chrono::milliseconds duration;
    double progress;
    std::string current_note;
    std::string next_note;
    std::vector<Key> active_keys;
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
    double speed_ = 1.0;
    std::function<void()> on_finished_;
};
