#pragma once

#import <AppKit/AppKit.h>

#include <array>

// Where the 21 lyre buttons are inside Genshin's game picture (the window
// minus its title bar), as fractions so it works at any window size.
//
// Source of truth, in order:
//   1. A click calibration (HUD → Key highlights → Calibrate keys), saved in
//      hud-settings.json — two clicks on Q and M define the whole 7×3 grid,
//      and any key can then be dragged / resized on its own.
//   2. The hand-measured map in lyre_key_map.h.

struct KeyPlacement {
    double u = 0.0;       // center x, fraction of picture width
    double v = 0.0;       // center y, fraction of picture height (from the top)
    double radius = 0.0;  // fraction of picture width
};

struct KeyLayout {
    bool ready = false;        // usable at all
    bool calibrated = false;   // came from a click calibration
    std::array<KeyPlacement, 21> keys{};   // Key-enum order (Q…U, A…J, Z…M)
};

// Current layout (cached; cheap to call every frame).
const KeyLayout& current_key_layout();

// Build a full grid from the centers of Q (top-left) and M (bottom-right),
// given in picture fractions.
KeyLayout key_layout_from_corners(double qu, double qv, double mu, double mv);

// Save all 21 keys as placed (after per-key adjustment).
void save_key_layout(const std::array<KeyPlacement, 21>& keys);
void clear_key_calibration();

// The game picture inside a window that exactly covers the Genshin window:
// excludes the title bar unless the window fills its display (full screen).
// Returned in the view's flipped (top-left) coordinates.
NSRect key_picture_rect(NSWindow* window, NSRect bounds);
