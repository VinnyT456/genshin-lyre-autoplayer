#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "PlayerWindow.h"
#include "genshin.h"
#include "keyboard.h"
#include "parser.h"
#include "playback_controller.h"
#include "settings.h"

namespace {

// Ensure this process is trusted for Accessibility; without it CGEventPostToPid
// is silently ignored. Shows the system prompt (which deep-links to the
// Accessibility pane) the first time, and a reminder alert if still untrusted.
void ensure_accessibility_trust() {
    NSDictionary* options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    if (AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        return;
    }
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Accessibility permission needed";
    alert.informativeText =
        @"This needs Accessibility access to send keystrokes to Genshin.\n\n"
        @"Open System Settings → Privacy & Security → Accessibility, enable the "
        @"terminal you launched it from, then quit and run it again.";
    [alert addButtonWithTitle:@"Open Accessibility Settings"];
    [alert addButtonWithTitle:@"Continue anyway"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURL* url = [NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security"
            @"?Privacy_Accessibility"];
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

// Resolve a path to an absolute, standardized form so a stored playlist works
// regardless of the working directory it's later launched from.
std::string absolute_path(NSString* path) {
    NSString* standardized = path.stringByStandardizingPath;
    if (!standardized.isAbsolutePath) {
        NSString* cwd = NSFileManager.defaultManager.currentDirectoryPath;
        standardized = [cwd stringByAppendingPathComponent:standardized]
                           .stringByStandardizingPath;
    }
    return standardized.UTF8String;
}

// Expand a path: a directory contributes all its *.genshinsheet files. All
// results are absolute.
void collect_sheets(const std::string& path, std::vector<std::string>& out) {
    NSString* ns = [NSString stringWithUTF8String:path.c_str()];
    BOOL is_dir = NO;
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:ns isDirectory:&is_dir]) {
        out.push_back(absolute_path(ns));  // let the parser report the error
        return;
    }
    if (!is_dir) {
        out.push_back(absolute_path(ns));
        return;
    }

    NSArray<NSString*>* entries =
        [[fm contentsOfDirectoryAtPath:ns error:nil]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString* entry in entries) {
        if ([entry.pathExtension isEqualToString:@"genshinsheet"]) {
            out.push_back(absolute_path([ns stringByAppendingPathComponent:entry]));
        }
    }
}

}  // namespace

// Owns the playlist of sheet paths and swaps songs into the shared
// PlaybackController on demand. Parsing is lazy (per load) so a big folder
// costs nothing until a song is selected.
@interface SongQueue : NSObject <PlayerQueueDelegate>
- (instancetype)initWithPaths:(std::vector<std::string>)paths
                     playback:(PlaybackController*)playback;
// Load index 0 eagerly so the HUD opens on a real song; returns NO if empty.
- (BOOL)primeFirst;
@end

@implementation SongQueue {
    std::vector<std::string> _paths;
    std::vector<std::string> _titles;
    std::vector<int> _bpms;
    NSInteger _current;
    PlaybackController* _playback;
}

- (instancetype)initWithPaths:(std::vector<std::string>)paths
                     playback:(PlaybackController*)playback {
    self = [super init];
    if (self != nil) {
        _paths = std::move(paths);
        _titles.assign(_paths.size(), std::string());
        _bpms.assign(_paths.size(), 0);
        _current = -1;
        _playback = playback;
        if (!_paths.empty()) {
            [self persistPaths];
        }
    }
    return self;
}

- (BOOL)primeFirst {
    return _paths.empty() ? NO : [self queueLoadIndex:0];
}

- (NSInteger)queueCount {
    return static_cast<NSInteger>(_paths.size());
}

- (NSInteger)queueCurrentIndex {
    return _current;
}

