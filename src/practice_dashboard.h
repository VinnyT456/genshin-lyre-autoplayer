#pragma once

#import <AppKit/AppKit.h>

class PlaybackController;

@interface PracticeDashboardController : NSWindowController
- (instancetype)initWithPlayback:(PlaybackController*)playback;
- (void)setSongKey:(NSString*)songKey;
- (void)refresh;
@end
