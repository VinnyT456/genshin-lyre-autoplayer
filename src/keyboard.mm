#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include "keyboard.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <random>
#include <thread>
#include <unistd.h>

using namespace std;

namespace {

thread_local mt19937 rng{random_device{}()};

int human_delay_ms(double mean, double deviation, int minimum, int maximum) {
    normal_distribution<double> dist(mean, deviation);
    const int sampled = static_cast<int>(std::lround(dist(rng)));
    return std::clamp(sampled, minimum, maximum);
}

void sleep_ms(int ms) {
    if (ms > 0) {
        this_thread::sleep_for(chrono::milliseconds(ms));
    }
}

CGEventSourceRef event_source() {
    static CGEventSourceRef source =
        CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    return source;
}

NSRunningApplication* genshin_app() {
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.localizedName isEqualToString:@"Genshin Impact"]) {
            return app;
        }
    }
    return nil;
}

void post_event(CGEventRef event) {
    NSRunningApplication* app = genshin_app();
    if (app == nil) {
        CGEventPost(kCGHIDEventTap, event);
        return;
    }

    if (!app.isActive) {
        [app activateWithOptions:NSApplicationActivateAllWindows];
        usleep(50000);
    }

    CGEventPostToPid(app.processIdentifier, event);
}

}  // namespace

Keyboard::Keyboard() {
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

void Keyboard::keyDown(Key key) {
    CGEventRef key_down =
        CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), true);
    if (key_down == nullptr) {
        return;
    }

    post_event(key_down);
    CFRelease(key_down);
}

void Keyboard::keyUp(Key key) {
    CGEventRef key_up =
        CGEventCreateKeyboardEvent(event_source(), keycodes.at(key), false);
    if (key_up == nullptr) {
        return;
    }

    post_event(key_up);
    CFRelease(key_up);
}

void Keyboard::press(vector<Key> keys) {
    if (keys.empty()) {
        return;
    }

    // Human timing clusters around a typical value instead of treating every
    // point in a broad range as equally likely. Keep jitter short because the
    // playback scheduler already determines the intended note time.
    sleep_ms(human_delay_ms(5.0, 2.5, 1, 12));

    // A chord is one musical event. Post every key-down in one tight cluster
    // so the game receives the notes together instead of as a short arpeggio.
    for (Key key : keys) {
        keyDown(key);
    }

    // Most taps sit near 45 ms, with occasional shorter or longer presses.
    sleep_ms(human_delay_ms(45.0, 10.0, 26, 72));

    for (Key key : keys) {
        keyUp(key);
    }
}
