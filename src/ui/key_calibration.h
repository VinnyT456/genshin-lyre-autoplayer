#pragma once

#import <AppKit/AppKit.h>

// Two-click key calibration laid over the Genshin window: click the center of
// Q (top-left button), then M (bottom-right button); the full 7×3 grid is
// derived from those and shown for review, where any ring can be dragged,
// resized (scroll, +/−) or nudged (arrows) on its own before saving. Clicks
// land on this layer, never the game. Enter saves, R redoes, Esc cancels.
// adjusting:YES skips the clicks and starts from the current layout.
@interface KeyCalibrationController : NSWindowController
- (void)beginOverGameFrame:(NSRect)gameFrame
                 adjusting:(BOOL)adjusting
                completion:(void (^)(BOOL saved))completion;
@end
