#pragma once

#include <unordered_map>
#include <vector>
#include <atomic>
#include <CoreGraphics/CoreGraphics.h>
#include <chrono>
#include <sys/types.h>
#include "key.h"

using namespace std;

class Keyboard {
private:
    std::unordered_map<Key, CGKeyCode> keycodes;
    std::atomic_bool play_in_background{false};
    // Genshin's process id, pushed in by the HUD's focus tracker. Keystrokes
    // are posted straight to this pid, so they reach the game whether or not
    // it is frontmost. 0 = unknown; fall back to a live lookup.
    std::atomic<pid_t> target_pid{0};
    CGKeyCode getKeyCode(Key key);
    pid_t resolve_target_pid();
public:
    Keyboard();
    void set_play_in_background(bool enabled);
    bool plays_in_background() const;
    void set_target_pid(pid_t pid);
    void press(vector<Key> key);
    void keyDown(Key key);
    void keyUp(Key key);
};
