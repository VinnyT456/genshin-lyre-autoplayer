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
    void press(Key key);
    void press(Key key, chrono::milliseconds);
    void keyDown(Key key);
    void keyUp(Key key);
};