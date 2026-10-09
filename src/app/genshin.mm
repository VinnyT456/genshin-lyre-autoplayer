#include "genshin.h"
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <iostream>

namespace {

bool contains_genshin(NSString* value) {
    if (value == nil) {
        return false;
    }
    // Match the global client plus the CN release ("YuanShen" / "原神"), which
    // contains none of the string "genshin".
    for (NSString* needle in @[@"genshin", @"yuanshen", @"原神"]) {
        if ([value rangeOfString:needle
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return true;
        }
    }
    return false;
}

bool is_genshin_application(NSRunningApplication* app) {
    // The game is always a regular (Dock) app. Helpers that happen to carry
    // "genshin" in their name are accessory/background processes — e.g. an
    // editor's extension host for a project folder named genshin-*, or macOS's
    // "AutoFill (Genshin Impact)" — and must never be targeted.
    if (app == nil ||
        app.activationPolicy != NSApplicationActivationPolicyRegular ||
        app.processIdentifier == NSProcessInfo.processInfo.processIdentifier) {
        return false;
    }
    return contains_genshin(app.localizedName) ||
        contains_genshin(app.bundleIdentifier) ||
        contains_genshin(app.executableURL.lastPathComponent);
}

// Score how likely a candidate owns the playable window. PlayCover can leave
// more than one matching bundle running; prefer the active one, then one with
// a window on screen, then one with any normal window (e.g. on another Space).
int window_score(pid_t pid, NSArray* windows) {
    int best = 0;
    for (NSDictionary* window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid ||
            [window[(id)kCGWindowLayer] intValue] != 0) {
            continue;
        }
        best = std::max(best, [window[(id)kCGWindowIsOnscreen] boolValue] ? 2 : 1);
    }
    return best;
}

}  // namespace

NSRunningApplication* find_genshin_application() {
    NSMutableArray<NSRunningApplication*>* candidates = [NSMutableArray array];
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (is_genshin_application(app)) {
            if (app.isActive) {
                return app;
            }
            [candidates addObject:app];
        }
    }
    if (candidates.count <= 1) {
        return candidates.firstObject;
    }

    NSArray* windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID)) ?: @[];
    NSRunningApplication* best = candidates.firstObject;
    int best_score = -1;
    for (NSRunningApplication* app in candidates) {
        const int score = window_score(app.processIdentifier, windows);
        if (score > best_score) {
            best_score = score;
            best = app;
        }
    }
    return best;
}

pid_t find_genshin_pid() {
    NSRunningApplication* app = find_genshin_application();
    return app != nil ? app.processIdentifier : 0;
}

Genshin::Genshin() {
    workspace = [NSWorkspace sharedWorkspace];
}

void Genshin::locate_application() {
    genshin_application = find_genshin_application();
    if (genshin_application != nil) {
        std::cout << "Found Genshin (pid "
                  << genshin_application.processIdentifier << ")\n";
    }
}

void Genshin::activate_application() {
    // Refresh the process reference every time: PlayCover or the game can be
    // relaunched, which invalidates the previously cached NSRunningApplication.
    locate_application();
    if (genshin_application == nil) {
        return;
    }

    // This process runs as an Accessory app (no Dock icon). On macOS 14+ an app
    // may only raise ANOTHER app while it is itself the active app — and the old
    // NSApplicationActivateIgnoringOtherApps flag is now a no-op — so an inactive
    // accessory app's activate request is simply dropped. Make ourselves active
    // first, then activate the game on the next runloop turn (so our own
    // activation has taken effect before we hand focus to Genshin).
    [NSApp activateIgnoringOtherApps:YES];
    NSRunningApplication* app = genshin_application;

    // Primary: the direct activate. Cheap, and enough when we already hold focus.
    [app activateWithOptions:NSApplicationActivateAllWindows];

    // Sturdy fallback: re-open the app bundle. NSWorkspace's open request brings
    // an already-running app frontmost on every modern macOS, from an accessory
    // app, without Accessibility/Automation permission — unlike a bare
    // activateWithOptions:, which macOS 14+ drops when the caller isn't active.
    NSURL* bundle = app.bundleURL;
    if (bundle != nil) {
        NSWorkspaceOpenConfiguration* config =
            [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSWorkspace sharedWorkspace]
                openApplicationAtURL:bundle
                       configuration:config
                   completionHandler:^(NSRunningApplication* _Nullable running,
                                       NSError* _Nullable error) {
                (void)running;
                (void)error;
            }];
        });
    } else {
        // No bundle URL (rare) — re-issue the direct activate a beat later to win
        // any race with the app currently holding focus.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [app activateWithOptions:NSApplicationActivateAllWindows];
        });
    }
}
