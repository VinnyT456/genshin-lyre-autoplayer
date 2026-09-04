#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include <iostream>
#include <algorithm>
#include <stdexcept>
#include <string>
#include <utility>
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

bool is_supported_song_file(NSString* path) {
    NSString* extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"genshinsheet"] ||
           [extension isEqualToString:@"mid"] ||
           [extension isEqualToString:@"midi"];
}

// Expand a path: a directory contributes all supported song files. All
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
        if (is_supported_song_file(entry)) {
            out.push_back(absolute_path([ns stringByAppendingPathComponent:entry]));
        }
    }
}

struct PlaylistEntry {
    std::vector<std::string> sources;
};

// Files with the same name in the same folder are alternate representations
// of one song (for example, Song.genshinsheet and Song.mid). Keeping the
// directory in the key avoids merging unrelated songs that merely share a
// title in different folders.
std::string playlist_group_key(const std::string& path) {
    NSString* ns = [NSString stringWithUTF8String:path.c_str()];
    NSString* directory = ns.stringByDeletingLastPathComponent.lowercaseString;
    NSString* stem = [ns.lastPathComponent stringByDeletingPathExtension].lowercaseString;
    return std::string(directory.UTF8String ?: "") + "\n" +
           std::string(stem.UTF8String ?: "");
}

int source_priority(const std::string& path) {
    NSString* extension = [NSString stringWithUTF8String:path.c_str()]
                              .pathExtension.lowercaseString;
    if ([extension isEqualToString:@"genshinsheet"]) {
        return 0;
    }
    return 1;
}

void add_playlist_path(std::vector<PlaylistEntry>& songs, std::string path) {
    const std::string key = playlist_group_key(path);
    for (PlaylistEntry& song : songs) {
        if (playlist_group_key(song.sources.front()) != key) {
            continue;
        }
        if (std::find(song.sources.begin(), song.sources.end(), path) == song.sources.end()) {
            song.sources.push_back(std::move(path));
            std::stable_sort(song.sources.begin(), song.sources.end(),
                             [](const std::string& left, const std::string& right) {
                                 const int left_priority = source_priority(left);
                                 const int right_priority = source_priority(right);
                                 return left_priority != right_priority
                                     ? left_priority < right_priority
                                     : left < right;
                             });
        }
        return;
    }
    songs.push_back(PlaylistEntry{{std::move(path)}});
}

std::vector<std::string> flatten_playlist(const std::vector<PlaylistEntry>& songs) {
    std::vector<std::string> paths;
    for (const PlaylistEntry& song : songs) {
        paths.insert(paths.end(), song.sources.begin(), song.sources.end());
    }
    return paths;
}

}  // namespace

// Owns the playlist of song paths and swaps songs into the shared
// PlaybackController on demand. Parsing is lazy (per load) so a big folder
// costs nothing until a song is selected.
@interface SongQueue : NSObject <PlayerQueueDelegate>
- (instancetype)initWithPaths:(std::vector<std::string>)paths
                     playback:(PlaybackController*)playback;
// Load index 0 eagerly so the HUD opens on a real song; returns NO if empty.
- (BOOL)primeFirst;
@end

@implementation SongQueue {
    std::vector<PlaylistEntry> _songs;
    std::vector<size_t> _selected_sources;
    std::vector<std::string> _titles;
    std::vector<int> _bpms;
    NSInteger _current;
    PlaybackController* _playback;
}

- (instancetype)initWithPaths:(std::vector<std::string>)paths
                     playback:(PlaybackController*)playback {
    self = [super init];
    if (self != nil) {
        for (std::string& path : paths) {
            add_playlist_path(_songs, std::move(path));
        }
        _selected_sources.assign(_songs.size(), 0);
        _titles.assign(_songs.size(), std::string());
        _bpms.assign(_songs.size(), 0);
        _current = -1;
        _playback = playback;
        if (!_songs.empty()) {
            [self persistPaths];
        }
    }
    return self;
}

- (BOOL)primeFirst {
    return _songs.empty() ? NO : [self queueLoadIndex:0];
}

- (NSInteger)queueCount {
    return static_cast<NSInteger>(_songs.size());
}

- (NSInteger)queueCurrentIndex {
    return _current;
}

