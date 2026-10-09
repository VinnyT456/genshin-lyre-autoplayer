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
- (BOOL)queueLoadIndex:(NSInteger)index sourceIndex:(NSInteger)sourceIndex;
- (NSString*)queueTitleAtIndex:(NSInteger)index;
- (NSInteger)queueBpmAtIndex:(NSInteger)index;
// The song's real title (from its file metadata) without loading it into
// playback; parsed once and cached. Used to match practice history by title.
- (NSString*)queueResolvedTitleAtIndex:(NSInteger)index;
// A matching .genshinsheet/.mid pair is one playlist song with alternate
// sources shown in its popup submenu.
- (NSInteger)queueSourceCountAtIndex:(NSInteger)index;
- (NSString*)queueSourceTitleAtIndex:(NSInteger)index sourceIndex:(NSInteger)sourceIndex;
- (NSInteger)queueSelectedSourceIndexAtIndex:(NSInteger)index;
// Append supported song files or folders; returns number of songs added.
- (NSInteger)queueAddPaths:(NSArray<NSString*>*)paths;
// Queue organization controls exposed by the playlist popup.
- (BOOL)queueMoveCurrentBy:(NSInteger)offset;
// Move any song to a new position (the current song keeps playing).
- (BOOL)queueMoveIndex:(NSInteger)from to:(NSInteger)to;
- (BOOL)queueRemoveIndex:(NSInteger)index;
- (void)queueClear;
- (BOOL)queueIsFavoriteAtIndex:(NSInteger)index;
- (void)queueToggleFavoriteAtIndex:(NSInteger)index;
- (NSArray<NSNumber*>*)queueRecentIndexes;
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
