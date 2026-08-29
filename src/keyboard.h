#pragma once

#include <unordered_map>
#include <vector>
#include <CoreGraphics/CoreGraphics.h>
#include <chrono>
#include "key.h"

using namespace std;

class Keyboard {
private:
    std::unordered_map<Key, CGKeyCode> keycodes;
    CGKeyCode getKeyCode(Key key);
public:
    Keyboard();
    void press(vector<Key> key);
    void keyDown(Key key);
    void keyUp(Key key);
};