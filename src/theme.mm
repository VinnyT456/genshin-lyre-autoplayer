#include "theme.h"

namespace themes {
namespace {

NSColor* srgb(double r, double g, double b, double a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

std::vector<Theme> make_all() {
    std::vector<Theme> list;

    // Naberius (default) — reference: orange-gold hair under a white hood, gold
    // halo rings, amber eyes. The accent is that halo gold — warmer and more
    // orange than a flat yellow — over a deep warm-brown black, with hood-white
    // ink.
    list.push_back(Theme{
        "naberius", "Naberius (radiant gold)", "那贝流士（辉耀金）",
        srgb(1.00, 0.72, 0.25, 1.0),   // accent  (halo gold, warm orange lean)
        srgb(1.00, 0.72, 0.25, 0.5),   // accent_dim
        srgb(1.00, 0.99, 0.96, 1.0),   // ink     (hood white, near-neutral)
        srgb(1.00, 0.98, 0.94, 0.66),  // ink_soft
        srgb(1.00, 0.96, 0.89, 0.32),  // ink_faint
        srgb(0.05, 0.04, 0.03, 0.62),  // panel_tint (near-black, faint warm lift)
        srgb(1.00, 0.72, 0.25, 0.26),  // border  (gold hairline)
        srgb(0.16, 0.10, 0.01, 1.0),   // on_accent (dark warm text on gold)
        0.5,    // key_radius   — full circles: halo rings
        10.0,   // glow_spread  — very wide, holy bloom
        0.40,   // glow_strength
        0.75,   // key_stroke   — soft, barely-there edge
        0.0,    // edge_tint    — neutral
    });

    // Ronova — the "Death" Archon. Reference: glowing scarlet eye-motifs and
    // crimson wing-crests over an oxblood/near-black gown, with silver-white
    // hair. The accent is the *glow* red (hot, slightly orange-leaning so it
    // reads as light, not paint); the ground is a deep oxblood-black and the
    // ink carries a faint rose cast picked up from her hair in that red light.
    list.push_back(Theme{
        "ronova", "Ronova (crimson)", "洛诺瓦（绯红）",
        srgb(0.92, 0.15, 0.20, 1.0),   // accent  (glowing scarlet)
        srgb(0.92, 0.15, 0.20, 0.5),   // accent_dim
        srgb(0.95, 0.95, 0.96, 1.0),   // ink     (cool silver-white)
        srgb(0.94, 0.92, 0.94, 0.58),  // ink_soft
        srgb(0.92, 0.88, 0.91, 0.32),  // ink_faint
        srgb(0.06, 0.02, 0.03, 0.68),  // panel_tint (black, faint oxblood cast)
        srgb(0.92, 0.15, 0.20, 0.26),  // border  (scarlet hairline)
        srgb(1.00, 0.95, 0.95, 1.0),   // on_accent (near-white on scarlet)
        0.06,   // key_radius   — near-square, blade-sharp corners
        2.0,    // glow_spread  — very tight, hot flare
        0.55,   // glow_strength — fierce
        1.2,    // key_stroke
        0.15,   // edge_tint    — faint scarlet edge
    });

    // Asmoday — reworked toward the "armoured knight". Reference: white raiment
    // over navy-steel shoulder plating, gold filigree trim, amber eyes and a
    // rust gauntlet against a cold sky. The accent is the *gold trim* (a clean
    // warm gold, distinct from Naberius's orange halo and Istaroth's dull
    // brass), on a cold steel-blue ground with pure-white ink. Keys are the most
    // squared and heavily-plated of any theme — armour, not glow.
    list.push_back(Theme{
        "asmoday", "Asmoday (steel & gold)", "阿斯莫代（钢与金）",
        srgb(0.93, 0.78, 0.42, 1.0),   // accent  (clean gold trim)
        srgb(0.93, 0.78, 0.42, 0.5),   // accent_dim
        srgb(0.99, 1.00, 1.00, 1.0),   // ink     (raiment white, cool)
        srgb(0.97, 0.99, 1.00, 0.66),  // ink_soft
        srgb(0.93, 0.96, 1.00, 0.34),  // ink_faint
        srgb(0.10, 0.14, 0.22, 0.60),  // panel_tint (cold steel-blue)
        srgb(0.93, 0.78, 0.42, 0.30),  // border  (gold trim, stronger)
        srgb(0.10, 0.09, 0.03, 1.0),   // on_accent (dark on gold)
        0.16,   // key_radius   — squared plating
        3.5,    // glow_spread  — contained, like a lit rivet
        0.30,   // glow_strength
        1.8,    // key_stroke   — thick armour edge, the loudest of any theme
        0.55,   // edge_tint    — gold-trimmed plating, clearly visible
    });

    // Istaroth — the Time/Wind archon. Reference: platinum-white hair and a deep
    // midnight-navy robe, hung with brass-gold clock hands and halo rings over a
    // starfield. The accent is that aged brass (duller and greener than
    // Naberius's radiant halo gold, so the two golds don't read as the same
    // theme), the ground is midnight navy, and the ink is cool platinum.
    list.push_back(Theme{
        "istaroth", "Istaroth (brass & midnight)", "伊斯塔露（黄铜与午夜）",
        srgb(0.87, 0.71, 0.36, 1.0),   // accent  (aged brass, clock hands)
        srgb(0.87, 0.71, 0.36, 0.5),   // accent_dim
        srgb(0.96, 0.96, 0.98, 1.0),   // ink     (platinum white, cool)
        srgb(0.94, 0.95, 0.99, 0.62),  // ink_soft
        srgb(0.90, 0.92, 0.98, 0.34),  // ink_faint
        srgb(0.04, 0.05, 0.12, 0.66),  // panel_tint (midnight navy)
        srgb(0.87, 0.71, 0.36, 0.26),  // border  (brass hairline)
        srgb(0.10, 0.09, 0.04, 1.0),   // on_accent (dark text on brass)
        0.34,   // key_radius   — clockface curves
        9.0,    // glow_spread  — wide, faint starlight shimmer
        0.16,   // glow_strength — barely there
        0.6,    // key_stroke   — finest gold filigree
        0.25,   // edge_tint    — brass filigree edge
    });

    return list;
}

std::vector<Theme>& registry() {
    static std::vector<Theme> list = make_all();
    return list;
}

std::size_t g_current_index = 0;

}  // namespace

const std::vector<Theme>& all() {
    return registry();
}

const Theme& current() {
    return registry()[g_current_index];
}

void set_current(const std::string& id) {
    const auto& list = registry();
    for (std::size_t i = 0; i < list.size(); ++i) {
        if (list[i].id == id) {
            g_current_index = i;
            return;
        }
    }
}

}  // namespace themes