- (BOOL)queueLoadIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_paths.size())) {
        return NO;
    }
    try {
        GenshinSheetParser parser(_paths[index]);
        std::vector<Note> notes = parser.translate();
        if (notes.empty()) {
            std::cerr << "No notes in " << _paths[index] << '\n';
            return NO;
        }
        _titles[index] = parser.song_metadata().title;
        _bpms[index] = parser.song_metadata().bpm;
        _playback->set_notes(std::move(notes));
        _current = index;
        return YES;
    } catch (const std::exception& error) {
        std::cerr << "Failed to load " << _paths[index] << ": "
                  << error.what() << '\n';
        return NO;
    }
}

- (NSString*)queueTitleAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_paths.size())) {
        return @"Untitled";
    }
    const std::string& t = _titles[index];
    if (!t.empty()) {
        return [NSString stringWithUTF8String:t.c_str()];
    }
    NSString* path = [NSString stringWithUTF8String:_paths[index].c_str()];
    NSString* name = path.lastPathComponent.stringByDeletingPathExtension;
    return name.length > 0 ? name : @"Untitled";
}

- (NSInteger)queueAddPaths:(NSArray<NSString*>*)paths {
    NSInteger added = 0;
    for (NSString* path in paths) {
        std::vector<std::string> sheets;
        collect_sheets(path.UTF8String, sheets);
        for (std::string& sheet : sheets) {
            _paths.push_back(std::move(sheet));
            _titles.emplace_back();
            _bpms.push_back(0);
            ++added;
        }
    }
    if (added > 0) {
        [self persistPaths];
    }
    return added;
}

// Persist the playlist so it reloads on next launch (local hud-settings.json).
- (void)persistPaths {
    settings::set_string_array("playlist", _paths);
}

- (NSInteger)queueBpmAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_bpms.size())) {
        return 0;
    }
    return _bpms[index];
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        try {
            bool show_hud = true;
            std::vector<std::string> inputs;

            for (int i = 1; i < argc; ++i) {
                const std::string arg = argv[i];
                if (arg == "--no-hud") {
                    show_hud = false;
                } else {
                    inputs.push_back(arg);
                }
            }

            if (inputs.empty() && !show_hud) {
                std::cerr << "Usage: ./macauto.out [--no-hud] "
                             "[<sheet.genshinsheet | folder> ...]\n"
                             "  HUD mode (default): launch with no args and "
                             "open songs from the HUD.\n"
                             "  --no-hud: requires at least one sheet path.\n";
                return 1;
            }

            std::vector<std::string> sheets;
            for (const std::string& in : inputs) {
                collect_sheets(in, sheets);
            }
            if (!inputs.empty() && sheets.empty()) {
                std::cerr << "No .genshinsheet files found\n";
                return 1;
            }

            // No paths given → restore the last session's playlist, dropping
            // any files that have since disappeared.
            if (inputs.empty()) {
                NSFileManager* fm = NSFileManager.defaultManager;
                for (const std::string& p : settings::get_string_array("playlist")) {
                    NSString* ns = [NSString stringWithUTF8String:p.c_str()];
                    if (ns != nil && [fm fileExistsAtPath:ns]) {
                        sheets.push_back(p);
                    }
                }
            }

            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

            // Posting keystrokes to Genshin (CGEventPostToPid) is gated by the
            // Accessibility permission of THIS process. A terminal run inherits
            // the terminal's grant; otherwise key events are silently dropped.
            ensure_accessibility_trust();

            Genshin genshin;
            genshin.locate_application();
            genshin.activate_application();

            Keyboard keyboard;
            PlaybackController playback({}, keyboard);

            SongQueue* queue = [[SongQueue alloc] initWithPaths:sheets
                                                       playback:&playback];

            if (show_hud) {
                PlayerWindowController* controller = [[PlayerWindowController alloc]
                    initWithPlayback:&playback
                             genshin:&genshin
                            keyboard:&keyboard
                               title:@"No song selected"
                                 bpm:0];
                controller.queueDelegate = queue;
                if (!sheets.empty()) {
                    [controller loadQueueIndex:0 autoplay:NO];
                }
                // User presses play (with count-in) when ready.
            } else {
                if (![queue primeFirst]) {
                    throw std::runtime_error("Could not load any sheet");
                }
                playback.play();
            }

            [NSApp run];
            playback.stop();
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    return 0;
}
