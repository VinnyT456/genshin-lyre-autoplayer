#pragma once

#import <AppKit/AppKit.h>

class Genshin;
class Keyboard;
class PlaybackController;

// Supplies the HUD with a playlist so its prev/next buttons can swap songs.
// Implemented in main.mm over the parsed sheet list.
@protocol PlayerQueueDelegate <NSObject>
- (NSInteger)queueCount;
- (NSInteger)queueCurrentIndex;
// Load the song at index into the shared PlaybackController; returns NO on
// failure (bad file, empty sheet). On success the HUD reads the new title/bpm
// via queueTitleAtIndex:/queueBpmAtIndex:.
- (BOOL)queueLoadIndex:(NSInteger)index;
- (NSString*)queueTitleAtIndex:(NSInteger)index;
- (NSInteger)queueBpmAtIndex:(NSInteger)index;
// Append .genshinsheet files or folders; returns number of songs added.
- (NSInteger)queueAddPaths:(NSArray<NSString*>*)paths;
@end

@interface PlayerWindowController : NSWindowController
- (instancetype)initWithPlayback:(PlaybackController*)playback
                         genshin:(Genshin*)genshin
                        keyboard:(Keyboard*)keyboard
                           title:(NSString*)title
                             bpm:(NSInteger)bpm;
// Optional playlist support. When set (count > 1) the HUD shows prev/next.
@property(nonatomic, weak) id<PlayerQueueDelegate> queueDelegate;
- (void)reloadQueueMetadata;
- (void)loadQueueIndex:(NSInteger)index autoplay:(BOOL)autoplay;
- (void)hideHud;
@end