- (BOOL)queueLoadIndex:(NSInteger)index sourceIndex:(NSInteger)sourceIndex {
    if (index < 0 || index >= static_cast<NSInteger>(_songs.size())) {
        return NO;
    }
    const PlaylistEntry& song = _songs[static_cast<size_t>(index)];
    if (song.sources.empty()) {
        return NO;
    }
    const bool requested_source =
        sourceIndex >= 0 && sourceIndex < static_cast<NSInteger>(song.sources.size());
    size_t preferred_source = requested_source
        ? static_cast<size_t>(sourceIndex)
        : _selected_sources[static_cast<size_t>(index)];
    if (preferred_source >= song.sources.size()) {
        preferred_source = 0;
    }

    const size_t attempts = requested_source ? 1 : song.sources.size();
    for (size_t attempt = 0; attempt < attempts; ++attempt) {
        const size_t candidate = (preferred_source + attempt) % song.sources.size();
        try {
            GenshinSheetParser parser(song.sources[candidate]);
            std::vector<Note> notes = parser.translate();
            if (notes.empty()) {
                throw std::runtime_error("song contains no playable notes");
            }
            _selected_sources[static_cast<size_t>(index)] = candidate;
            _titles[static_cast<size_t>(index)] = parser.song_metadata().title;
            _bpms[static_cast<size_t>(index)] = parser.song_metadata().bpm;
            _playback->set_notes(std::move(notes));
            _current = index;
            return YES;
        } catch (const std::exception& error) {
            std::cerr << "Failed to load " << song.sources[candidate] << ": "
                      << error.what() << '\n';
        }
    }
    return NO;
}

- (BOOL)queueLoadIndex:(NSInteger)index {
    return [self queueLoadIndex:index sourceIndex:-1];
}

- (NSString*)queueTitleAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_songs.size())) {
        return @"Untitled";
    }
    const std::string& t = _titles[index];
    if (!t.empty()) {
        return [NSString stringWithUTF8String:t.c_str()];
    }
    const PlaylistEntry& song = _songs[static_cast<size_t>(index)];
    NSString* path = song.sources.empty()
        ? @""
        : [NSString stringWithUTF8String:song.sources.front().c_str()];
    NSString* name = path.lastPathComponent.stringByDeletingPathExtension;
    return name.length > 0 ? name : @"Untitled";
}

- (NSInteger)queueAddPaths:(NSArray<NSString*>*)paths {
    NSInteger added = 0;
    for (NSString* path in paths) {
        std::vector<std::string> sheets;
        collect_sheets(path.UTF8String, sheets);
        for (std::string& sheet : sheets) {
            const size_t previous_count = _songs.size();
            add_playlist_path(_songs, std::move(sheet));
            if (_songs.size() == previous_count) {
                continue;
            }
            _selected_sources.push_back(0);
            _titles.emplace_back();
            _bpms.push_back(0);
            ++added;
        }
    }
    if (added > 0 || paths.count > 0) {
        [self persistPaths];
    }
    return added;
}

// Persist the playlist so it reloads on next launch (local hud-settings.json).
- (void)persistPaths {
    settings::set_string_array("playlist", flatten_playlist(_songs));
}

- (NSInteger)queueBpmAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_bpms.size())) {
        return 0;
    }
    return _bpms[index];
}

- (NSInteger)queueSourceCountAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_songs.size())) {
        return 0;
    }
    return static_cast<NSInteger>(_songs[static_cast<size_t>(index)].sources.size());
}

- (NSString*)queueSourceTitleAtIndex:(NSInteger)index sourceIndex:(NSInteger)sourceIndex {
    if (index < 0 || index >= static_cast<NSInteger>(_songs.size())) {
        return @"";
    }
    const PlaylistEntry& song = _songs[static_cast<size_t>(index)];
    if (sourceIndex < 0 || sourceIndex >= static_cast<NSInteger>(song.sources.size())) {
        return @"";
    }
    NSString* path = [NSString stringWithUTF8String:
        song.sources[static_cast<size_t>(sourceIndex)].c_str()];
    return path.lastPathComponent ?: @"";
}

- (NSInteger)queueSelectedSourceIndexAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_selected_sources.size())) {
        return 0;
    }
    return static_cast<NSInteger>(_selected_sources[static_cast<size_t>(index)]);
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
                             "[<sheet.genshinsheet | song.mid | folder> ...]\n"
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
                std::cerr << "No playable song files found\n";
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
