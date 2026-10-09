#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include "keyboard.h"
#include "genshin.h"

#include <cerrno>
#include <chrono>
#include <csignal>
#include <thread>
#include <unistd.h>

using namespace std;

namespace {

constexpr chrono::milliseconds kKeyHoldDuration{35};

CGEventSourceRef event_source() {
    static CGEventSourceRef source =
        CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    return source;
}

// True while the process exists. kill(pid, 0) sends nothing; EPERM still means
// the process is alive (we just can't signal it).
bool process_alive(pid_t pid) {
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

void prepare_target(pid_t pid, bool background) {
    // Background play posts straight to the pid and never touches focus.
    if (background) {
        return;
    }
    NSRunningApplication* app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app != nil && !app.isActive) {
        [app activateWithOptions:NSApplicationActivateAllWindows];
        usleep(50000);
    }
}

void post_event(CGEventRef event, pid_t target_pid) {
    if (target_pid == 0) {
        return;
    }

    CGEventPostToPid(target_pid, event);
}

}  // namespace

Keyboard::Keyboard() {
    // Background playback is the safe default for every construction path;
    // the HUD can still explicitly disable it for users who want Genshin
    // activated before playback.
    play_in_background.store(true, std::memory_order_relaxed);

    // CGEventCreateKeyboardEvent expects macOS virtual keycodes. PlayCover
    // translates these incoming virtual codes to the internal keymap codes
    // stored in Genshin Impact.playmap.
    keycodes[Key::Q] = 12;
    keycodes[Key::W] = 13;
    keycodes[Key::E] = 14;
    keycodes[Key::R] = 15;
    keycodes[Key::T] = 17;
    keycodes[Key::Y] = 16;
    keycodes[Key::U] = 32;

    keycodes[Key::A] = 0;
    keycodes[Key::S] = 1;
    keycodes[Key::D] = 2;
    keycodes[Key::F] = 3;
    keycodes[Key::G] = 5;
    keycodes[Key::H] = 4;
    keycodes[Key::J] = 38;

    keycodes[Key::Z] = 6;
    keycodes[Key::X] = 7;
    keycodes[Key::C] = 8;
    keycodes[Key::V] = 9;
    keycodes[Key::B] = 11;
    keycodes[Key::N] = 45;
    keycodes[Key::M] = 46;
}

void Keyboard::set_play_in_background(bool enabled) {
    play_in_background.store(enabled, std::memory_order_relaxed);
}

bool Keyboard::plays_in_background() const {
    return play_in_background.load(std::memory_order_relaxed);
}

void Keyboard::set_target_pid(pid_t pid) {
    target_pid.store(pid, std::memory_order_relaxed);
}

// Use the cached Genshin pid while that process is alive; only fall back to
// the (much slower) window-list scan when it is unknown or has exited. This
// keeps per-note latency low and pins keys to one process.
pid_t Keyboard::resolve_target_pid() {
    const pid_t cached = target_pid.load(std::memory_order_relaxed);
    if (process_alive(cached)) {
        return cached;
    }
    const pid_t pid = find_genshin_pid();
    target_pid.store(pid, std::memory_order_relaxed);
    return pid;
}

void Keyboard::keyDown(Key key) {
    const pid_t pid = resolve_target_pid();
    if (pid == 0) {
        return;
    }
    prepare_target(pid, plays_in_background());

    CGEventRef key_down =
        CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), true);
    if (key_down == nullptr) {
        return;
    }

    post_event(key_down, pid);
    CFRelease(key_down);
}

void Keyboard::keyUp(Key key) {
    const pid_t pid = resolve_target_pid();
    if (pid == 0) {
        return;
    }
    prepare_target(pid, plays_in_background());

    CGEventRef key_up =
        CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), false);
    if (key_up == nullptr) {
        return;
    }

    post_event(key_up, pid);
    CFRelease(key_up);
}

void Keyboard::press(vector<Key> keys) {
    if (keys.empty()) {
        return;
    }

    // Resolve the destination once per chord so key-downs and key-ups stay
    // tightly grouped and all land on the same process.
    const pid_t target_pid = resolve_target_pid();
    if (target_pid == 0) {
        return;
    }
    prepare_target(target_pid, plays_in_background());

    for (Key key : keys) {
        CGEventRef key_down =
            CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), true);
        if (key_down != nullptr) {
            post_event(key_down, target_pid);
            CFRelease(key_down);
        }
    }

    // A fixed tap duration keeps the musical timing deterministic while still
    // giving the game enough time to recognize each note.
    this_thread::sleep_for(kKeyHoldDuration);

    for (Key key : keys) {
        CGEventRef key_up =
            CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), false);
        if (key_up != nullptr) {
            post_event(key_up, target_pid);
            CFRelease(key_up);
        }
    }
}
