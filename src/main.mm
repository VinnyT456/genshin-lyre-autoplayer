#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <iostream>
#include <thread>
#include <chrono>
#include "keyboard.h"
#include "genshin.h"

using namespace std;

int main() {
    @autoreleasepool {
        Genshin* genshin = new Genshin();
        Keyboard* keyboard = new Keyboard();

        genshin->locate_application();
        genshin->activate_application();
        
        keyboard->press(Key::Q);
        keyboard->press(Key::W);
        keyboard->press(Key::E);
        keyboard->press(Key::R);
        keyboard->press(Key::T);
        keyboard->press(Key::Y);
        keyboard->press(Key::U);                

        keyboard->press(Key::A);
        keyboard->press(Key::S);
        keyboard->press(Key::D);
        keyboard->press(Key::F);
        keyboard->press(Key::G);
        keyboard->press(Key::H);
        keyboard->press(Key::J);

        keyboard->press(Key::Z);
        keyboard->press(Key::X);
        keyboard->press(Key::C);
        keyboard->press(Key::V);
        keyboard->press(Key::B);
        keyboard->press(Key::N);
        keyboard->press(Key::M);
    }

    return 0;
}