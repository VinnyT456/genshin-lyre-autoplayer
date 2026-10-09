#pragma once

#import <AppKit/AppKit.h>

class PlaybackController;

// Floating "note highway": the loaded song's notes fall down 21 pitch-ordered
// lanes toward a hit line above a mini lyre keyboard. Follows autoplay,
// song-speed practice (real time, including the count-in) and wait-for-input
// practice (glides to the note being waited on). Scroll over it to change how
// far ahead it shows.
@interface NoteHighwayController : NSWindowController
- (instancetype)initWithPlayback:(PlaybackController*)playback;
// Re-read localized strings (window title, empty state).
- (void)reloadStrings;
@end
