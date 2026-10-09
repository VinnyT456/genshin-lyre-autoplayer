#pragma once

// Where each lyre key sits on Genshin's in-game lyre, for highlighting the
// keys directly over the game window.
//
// HOW IT'S MEASURED
//   Key positions are SCREEN coordinates (points, measured from the top-left
//   of the whole screen) taken with Genshin windowed. Because the window can
//   later be moved or resized, the map also records where that window was on
//   screen at the time (kLyreMeasuredWindow, title bar included). The overlay
//   converts each key to a position inside the game picture (the window minus
//   its title bar) and maps that onto wherever the game window is now.
//
// EASIER: HUD gear → Key highlights → "Calibrate keys…" (click Q, then M).
// A saved click calibration takes priority over this file; this map is the
// built-in fallback. A key with radius 0 is "not set yet".

#include <array>
#include <cstddef>

#include "key.h"

struct LyreKeySpot {
    Key key;
    const char* note;   // pitch the key plays, for reference
    double x;           // button center, screen points from the left
    double y;           // button center, screen points from the top
    double radius;      // button radius, points
};

// Genshin's window on screen when the keys were measured: top-left x, y and
// size in points, title bar included. All zero = not recorded yet.
struct LyreWindowRect {
    double x, y, width, height;
};
constexpr LyreWindowRect kLyreMeasuredWindow = {76.0, 33.0, 1361.0, 879.0};

// Height of a standard macOS title bar on a windowed game. Excluded so keys
// are positioned relative to the game picture itself.
constexpr double kLyreTitleBarHeight = 28.0;

// Same order as the Key enum: top row (high) → bottom row (low).
constexpr std::array<LyreKeySpot, 21> kLyreKeyMap = {{
    // ---- Top row: C5 – B5 -------------------------------------------------
    {Key::Q, "C5", 312, 552, 47},
    {Key::W, "D5", 460, 552, 47},
    {Key::E, "E5", 608, 552, 47},
    {Key::R, "F5", 756, 552, 47},
    {Key::T, "G5", 904, 552, 47},
    {Key::Y, "A5", 1052, 552, 47},
    {Key::U, "B5", 1200, 552, 47},

    // ---- Middle row: C4 – B4 ----------------------------------------------
    {Key::A, "C4", 312, 672, 47},
    {Key::S, "D4", 460, 672, 47},
    {Key::D, "E4", 608, 672, 47},
    {Key::F, "F4", 756, 672, 47},
    {Key::G, "G4", 904, 672, 47},
    {Key::H, "A4", 1052, 672, 47},
    {Key::J, "B4", 1200, 672, 47},

    // ---- Bottom row: C3 – B3 ----------------------------------------------
    {Key::Z, "C3", 312, 792, 47},
    {Key::X, "D3", 460, 792, 47},
    {Key::C, "E3", 608, 792, 47},
    {Key::V, "F3", 756, 792, 47},
    {Key::B, "G3", 904, 792, 47},
    {Key::N, "A3", 1052, 792, 47},
    {Key::M, "B3", 1200, 792, 47},
}};

// The spot for a key (entries are in Key-enum order).
constexpr const LyreKeySpot& lyre_key_spot(Key key) {
    return kLyreKeyMap[static_cast<std::size_t>(key)];
}

// True once the reference size and every key's radius have been filled in.
constexpr bool lyre_key_map_complete() {
    if (kLyreMeasuredWindow.width <= 0.0 ||
        kLyreMeasuredWindow.height <= kLyreTitleBarHeight) {
        return false;
    }
    for (const LyreKeySpot& spot : kLyreKeyMap) {
        if (spot.radius <= 0.0) {
            return false;
        }
    }
    return true;
}

// Guard against the table drifting out of Key-enum order.
static_assert([] {
    for (std::size_t i = 0; i < kLyreKeyMap.size(); ++i) {
        if (static_cast<std::size_t>(kLyreKeyMap[i].key) != i) {
            return false;
        }
    }
    return true;
}(), "kLyreKeyMap must list keys in Key-enum order (Q…U, A…J, Z…M)");

// A key's position inside the game picture, as fractions of the picture's
// width/height (u, v) and its radius as a fraction of the picture's width.
struct LyreKeyRelative {
    double u, v, radius;
};

constexpr LyreKeyRelative lyre_key_relative(const LyreKeySpot& spot) {
    const double pictureTop = kLyreMeasuredWindow.y + kLyreTitleBarHeight;
    const double pictureWidth = kLyreMeasuredWindow.width;
    const double pictureHeight = kLyreMeasuredWindow.height - kLyreTitleBarHeight;
    return {(spot.x - kLyreMeasuredWindow.x) / pictureWidth,
            (spot.y - pictureTop) / pictureHeight,
            spot.radius / pictureWidth};
}
