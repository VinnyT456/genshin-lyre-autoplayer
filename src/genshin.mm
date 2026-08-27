#include "genshin.h"
#include <iostream>
#include <thread>
#include <chrono>

Genshin::Genshin() {
    workspace = [NSWorkspace sharedWorkspace];
}

void Genshin::locate_application() {
    NSArray<NSRunningApplication*>* applications =
            [workspace runningApplications];

    for (NSRunningApplication* app : applications) {
        NSString* name = [app localizedName];

        if ([name isEqualToString:@"Genshin Impact"]) {
            std::cout << "Found Genshin!\n";
            genshin_application = app;
            break;
        }
    }
}

void Genshin::activate_application() {
    [genshin_application activateWithOptions:
        NSEventSubtypeApplicationActivated];
}