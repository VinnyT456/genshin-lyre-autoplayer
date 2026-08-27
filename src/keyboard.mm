#import <CoreGraphics/CoreGraphics.h>

#include "keyboard.h"
#include <thread>
#include <chrono>

using namespace std;

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
    CGKeyCode keyCode = keycodes.at(key);

    CGEventRef keyDown =
        CGEventCreateKeyboardEvent(
            nullptr,
            keyCode,
            true
        );

    if (keyDown == nullptr) {
        return;
    }

    CGEventPost(kCGHIDEventTap, keyDown);
    CFRelease(keyDown);
}

void Keyboard::keyUp(Key key) {
    CGKeyCode keyCode = keycodes.at(key);

    CGEventRef keyUp =
        CGEventCreateKeyboardEvent(
            nullptr,
            keyCode,
            false
        );

    if (keyUp == nullptr) {
        return;
    }

    CGEventPost(kCGHIDEventTap, keyUp);
    CFRelease(keyUp);
}

void Keyboard::press(Key key) {
    keyDown(key);
    this_thread::sleep_for(
        chrono::milliseconds(300)
    );
    keyUp(key);
}

void Keyboard::press(Key key, chrono::milliseconds hold_time) {
    keyDown(key);
    this_thread::sleep_for(
        chrono::milliseconds(hold_time)
    );
    keyUp(key);
}