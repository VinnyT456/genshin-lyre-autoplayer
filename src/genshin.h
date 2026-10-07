#pragma once

#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>

using namespace std;

// The running Genshin game (global or CN client), or nil if it isn't running.
// Only regular foreground apps qualify, so helper processes that merely have
// "genshin" in their name (editor extension hosts, AutoFill helpers) are never
// mistaken for the game. Works whether or not the game window is on screen.
NSRunningApplication* find_genshin_application();

// Convenience: the game's pid, or 0 if it isn't running.
pid_t find_genshin_pid();

class Genshin {
private:
    NSWorkspace* workspace;
    NSRunningApplication* genshin_application = nil;
public:
    Genshin();

    void locate_application();
    void activate_application();
};
