#import "key_layout.h"

#include <algorithm>
#include <cmath>

#include <nlohmann/json.hpp>

#include "lyre_key_map.h"
#include "settings.h"

namespace {

constexpr const char* kSettingCalibration = "key_calibration";

// Button radius relative to the spacing between neighbouring buttons in a row,
// taken from the hand-measured map (47 pt radius, 148 pt spacing).
constexpr double kRadiusToColumnSpacing = 47.0 / 148.0;

KeyLayout layout_from_header() {
    KeyLayout layout;
    layout.ready = lyre_key_map_complete();
    if (!layout.ready) {
        return layout;
    }
    for (const LyreKeySpot& spot : kLyreKeyMap) {
        const LyreKeyRelative rel = lyre_key_relative(spot);
        layout.keys[static_cast<std::size_t>(spot.key)] = {rel.u, rel.v, rel.radius};
    }
    return layout;
}

KeyLayout load_layout() {
    try {
        const nlohmann::json saved =
            nlohmann::json::parse(settings::get_json(kSettingCalibration, "{}"));
        // Per-key layout: 21 [u, v, radius] triples.
        if (saved.is_object() && saved.contains("keys") && saved["keys"].is_array() &&
            saved["keys"].size() == 21) {
            KeyLayout layout;
            for (std::size_t k = 0; k < 21; ++k) {
                const auto& key = saved["keys"][k];
                layout.keys[k] = {key.at(0).get<double>(), key.at(1).get<double>(),
                                  key.at(2).get<double>()};
            }
            layout.ready = true;
            layout.calibrated = true;
            return layout;
        }
        if (saved.is_object() && saved.contains("qu") && saved.contains("qv") &&
            saved.contains("mu") && saved.contains("mv")) {
            KeyLayout layout = key_layout_from_corners(
                saved["qu"].get<double>(), saved["qv"].get<double>(),
                saved["mu"].get<double>(), saved["mv"].get<double>());
            layout.calibrated = true;
            return layout;
        }
    } catch (...) {
        // Corrupt calibration: fall back to the hand-measured map.
    }
    return layout_from_header();
}

KeyLayout& cache() {
    static KeyLayout layout = load_layout();
    return layout;
}

}  // namespace

const KeyLayout& current_key_layout() {
    return cache();
}

KeyLayout key_layout_from_corners(double qu, double qv, double mu, double mv) {
    KeyLayout layout;
    const double du = (mu - qu) / 6.0;   // column step (7 columns)
    const double dv = (mv - qv) / 2.0;   // row step (3 rows)
    if (std::abs(du) < 1e-4 || std::abs(dv) < 1e-4) {
        return layout;   // the two clicks were on top of each other
    }
    const double radius = std::abs(du) * kRadiusToColumnSpacing;
    for (int k = 0; k < 21; ++k) {
        const int row = k / 7;   // 0 = top row (Q…U)
        const int col = k % 7;
        layout.keys[static_cast<std::size_t>(k)] = {qu + col * du, qv + row * dv, radius};
    }
    layout.ready = true;
    return layout;
}

void save_key_layout(const std::array<KeyPlacement, 21>& keys) {
    nlohmann::json list = nlohmann::json::array();
    for (const KeyPlacement& key : keys) {
        list.push_back({key.u, key.v, key.radius});
    }
    settings::set_json(kSettingCalibration, nlohmann::json{{"keys", list}}.dump());
    cache() = load_layout();
}

void clear_key_calibration() {
    settings::set_json(kSettingCalibration, "{}");
    cache() = load_layout();
}

NSRect key_picture_rect(NSWindow* window, NSRect bounds) {
    NSScreen* screen = window.screen;
    const bool fullScreen = screen != nil && NSEqualRects(window.frame, screen.frame);
    const CGFloat titleBar = fullScreen ? 0.0 : kLyreTitleBarHeight;
    return NSMakeRect(0, titleBar, NSWidth(bounds), std::max<CGFloat>(1.0, NSHeight(bounds) - titleBar));
}
