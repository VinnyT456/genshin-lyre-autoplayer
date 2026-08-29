#pragma once

#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>

using namespace std;

class Genshin {
private:
    NSWorkspace* workspace;
    NSRunningApplication* genshin_application;
public:
    Genshin();

    void locate_application();
    void activate_application();
};