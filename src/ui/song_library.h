#pragma once

#import <AppKit/AppKit.h>

#import "PlayerWindow.h"

// What the library window asks of the HUD. Reads go straight to the queue;
// anything that changes playback or needs a confirmation goes through here.
@protocol SongLibraryHost <NSObject>
- (id<PlayerQueueDelegate>)queueDelegate;
- (void)libraryLoadSong:(NSInteger)index source:(NSInteger)source;
- (void)libraryRemoveSong:(NSInteger)index;   // asks first
- (void)libraryClearSongs;                    // asks first
- (void)libraryAddSongs;                      // file picker
- (void)libraryQueueChanged;                  // favorites / order changed
@end

// Themed playlist window in the style of the settings window: a sidebar of
// views (All songs / Favorites / Recently played), a search field, and one
// row per song with favorite, reorder, version, and remove controls.
@interface SongLibraryWindowController : NSWindowController
- (instancetype)initWithHost:(id<SongLibraryHost>)host;
// Rebuild from the queue (songs, current song, language, or theme changed).
- (void)reload;
@end
