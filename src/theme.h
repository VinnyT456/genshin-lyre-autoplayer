#pragma once

#import <AppKit/AppKit.h>
#include <string>
#include <vector>

// A HUD color theme. Accent is the single highlight color; the ink shades are
// the text/foreground at three opacities; panel_tint and border style the
// translucent panel behind everything.
struct Theme {
    std::string id;      // stable key stored in settings
    std::string name;    // menu label (English)
    std::string name_zh; // menu label (Simplified Chinese)
    NSColor* accent;
    NSColor* accent_dim;
    NSColor* ink;
    NSColor* ink_soft;
    NSColor* ink_faint;
    NSColor* panel_tint;
    NSColor* border;
    // Text color drawn on top of an accent-filled key (dark for light accents).
    NSColor* on_accent;

    // --- Form, not just color. These let each theme borrow a shape cue from
    // its character so the themes differ at a glance, not only in hue.

    // Key corner radius as a fraction of the key size: low = angular/sharp,
    // high = round. (Ronova's crests are sharp; Naberius's halos are circles.)
    double key_radius;
    // How far the lit-key bloom spreads, in points at full brightness.
    double glow_spread;
    // Peak opacity of that bloom — a tight hard glow vs a wide soft one.
    double glow_strength;
    // Stroke width on idle keys: hairline filigree vs plated edges.
    double key_stroke;
    // How much the idle key edge is tinted toward the accent (0 = neutral ink,
    // 1 = full accent) — lets Asmoday's plating read as gold trim.
    double edge_tint;
};

namespace themes {

// All available themes, in menu order.
const std::vector<Theme>& all();

// The active theme.
const Theme& current();

// Switch by id; no-op if unknown. Persists nothing (caller stores the id).
void set_current(const std::string& id);

}  // namespace themes
