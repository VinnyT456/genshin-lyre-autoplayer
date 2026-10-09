#pragma once

#import <AppKit/AppKit.h>

class PlaybackController;

// Transparent, click-through window laid exactly over the Genshin window that
// highlights the lyre buttons to play, using the positions in lyre_key_map.h.
//
//   Wait-for-input practice: the target key(s) stay solid until played.
//   Song-speed practice: a key turns solid when its hit window opens and fades
//   to transparent as the window closes (fully faded = missed).
//
// Draws nothing until the key map has been filled in.
@interface KeyOverlayController : NSWindowController
- (instancetype)initWithPlayback:(PlaybackController*)playback;
// Called by the HUD's focus tracker. gameFrame is the Genshin window in
// AppKit screen coordinates; visible = whether the overlay should show now.
- (void)updateWithGameFrame:(NSRect)gameFrame visible:(BOOL)visible;
// Outline every mapped key (with its letter) to check alignment.
@property(nonatomic) BOOL preview;
@end

// True once lyre_key_map.h has a reference size and a radius for every key.
bool key_overlay_map_ready();
