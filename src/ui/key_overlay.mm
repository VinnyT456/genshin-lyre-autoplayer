#import "key_overlay.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <vector>

#include "key_layout.h"
#include "playback_controller.h"
#include "theme.h"

namespace {

NSColor* rgba(double r, double g, double b, double a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:std::clamp(a, 0.0, 1.0)];
}

// Default look: accent glow + fill rimmed in the theme ink.
void draw_default_spot(const Theme& theme, NSPoint c, CGFloat r, double level) {
    const NSRect circle = NSMakeRect(c.x - r, c.y - r, r * 2.0, r * 2.0);
    [[theme.accent colorWithAlphaComponent:0.28 * level] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, -r * 0.22, -r * 0.22)] fill];
    [[theme.accent colorWithAlphaComponent:0.78 * level] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    NSBezierPath* rim = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, 1.0, 1.0)];
    rim.lineWidth = std::max(1.5, r * 0.08);
    [[theme.ink colorWithAlphaComponent:0.85 * level] setStroke];
    [rim stroke];
}

// ---- Ronova -----------------------------------------------------------------

// All Ronova shapes are authored in key-radius units around the key center
// (y down, flipped view) for the RIGHT side; the left side mirrors x.

NSAffineTransform* ronova_frame(NSPoint c, CGFloat r, bool mirror) {
    NSAffineTransform* t = [NSAffineTransform transform];
    [t translateXBy:c.x yBy:c.y];
    [t scaleXBy:(mirror ? -r : r) yBy:r];
    return t;
}

// Wing-crest: a slim flame-feather rising from the upper rim. A sharp lower
// spike points outward (her serrated feathers); the main blade climbs to a
// tip that hooks back inward. Stays inside the gaps between lyre buttons.
NSBezierPath* ronova_crest_path() {
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0.98, -0.06)];
    [p curveToPoint:NSMakePoint(1.96, -0.30)                         // lower spike
      controlPoint1:NSMakePoint(1.36, 0.04) controlPoint2:NSMakePoint(1.72, -0.10)];
    [p curveToPoint:NSMakePoint(1.52, -0.56)
      controlPoint1:NSMakePoint(1.76, -0.40) controlPoint2:NSMakePoint(1.62, -0.50)];
    [p curveToPoint:NSMakePoint(1.64, -1.46)                         // main tip
      controlPoint1:NSMakePoint(1.84, -0.80) controlPoint2:NSMakePoint(1.86, -1.22)];
    [p curveToPoint:NSMakePoint(1.30, -1.04)                         // hook back in
      controlPoint1:NSMakePoint(1.50, -1.42) controlPoint2:NSMakePoint(1.38, -1.22)];
    [p curveToPoint:NSMakePoint(0.70, -0.72)
      controlPoint1:NSMakePoint(1.14, -0.86) controlPoint2:NSMakePoint(0.90, -0.70)];
    [p closePath];
    return p;
}

// Slim slit cut clean through the blade (background shows through), running
// along it — the eye motif of her wings.
NSBezierPath* ronova_crest_eye_path() {
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(1.24, -0.60)];
    [p curveToPoint:NSMakePoint(1.62, -1.16)
      controlPoint1:NSMakePoint(1.48, -0.66) controlPoint2:NSMakePoint(1.62, -0.90)];
    [p curveToPoint:NSMakePoint(1.24, -0.60)
      controlPoint1:NSMakePoint(1.50, -1.00) controlPoint2:NSMakePoint(1.32, -0.80)];
    [p closePath];
    return p;
}

// Pointed loop (vesica) from the center out along +x, length L, half-width w.
NSBezierPath* ronova_loop(double L, double w) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0.0, 0.0)];
    [p curveToPoint:NSMakePoint(L, 0.0)
      controlPoint1:NSMakePoint(L * 0.25, -w) controlPoint2:NSMakePoint(L * 0.80, -w * 0.7)];
    [p curveToPoint:NSMakePoint(0.0, 0.0)
      controlPoint1:NSMakePoint(L * 0.80, w * 0.7) controlPoint2:NSMakePoint(L * 0.25, w)];
    [p closePath];
    return p;
}

NSBezierPath* in_frame(NSBezierPath* path, NSAffineTransform* frame, double rotateDeg) {
    NSBezierPath* copy = [path copy];
    if (rotateDeg != 0.0) {
        NSAffineTransform* rot = [NSAffineTransform transform];
        [rot rotateByDegrees:rotateDeg];
        [copy transformUsingAffineTransform:rot];
    }
    [copy transformUsingAffineTransform:frame];
    return copy;
}

// Ronova, after her splash art: a disc dressed like her gown (black into a
// crimson hem) covering the whole button, her silver hip-knot as the
// centerpiece, and two crimson wing-crests with almond eyes. Flat color and
// ink outlines; the whole emblem fades as one layer.
void draw_ronova_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    NSColor* ink = rgba(0.11, 0.01, 0.03, 1.0);
    NSColor* silver = rgba(0.87, 0.87, 0.89, 1.0);
    NSColor* silverShade = rgba(0.55, 0.55, 0.58, 1.0);
    const CGFloat line = std::max(1.0, r * 0.035);

    // ---- Wing-crests (behind the disc). They fold toward the rim as the
    //      highlight fades.
    const double fold = 0.6 + 0.4 * level;
    for (int side = 0; side < 2; ++side) {
        NSAffineTransform* frame = ronova_frame(c, r, side == 1);
        NSAffineTransform* folded = [NSAffineTransform transform];
        [folded translateXBy:0.85 yBy:-0.40];         // fold about the crest root
        [folded scaleBy:fold];
        [folded translateXBy:-0.85 yBy:0.40];
        [folded appendTransform:frame];

        // Back feather: the same crest swung up a little and darker, so each
        // wing reads as layered feathers rather than a single cut-out.
        NSAffineTransform* back = [NSAffineTransform transform];
        [back translateXBy:0.95 yBy:-0.30];
        [back rotateByDegrees:-15.0];
        [back scaleBy:0.92];
        [back translateXBy:-0.95 yBy:0.30];
        [back appendTransform:folded];
        NSBezierPath* backFeather = in_frame(ronova_crest_path(), back, 0);
        [rgba(0.30, 0.02, 0.06, 1.0) setFill];
        [backFeather fill];
        [ink setStroke];
        backFeather.lineWidth = line;
        [backFeather stroke];

        NSBezierPath* crest = in_frame(ronova_crest_path(), folded, 0);
        NSBezierPath* eye = in_frame(ronova_crest_eye_path(), folded, 0);
        [crest appendBezierPath:eye];
        crest.windingRule = NSWindingRuleEvenOdd;   // the slit is a real hole
        // Two-tone: lit scarlet along the inner edge, deep crimson outside.
        NSGradient* tone = [[NSGradient alloc] initWithColorsAndLocations:
            rgba(0.90, 0.13, 0.20, 1.0), 0.0,
            rgba(0.74, 0.06, 0.14, 1.0), 0.5,
            rgba(0.42, 0.02, 0.07, 1.0), 1.0, nil];
        const NSPoint inner = [folded transformPoint:NSMakePoint(1.00, -1.00)];
        const NSPoint outer = [folded transformPoint:NSMakePoint(1.90, -0.30)];
        [NSGraphicsContext saveGraphicsState];
        [crest addClip];
        [tone drawFromPoint:inner toPoint:outer
                    options:NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
        // Spine: a fine lit line along the blade (hidden where it crosses the slit).
        NSBezierPath* spine = [NSBezierPath bezierPath];
        [spine moveToPoint:NSMakePoint(0.92, -0.30)];
        [spine curveToPoint:NSMakePoint(1.62, -1.30)
              controlPoint1:NSMakePoint(1.40, -0.50) controlPoint2:NSMakePoint(1.70, -0.98)];
        [spine transformUsingAffineTransform:folded];
        spine.lineWidth = line * 0.7;
        spine.lineCapStyle = NSLineCapStyleRound;
        [rgba(1.0, 0.50, 0.50, 0.55) setStroke];
        [spine stroke];
        [NSGraphicsContext restoreGraphicsState];

        // A small red orb ringed in black, sitting in the slit.
        const NSPoint orb = [folded transformPoint:NSMakePoint(1.47, -0.86)];
        const CGFloat orbR = r * 0.06 * fold;
        [ink setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(orb.x - orbR * 1.35, orb.y - orbR * 1.35,
                                                           orbR * 2.7, orbR * 2.7)] fill];
        [rgba(0.95, 0.20, 0.22, 1.0) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(orb.x - orbR, orb.y - orbR,
                                                           orbR * 2.0, orbR * 2.0)] fill];

        [ink setStroke];
        crest.lineWidth = line;
        crest.lineJoinStyle = NSLineJoinStyleMiter;
        [crest stroke];
    }

    // ---- Disc over the whole button: black bodice into a crimson hem.
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* gown = [[NSGradient alloc] initWithColorsAndLocations:
        rgba(0.07, 0.03, 0.04, 1.0), 0.0,
        rgba(0.10, 0.03, 0.05, 1.0), 0.45,
        rgba(0.50, 0.03, 0.09, 1.0), 1.0, nil];
    [gown drawInBezierPath:disc angle:90];          // flipped view: top → bottom

    // Her gown's red flame stripes rising from the hem, cut off by the rim.
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    // Brightest in the middle, deeper at the sides, like the folds of the dress.
    struct Flame { double x, tip, width, red; };
    const Flame flames[3] = {{-0.48, 0.30, 0.17, 0.50}, {0.04, 0.02, 0.20, 0.80},
                             {0.52, 0.36, 0.16, 0.56}};
    for (const Flame& f : flames) {
        NSBezierPath* tongue = [NSBezierPath bezierPath];
        [tongue moveToPoint:NSMakePoint(f.x - f.width, 1.10)];
        [tongue curveToPoint:NSMakePoint(f.x + f.width * 0.25, f.tip)        // leans slightly
               controlPoint1:NSMakePoint(f.x - f.width * 0.7, 0.75)
               controlPoint2:NSMakePoint(f.x - f.width * 0.15, f.tip + 0.25)];
        [tongue curveToPoint:NSMakePoint(f.x + f.width, 1.10)
               controlPoint1:NSMakePoint(f.x + f.width * 0.35, f.tip + 0.30)
               controlPoint2:NSMakePoint(f.x + f.width * 0.8, 0.75)];
        [tongue closePath];
        [tongue transformUsingAffineTransform:ronova_frame(c, r, false)];
        [rgba(f.red, 0.04 + f.red * 0.03, 0.08 + f.red * 0.07, 1.0) setFill];
        [tongue fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Double rim: silver band, a fine dark gap, then a thin inner silver line.
    [silver setStroke];
    disc.lineWidth = std::max(1.5, r * 0.055);
    [disc stroke];
    NSBezierPath* gap = [NSBezierPath bezierPathWithOvalInRect:
        NSInsetRect(disc.bounds, r * 0.055, r * 0.055)];
    gap.lineWidth = std::max(0.6, r * 0.022);
    [ink setStroke];
    [gap stroke];
    NSBezierPath* hairline = [NSBezierPath bezierPathWithOvalInRect:
        NSInsetRect(disc.bounds, r * 0.085, r * 0.085)];
    hairline.lineWidth = std::max(0.6, r * 0.016);
    [silverShade setStroke];
    [hairline stroke];

    // ---- Her silver hip-knot: four interlaced pointed loops on the
    //      diagonals, red points on the axes, a red jewel at the heart.
    NSAffineTransform* center = ronova_frame(c, r, false);
    for (int i = 0; i < 4; ++i) {                   // red points between the loops
        NSBezierPath* point = in_frame(ronova_loop(0.62, 0.13), center, -90.0 + i * 90.0);
        [rgba(0.82, 0.08, 0.16, 1.0) setFill];
        [point fill];
        [ink setStroke];
        point.lineWidth = line * 0.8;
        [point stroke];
    }
    // Silver loops: ink edge (casting a small shadow onto the gown), the metal
    // band, then an engraved groove down its middle.
    [NSGraphicsContext saveGraphicsState];
    NSShadow* cast = [[NSShadow alloc] init];
    cast.shadowColor = rgba(0.0, 0.0, 0.0, 0.6);
    cast.shadowBlurRadius = r * 0.06;
    cast.shadowOffset = NSMakeSize(0, -r * 0.04);
    [cast set];
    for (int i = 0; i < 4; ++i) {
        NSBezierPath* loop = in_frame(ronova_loop(0.70, 0.24), center, -45.0 + i * 90.0);
        loop.lineJoinStyle = NSLineJoinStyleRound;
        loop.lineWidth = r * 0.13;
        [ink setStroke];
        [loop stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    for (int i = 0; i < 4; ++i) {
        NSBezierPath* loop = in_frame(ronova_loop(0.70, 0.24), center, -45.0 + i * 90.0);
        loop.lineJoinStyle = NSLineJoinStyleRound;
        loop.lineWidth = r * 0.075;
        [silver setStroke];
        [loop stroke];
        loop.lineWidth = std::max(0.5, r * 0.018);
        [silverShade setStroke];
        [loop stroke];
    }
    // Jewel: a red lozenge with a dark rim and one small catch-light.
    NSBezierPath* jewel = [NSBezierPath bezierPath];
    const CGFloat jw = r * 0.17;
    [jewel moveToPoint:NSMakePoint(c.x, c.y - jw * 1.25)];
    [jewel lineToPoint:NSMakePoint(c.x + jw, c.y)];
    [jewel lineToPoint:NSMakePoint(c.x, c.y + jw * 1.25)];
    [jewel lineToPoint:NSMakePoint(c.x - jw, c.y)];
    [jewel closePath];
    [rgba(0.86, 0.10, 0.17, 1.0) setFill];
    [jewel fill];
    [ink setStroke];
    jewel.lineWidth = line;
    [jewel stroke];
    [rgba(1.0, 0.85, 0.85, 0.9) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - jw * 0.42, c.y - jw * 0.62,
                                                       jw * 0.32, jw * 0.32)] fill];

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// ---- Naberius ------------------------------------------------------------
// After her art: the crystal-flower ornament behind her head (ice-blue
// diamond petals in gold frames around a glowing cyan core), her navy gown
// traced with the glowing circuit lines of her glove, and the faceted gold
// tridents and cyan gem of her circlet. Same unit space
// as Ronova (key radius, y down).

// Elongated diamond from `start` to `start + length` along +x, half-width w.
NSBezierPath* naberius_kite(double start, double length, double w) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(start, 0.0)];
    [p lineToPoint:NSMakePoint(start + length * 0.38, -w)];
    [p lineToPoint:NSMakePoint(start + length, 0.0)];
    [p lineToPoint:NSMakePoint(start + length * 0.38, w)];
    [p closePath];
    return p;
}

// One half of the kite (its upper facet), for two-tone faceting.
NSBezierPath* naberius_kite_facet(double start, double length, double w) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(start, 0.0)];
    [p lineToPoint:NSMakePoint(start + length * 0.38, -w)];
    [p lineToPoint:NSMakePoint(start + length, 0.0)];
    [p closePath];
    return p;
}

void draw_naberius_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    NSColor* ink = rgba(0.04, 0.05, 0.13, 1.0);
    NSColor* gold = rgba(0.90, 0.76, 0.45, 1.0);
    NSColor* goldShade = rgba(0.58, 0.45, 0.22, 1.0);
    NSColor* cyan = rgba(0.45, 0.88, 1.00, 1.0);
    const CGFloat line = std::max(1.0, r * 0.032);
    NSAffineTransform* unit = ronova_frame(c, r, false);

    // ---- Gold circlet tridents to each side (gothic forked metalwork): a
    //      main blade with two swept barbs. Faceted: lit upper half, shaded
    //      lower half. They draw in as the highlight fades.
    const double reach = 0.55 + 0.45 * level;
    struct SpikeAt { double degrees, start, length, width; };
    const SpikeAt spikes[6] = {{0, 0.82, 0.80, 0.14}, {180, 0.82, 0.80, 0.14},
                               {-30, 0.98, 0.40, 0.085}, {-150, 0.98, 0.40, 0.085},
                               {30, 0.98, 0.40, 0.085}, {150, 0.98, 0.40, 0.085}};
    for (const SpikeAt& sp : spikes) {
        NSBezierPath* blade = in_frame(naberius_kite(sp.start, sp.length * reach, sp.width), unit, sp.degrees);
        [goldShade setFill];
        [blade fill];
        [gold setFill];
        [in_frame(naberius_kite_facet(sp.start, sp.length * reach, sp.width), unit, sp.degrees) fill];
        [ink setStroke];
        blade.lineWidth = line;
        blade.lineJoinStyle = NSLineJoinStyleMiter;
        [blade stroke];
    }

    // ---- Disc: her navy gown, lighter at the top.
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* gown = [[NSGradient alloc]
        initWithStartingColor:rgba(0.14, 0.19, 0.42, 1.0)
                  endingColor:rgba(0.05, 0.07, 0.20, 1.0)];
    [gown drawInBezierPath:disc angle:90];

    // Glowing circuit traces from her glove: right-angle runs ending in nodes.
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    NSShadow* glow = [[NSShadow alloc] init];
    glow.shadowColor = [cyan colorWithAlphaComponent:0.9];
    glow.shadowBlurRadius = r * 0.10;
    glow.shadowOffset = NSZeroSize;
    [glow set];
    const NSPoint traces[3][4] = {
        {{-1.00, 0.42}, {-0.58, 0.42}, {-0.44, 0.58}, {0.02, 0.58}},
        {{1.00, -0.36}, {0.62, -0.36}, {0.48, -0.52}, {0.26, -0.52}},
        {{1.00, 0.70}, {0.56, 0.70}, {0.40, 0.84}, {0.40, 1.10}},
    };
    for (const auto& trace : traces) {
        NSBezierPath* path = [NSBezierPath bezierPath];
        [path moveToPoint:trace[0]];
        for (int i = 1; i < 4; ++i) [path lineToPoint:trace[i]];
        [path transformUsingAffineTransform:unit];
        path.lineWidth = std::max(0.8, r * 0.028);
        path.lineJoinStyle = NSLineJoinStyleMiter;
        [[cyan colorWithAlphaComponent:0.85] setStroke];
        [path stroke];
        const NSPoint node = [unit transformPoint:trace[3]];
        const CGFloat nr = r * 0.045;
        [cyan setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(node.x - nr, node.y - nr, nr * 2, nr * 2)] fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Gold double rim, like her circlet.
    [gold setStroke];
    disc.lineWidth = std::max(1.5, r * 0.06);
    [disc stroke];
    NSBezierPath* inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc.bounds, r * 0.09, r * 0.09)];
    inner.lineWidth = std::max(0.6, r * 0.018);
    [goldShade setStroke];
    [inner stroke];

    // Circlet gem: upright cyan diamond set on the rim at the top.
    NSAffineTransform* atBrow = [NSAffineTransform transform];
    [atBrow translateXBy:c.x yBy:c.y - r * 1.03];
    [atBrow rotateByDegrees:90.0];
    [atBrow scaleBy:r];
    NSBezierPath* gem = naberius_kite(-0.15, 0.30, 0.11);
    [gem transformUsingAffineTransform:atBrow];
    NSGradient* gemFill = [[NSGradient alloc]
        initWithStartingColor:rgba(0.72, 0.98, 1.0, 1.0)
                  endingColor:rgba(0.12, 0.62, 0.80, 1.0)];
    [gemFill drawInBezierPath:gem angle:90];
    [gold setStroke];
    gem.lineWidth = std::max(0.8, r * 0.03);
    [gem stroke];

    // ---- Crystal flower: eight near-equal diamond petals; ice-cyan at the
    //      core deepening to blue at the tips, each in a thin gold frame with
    //      a bright facet; the main four run on into gold points.
    [NSGraphicsContext saveGraphicsState];
    NSShadow* lift = [[NSShadow alloc] init];
    lift.shadowColor = rgba(0, 0, 0, 0.55);
    lift.shadowBlurRadius = r * 0.06;
    lift.shadowOffset = NSMakeSize(0, -r * 0.035);
    [lift set];
    for (int i = 0; i < 8; ++i) {
        const bool major = i % 2 == 0;
        NSBezierPath* petal = in_frame(naberius_kite(0.14, major ? 0.58 : 0.50, major ? 0.17 : 0.15),
                                       unit, -90.0 + i * 45.0);
        [ink setFill];
        [petal fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    for (int i = 0; i < 8; ++i) {
        const bool major = i % 2 == 0;
        const double len = major ? 0.58 : 0.50;   // near-equal: a flower, not a compass
        const double w = major ? 0.17 : 0.15;
        const double deg = -90.0 + i * 45.0;
        NSBezierPath* petal = in_frame(naberius_kite(0.14, len, w), unit, deg);
        const double rad = deg * M_PI / 180.0;
        const NSPoint from = NSMakePoint(c.x + std::cos(rad) * r * 0.14, c.y + std::sin(rad) * r * 0.14);
        const NSPoint to = NSMakePoint(c.x + std::cos(rad) * r * (0.14 + len),
                                       c.y + std::sin(rad) * r * (0.14 + len));
        NSGradient* crystal = [[NSGradient alloc]
            initWithStartingColor:rgba(0.72, 0.96, 1.00, 1.0)
                      endingColor:rgba(0.16, 0.42, 0.86, 1.0)];
        [NSGraphicsContext saveGraphicsState];
        [petal addClip];
        [crystal drawFromPoint:from toPoint:to options:0];
        [rgba(1.0, 1.0, 1.0, 0.28) setFill];                 // bright upper facet
        [in_frame(naberius_kite_facet(0.14, len, w), unit, deg) fill];
        [NSGraphicsContext restoreGraphicsState];
        [gold setStroke];
        petal.lineWidth = std::max(0.8, r * 0.026);
        petal.lineJoinStyle = NSLineJoinStyleMiter;
        [petal stroke];
        if (major) {
            NSBezierPath* tip = in_frame(naberius_kite(0.14 + len - 0.04, 0.16, 0.045), unit, deg);
            [gold setFill];
            [tip fill];
            [ink setStroke];
            tip.lineWidth = std::max(0.6, r * 0.016);
            [tip stroke];
        }
    }

    // Core: glowing cyan in a gold ring.
    const CGFloat coreR = r * 0.16;
    [NSGraphicsContext saveGraphicsState];
    NSShadow* coreGlow = [[NSShadow alloc] init];
    coreGlow.shadowColor = cyan;
    coreGlow.shadowBlurRadius = r * 0.18;
    coreGlow.shadowOffset = NSZeroSize;
    [coreGlow set];
    NSGradient* core = [[NSGradient alloc]
        initWithStartingColor:rgba(0.92, 1.0, 1.0, 1.0)
                  endingColor:rgba(0.30, 0.78, 1.0, 1.0)];
    NSBezierPath* coreDisc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - coreR, c.y - coreR, coreR * 2, coreR * 2)];
    [core drawInBezierPath:coreDisc relativeCenterPosition:NSZeroPoint];
    [NSGraphicsContext restoreGraphicsState];
    [gold setStroke];
    coreDisc.lineWidth = std::max(1.0, r * 0.04);
    [coreDisc stroke];

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// ---- Istaroth ------------------------------------------------------------
// After her art: the starlit midnight sky behind her, her four-point star in
// a clock dial (time), the tilted gold halo floating around her, and the
// hanging clock-hand pendants. Same unit space as the others (y down).

// Upright four-point star of unit "radius" with a slim waist.
NSBezierPath* istaroth_star(double waist) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    for (int i = 0; i < 8; ++i) {
        const double a = -M_PI / 2.0 + i * M_PI / 4.0;
        const double rr = i % 2 == 0 ? 1.0 : waist;
        const NSPoint pt = NSMakePoint(std::cos(a) * rr, std::sin(a) * rr);
        if (i == 0) [p moveToPoint:pt]; else [p lineToPoint:pt];
    }
    [p closePath];
    return p;
}

// Half of the tilted halo ellipse: back (upper arc, behind the disc) or
// front (lower arc, over it). Centered at (0, cy), radii rx/ry, tilted.
NSBezierPath* istaroth_halo_arc(double cy, double rx, double ry, double tiltDeg, bool front) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    const double tilt = tiltDeg * M_PI / 180.0;
    const int steps = 48;
    for (int i = 0; i <= steps; ++i) {
        // front = lower half (sin > 0 in y-down space), back = upper half.
        const double t = (front ? 0.0 : M_PI) + M_PI * i / steps;
        const double x = rx * std::cos(t), y = ry * std::sin(t);
        const NSPoint pt = NSMakePoint(x * std::cos(tilt) - y * std::sin(tilt),
                                       cy + x * std::sin(tilt) + y * std::cos(tilt));
        if (i == 0) [p moveToPoint:pt]; else [p lineToPoint:pt];
    }
    return p;
}

void istaroth_stroke_halo(NSBezierPath* arc, NSAffineTransform* unit, CGFloat r,
                          NSColor* gold, NSColor* glowGold, NSColor* ink) {
    NSBezierPath* path = [arc copy];
    [path transformUsingAffineTransform:unit];
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineWidth = r * 0.13;
    [ink setStroke];
    [path stroke];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* glow = [[NSShadow alloc] init];
    glow.shadowColor = glowGold;
    glow.shadowBlurRadius = r * 0.16;
    glow.shadowOffset = NSZeroSize;
    [glow set];
    path.lineWidth = r * 0.085;
    [gold setStroke];
    [path stroke];
    [NSGraphicsContext restoreGraphicsState];
    path.lineWidth = std::max(0.6, r * 0.022);
    [rgba(1.0, 0.95, 0.80, 0.9) setStroke];          // bright inner edge
    [path stroke];
}

void draw_istaroth_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    NSColor* ink = rgba(0.05, 0.04, 0.08, 1.0);
    NSColor* brass = rgba(0.88, 0.72, 0.38, 1.0);
    NSColor* brassShade = rgba(0.55, 0.42, 0.18, 1.0);
    NSColor* glowGold = rgba(1.0, 0.84, 0.42, 0.9);
    const CGFloat line = std::max(1.0, r * 0.03);
    NSAffineTransform* unit = ronova_frame(c, r, false);

    // Halo geometry: it tightens a little as the highlight fades.
    const double halo = 0.82 + 0.18 * level;
    // Floats above the top of the disc, like the halo over her head; the front
    // of the ring just crosses the top edge.
    const double haloCy = -0.98, haloRx = 1.18 * halo, haloRy = 0.30 * halo, haloTilt = -7.0;

    // ---- Hanging clock-hand pendants beside the disc: a small ring, then a
    //      slim faceted needle pointing down. They draw in as it fades.
    for (int side = -1; side <= 1; side += 2) {
        const double x = side * (1.16 * halo);
        const double ringY = -0.30, ringR = 0.10;
        NSBezierPath* thread = [NSBezierPath bezierPath];
        [thread moveToPoint:NSMakePoint(x, haloCy + 0.12)];
        [thread lineToPoint:NSMakePoint(x, ringY - ringR)];
        [thread transformUsingAffineTransform:unit];
        thread.lineWidth = std::max(0.6, r * 0.02);
        [brassShade setStroke];
        [thread stroke];
        NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(x - ringR, ringY - ringR, ringR * 2, ringR * 2)];
        [ring transformUsingAffineTransform:unit];
        ring.lineWidth = std::max(1.0, r * 0.04);
        [brass setStroke];
        [ring stroke];
        NSBezierPath* needle = [NSBezierPath bezierPath];
        const double top = ringY + ringR, bottom = top + 0.62 * halo, w = 0.07;
        [needle moveToPoint:NSMakePoint(x, top)];
        [needle lineToPoint:NSMakePoint(x + w, top + 0.18)];
        [needle lineToPoint:NSMakePoint(x, bottom)];
        [needle lineToPoint:NSMakePoint(x - w, top + 0.18)];
        [needle closePath];
        [needle transformUsingAffineTransform:unit];
        NSBezierPath* lit = [NSBezierPath bezierPath];
        [lit moveToPoint:NSMakePoint(x, top)];
        [lit lineToPoint:NSMakePoint(x + w, top + 0.18)];
        [lit lineToPoint:NSMakePoint(x, bottom)];
        [lit closePath];
        [lit transformUsingAffineTransform:unit];
        [brassShade setFill];
        [needle fill];
        [brass setFill];
        [lit fill];
        [ink setStroke];
        needle.lineWidth = line * 0.8;
        [needle stroke];
    }

    // ---- Back of the halo (passes behind the disc).
    istaroth_stroke_halo(istaroth_halo_arc(haloCy, haloRx, haloRy, haloTilt, false),
                         unit, r, brass, glowGold, ink);

    // ---- Disc: her white dress, warm at the hem, traced with the gold
    //      filigree scrolls of her outfit.
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* dress = [[NSGradient alloc]
        initWithStartingColor:rgba(0.99, 0.98, 0.95, 1.0)
                  endingColor:rgba(0.88, 0.85, 0.80, 1.0)];
    [dress drawInBezierPath:disc angle:90];
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    for (int side = -1; side <= 1; side += 2) {            // mirrored scrolls
        NSBezierPath* scroll = [NSBezierPath bezierPath];
        [scroll moveToPoint:NSMakePoint(side * 0.10, 1.05)];
        [scroll curveToPoint:NSMakePoint(side * 0.78, 0.20)
               controlPoint1:NSMakePoint(side * 0.20, 0.55) controlPoint2:NSMakePoint(side * 0.82, 0.62)];
        [scroll curveToPoint:NSMakePoint(side * 0.52, 0.02)
               controlPoint1:NSMakePoint(side * 0.74, 0.02) controlPoint2:NSMakePoint(side * 0.60, -0.04)];
        [scroll curveToPoint:NSMakePoint(side * 0.58, 0.16)
               controlPoint1:NSMakePoint(side * 0.46, 0.08) controlPoint2:NSMakePoint(side * 0.50, 0.18)];
        [scroll transformUsingAffineTransform:unit];
        scroll.lineWidth = std::max(1.0, r * 0.05);
        scroll.lineCapStyle = NSLineCapStyleRound;
        [ink setStroke];
        [scroll stroke];
        scroll.lineWidth = std::max(0.8, r * 0.03);
        [brass setStroke];
        [scroll stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Brass double rim.
    [brass setStroke];
    disc.lineWidth = std::max(1.5, r * 0.06);
    [disc stroke];
    NSBezierPath* inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc.bounds, r * 0.09, r * 0.09)];
    inner.lineWidth = std::max(0.6, r * 0.018);
    [brassShade setStroke];
    [inner stroke];

    // ---- Clock dial: a thin brass ring with twelve ticks (long at 12/3/6/9).
    NSBezierPath* dial = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - r * 0.72, c.y - r * 0.72, r * 1.44, r * 1.44)];
    dial.lineWidth = std::max(0.6, r * 0.02);
    [brassShade setStroke];
    [dial stroke];
    for (int i = 0; i < 12; ++i) {
        const double a = i * M_PI / 6.0;
        const double inR = i % 3 == 0 ? 0.56 : 0.63;
        NSBezierPath* tick = [NSBezierPath bezierPath];
        [tick moveToPoint:[unit transformPoint:NSMakePoint(std::cos(a) * inR, std::sin(a) * inR)]];
        [tick lineToPoint:[unit transformPoint:NSMakePoint(std::cos(a) * 0.72, std::sin(a) * 0.72)]];
        tick.lineWidth = std::max(0.6, r * (i % 3 == 0 ? 0.035 : 0.02));
        [brass setStroke];
        [tick stroke];
    }

    // ---- Her four-point star: faceted brass (lit left/top facets) with a
    //      warm glow, a smaller star behind it on the diagonals.
    NSAffineTransform* small = [NSAffineTransform transform];
    [small translateXBy:c.x yBy:c.y];
    [small rotateByDegrees:45.0];
    [small scaleBy:r * 0.30];
    NSBezierPath* backStar = istaroth_star(0.30);
    [backStar transformUsingAffineTransform:small];
    [brassShade setFill];
    [backStar fill];
    [ink setStroke];
    backStar.lineWidth = line * 0.7;
    [backStar stroke];

    NSAffineTransform* big = [NSAffineTransform transform];
    [big translateXBy:c.x yBy:c.y];
    [big scaleBy:r * 0.52];
    NSBezierPath* star = istaroth_star(0.22);
    [star transformUsingAffineTransform:big];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* starGlow = [[NSShadow alloc] init];
    starGlow.shadowColor = glowGold;
    starGlow.shadowBlurRadius = r * 0.20;
    starGlow.shadowOffset = NSZeroSize;
    [starGlow set];
    [brass setFill];
    [star fill];
    [NSGraphicsContext restoreGraphicsState];
    // Lit facets: the triangles on the upper-left side of each point.
    NSBezierPath* facets = [NSBezierPath bezierPath];
    const double w = 0.22 * 0.7071;
    const NSPoint tips[4] = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}};
    const NSPoint sides[4] = {{-w, -w}, {w, -w}, {w, w}, {-w, w}};
    for (int i = 0; i < 4; ++i) {
        [facets moveToPoint:NSZeroPoint];
        [facets lineToPoint:tips[i]];
        [facets lineToPoint:sides[i]];
        [facets closePath];
    }
    [facets transformUsingAffineTransform:big];
    [rgba(1.0, 0.95, 0.78, 1.0) setFill];
    [facets fill];
    [ink setStroke];
    star.lineWidth = line;
    star.lineJoinStyle = NSLineJoinStyleMiter;
    [star stroke];

    // ---- Front of the halo (passes over the disc).
    istaroth_stroke_halo(istaroth_halo_arc(haloCy, haloRx, haloRy, haloTilt, true),
                         unit, r, brass, glowGold, ink);

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// ---- Asmoday -------------------------------------------------------------
// After her art: her glowing golden cube resting on her white raiment, which
// is crossed by her black strap with rust trim, inside a charcoal-and-rust
// rim. Same unit space as the others (y down).

void draw_asmoday_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    NSColor* gold = rgba(1.0, 0.84, 0.32, 1.0);
    NSColor* glowGold = rgba(1.0, 0.86, 0.30, 0.95);
    NSAffineTransform* unit = ronova_frame(c, r, false);

    // ---- Disc: her white raiment crossed by the black strap with rust trim;
    //      the cube sits on the strap.
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* raiment = [[NSGradient alloc]
        initWithStartingColor:rgba(0.98, 0.97, 0.95, 1.0)
                  endingColor:rgba(0.82, 0.82, 0.84, 1.0)];
    [raiment drawInBezierPath:disc angle:90];
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    NSAffineTransform* strapAt = [NSAffineTransform transform];
    [strapAt translateXBy:c.x yBy:c.y];
    [strapAt rotateByDegrees:-32.0];
    [strapAt scaleBy:r];
    NSBezierPath* strap = [NSBezierPath bezierPathWithRect:NSMakeRect(-1.3, -0.30, 2.6, 0.60)];
    [strap transformUsingAffineTransform:strapAt];
    [rgba(0.10, 0.08, 0.09, 1.0) setFill];
    [strap fill];
    for (double y : {-0.30, 0.24}) {                       // rust trim stripes
        NSBezierPath* trim = [NSBezierPath bezierPathWithRect:NSMakeRect(-1.3, y, 2.6, 0.06)];
        [trim transformUsingAffineTransform:strapAt];
        [rgba(0.72, 0.36, 0.22, 1.0) setFill];
        [trim fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Charcoal rim with a rust line inside (her trim colors).
    [rgba(0.16, 0.13, 0.13, 1.0) setStroke];
    disc.lineWidth = std::max(1.5, r * 0.065);
    [disc stroke];
    NSBezierPath* inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc.bounds, r * 0.095, r * 0.095)];
    inner.lineWidth = std::max(0.6, r * 0.02);
    [rgba(0.74, 0.38, 0.23, 1.0) setStroke];
    [inner stroke];

    // ---- Her golden cube: a turned wireframe cube with translucent faces,
    //      bright front edges, dimmer back edges and a hot core.
    const double yaw = 38.0 * M_PI / 180.0, pitch = 24.0 * M_PI / 180.0;
    const double size = 0.36;
    NSPoint v[8];
    double depth[8];
    for (int i = 0; i < 8; ++i) {
        const double x = (i & 1 ? 1 : -1), y = (i & 2 ? 1 : -1), z = (i & 4 ? 1 : -1);
        const double x1 = x * std::cos(yaw) + z * std::sin(yaw);
        const double z1 = -x * std::sin(yaw) + z * std::cos(yaw);
        const double y2 = y * std::cos(pitch) - z1 * std::sin(pitch);
        const double z2 = y * std::sin(pitch) + z1 * std::cos(pitch);
        v[i] = [unit transformPoint:NSMakePoint(x1 * size, -y2 * size + 0.02)];
        depth[i] = z2;
    }
    const int edges[12][2] = {{0,1},{2,3},{4,5},{6,7},{0,2},{1,3},{4,6},{5,7},{0,4},{1,5},{2,6},{3,7}};
    const int faces[6][4] = {{0,1,3,2},{4,5,7,6},{0,1,5,4},{2,3,7,6},{0,2,6,4},{1,3,7,5}};
    // Translucent faces.
    for (const auto& f : faces) {
        NSBezierPath* face = [NSBezierPath bezierPath];
        [face moveToPoint:v[f[0]]];
        for (int k = 1; k < 4; ++k) [face lineToPoint:v[f[k]]];
        [face closePath];
        [rgba(1.0, 0.82, 0.30, 0.16) setFill];
        [face fill];
    }
    // Hot core.
    NSGradient* core = [[NSGradient alloc] initWithColorsAndLocations:
        rgba(1.0, 0.98, 0.85, 1.0), 0.0, rgba(1.0, 0.82, 0.30, 0.7), 0.4,
        rgba(1.0, 0.75, 0.20, 0.0), 1.0, nil];
    [core drawFromCenter:c radius:0 toCenter:c radius:r * 0.24 options:0];
    // Edges: back ones dim, front ones bright and glowing.
    [NSGraphicsContext saveGraphicsState];
    NSShadow* glow = [[NSShadow alloc] init];
    glow.shadowColor = [glowGold colorWithAlphaComponent:0.6];
    glow.shadowBlurRadius = r * 0.06;
    glow.shadowOffset = NSZeroSize;
    [glow set];
    for (const auto& e : edges) {
        const bool back = depth[e[0]] + depth[e[1]] < -0.6;
        NSBezierPath* edge = [NSBezierPath bezierPath];
        [edge moveToPoint:v[e[0]]];
        [edge lineToPoint:v[e[1]]];
        edge.lineWidth = std::max(0.8, r * (back ? 0.022 : 0.04));
        edge.lineCapStyle = NSLineCapStyleRound;
        [(back ? [gold colorWithAlphaComponent:0.45] : gold) setStroke];
        [edge stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// ---- Columbina -----------------------------------------------------------
// After her art: the great glowing moon behind her, waning to a crescent as
// the timing window runs out. Same unit space as the others.

void draw_columbina_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    // ---- Disc: the full moon behind her. A soft moonglow outside the rim,
    //      a pale lavender-white surface with a few periwinkle seas, and gentle
    //      shading toward the lower left so it reads as a sphere.
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* moonglow = [[NSGradient alloc] initWithColorsAndLocations:
        rgba(0.80, 0.88, 1.0, 0.60), 0.0, rgba(0.60, 0.72, 1.0, 0.20), 0.5,
        rgba(0.50, 0.62, 1.0, 0.0), 1.0, nil];
    [moonglow drawFromCenter:c radius:discR toCenter:c radius:discR * 1.42 options:0];

    NSGradient* surface = [[NSGradient alloc] initWithColorsAndLocations:
        rgba(0.99, 1.0, 1.0, 1.0), 0.0, rgba(0.86, 0.91, 1.0, 1.0), 0.5,
        rgba(0.60, 0.68, 0.96, 1.0), 1.0, nil];
    [surface drawInBezierPath:disc relativeCenterPosition:NSMakePoint(0.35, 0.35)];
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    // Seas: irregular periwinkle patches, each built from a few overlapping
    // soft lobes so the edges wander like real lunar maria.
    struct Lobe { double x, y, rx, ry, rot; };
    const Lobe lobes[10] = {
        {-0.46, 0.26, 0.24, 0.16, 18}, {-0.28, 0.40, 0.20, 0.12, -10}, {-0.56, 0.44, 0.12, 0.09, 30},
        {0.22, 0.48, 0.20, 0.12, -18}, {0.40, 0.38, 0.13, 0.10, 25},
        {0.44, -0.40, 0.16, 0.11, 35}, {0.56, -0.28, 0.10, 0.08, -20},
        {-0.50, -0.34, 0.13, 0.09, -25}, {-0.40, -0.44, 0.08, 0.06, 10},
        {0.04, 0.10, 0.07, 0.05, 0},
    };
    for (const Lobe& lobe : lobes) {
        NSAffineTransform* t = [NSAffineTransform transform];
        [t translateXBy:c.x + lobe.x * r yBy:c.y + lobe.y * r];
        [t rotateByDegrees:lobe.rot];
        NSBezierPath* patch = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(-lobe.rx * r, -lobe.ry * r, lobe.rx * r * 2, lobe.ry * r * 2)];
        [patch transformUsingAffineTransform:t];
        [rgba(0.52, 0.62, 0.92, 0.24) setFill];
        [patch fill];
    }
    // Bright limb: a crisp rim of light along the upper-right edge, as if
    // the moon is lit from that side.
    NSBezierPath* limb = [NSBezierPath bezierPath];
    [limb appendBezierPathWithArcWithCenter:c radius:discR * 0.93 startAngle:-100 endAngle:20];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* limbGlow = [[NSShadow alloc] init];
    limbGlow.shadowColor = rgba(1.0, 1.0, 1.0, 0.9);
    limbGlow.shadowBlurRadius = r * 0.12;
    limbGlow.shadowOffset = NSZeroSize;
    [limbGlow set];
    limb.lineWidth = r * 0.07;
    limb.lineCapStyle = NSLineCapStyleRound;
    [rgba(1.0, 1.0, 1.0, 0.85) setStroke];
    [limb stroke];
    [NSGraphicsContext restoreGraphicsState];
    // Phase: as the timing window runs out a shadow slides across from the
    // left, waning the full moon to a crescent (full while waiting).
    const double waning = 1.0 - level;
    if (waning > 0.01) {
        const CGFloat shift = discR * 2.0 * (1.0 - waning * 0.85);
        NSBezierPath* shadow = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(c.x - discR - shift, c.y - discR, discR * 2.0, discR * 2.0)];
        [rgba(0.10, 0.10, 0.28, 0.88) setFill];
        [shadow fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Crisp silver rim with a fine lilac line inside.
    [rgba(0.95, 0.95, 1.0, 1.0) setStroke];
    disc.lineWidth = std::max(1.5, r * 0.06);
    [disc stroke];
    NSBezierPath* inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc.bounds, r * 0.09, r * 0.09)];
    inner.lineWidth = std::max(0.6, r * 0.018);
    [rgba(0.56, 0.52, 0.90, 1.0) setStroke];
    [inner stroke];

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// ---- Skirk ----------------------------------------------------------------
// After her art: reality shattered open onto a starry void. The disc is a
// pane of pale violet glass with a jagged hole showing the deep cosmos and
// cracks running out to the rim; her crystal butterfly floats in the void;
// two clusters of glass shards break outward. Same unit space as the others.

// Jagged hole in the pane (unit space): an uneven break with a few sharp
// notches — deliberately irregular, not a star.
NSBezierPath* skirk_hole() {
    const NSPoint pts[14] = {
        {-0.08, -0.62}, {0.18, -0.56}, {0.30, -0.66}, {0.46, -0.40}, {0.62, -0.30},
        {0.50, -0.06}, {0.66, 0.18}, {0.40, 0.34}, {0.30, 0.58}, {0.02, 0.46},
        {-0.24, 0.60}, {-0.42, 0.30}, {-0.64, 0.10}, {-0.48, -0.30},
    };
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:pts[0]];
    for (int i = 1; i < 14; ++i) [p lineToPoint:pts[i]];
    [p closePath];
    return p;
}

void draw_skirk_spot(NSPoint c, CGFloat r, double level) {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, std::clamp(level, 0.0, 1.0));
    CGContextBeginTransparencyLayer(ctx, nullptr);

    NSColor* edge = rgba(0.90, 0.93, 1.0, 1.0);
    NSColor* deep = rgba(0.14, 0.12, 0.40, 1.0);
    NSAffineTransform* unit = ronova_frame(c, r, false);

    // ---- Shards breaking outward in two clusters (lower right, upper left);
    //      lit and shaded facets with bright glass edges. They drift further
    //      out as the highlight fades.
    const double drift = 1.0 + (1.0 - level) * 0.35;
    struct Shard { double deg, from, len, w, skew; };
    const Shard shards[5] = {
        {16, 0.94, 0.74, 0.17, 0.08}, {38, 0.97, 0.46, 0.12, -0.05}, {-4, 0.98, 0.40, 0.10, 0.04},
        {-158, 0.95, 0.66, 0.16, -0.07}, {-136, 0.98, 0.40, 0.11, 0.05},
    };
    for (const Shard& sh : shards) {
        const double a = sh.deg * M_PI / 180.0;
        auto at = [&](double along, double across) {
            const double x = std::cos(a) * along - std::sin(a) * across;
            const double y = std::sin(a) * along + std::cos(a) * across;
            return [unit transformPoint:NSMakePoint(x, y)];
        };
        const double base = sh.from * drift;
        NSBezierPath* shard = [NSBezierPath bezierPath];
        [shard moveToPoint:at(base, -sh.w)];
        [shard lineToPoint:at(base + sh.len * 0.45, sh.skew - sh.w * 0.6)];
        [shard lineToPoint:at(base + sh.len, sh.skew)];
        [shard lineToPoint:at(base + sh.len * 0.30, sh.w * 0.9)];
        [shard closePath];
        NSBezierPath* litFacet = [NSBezierPath bezierPath];
        [litFacet moveToPoint:at(base, -sh.w)];
        [litFacet lineToPoint:at(base + sh.len * 0.45, sh.skew - sh.w * 0.6)];
        [litFacet lineToPoint:at(base + sh.len, sh.skew)];
        [litFacet closePath];
        [rgba(0.42, 0.40, 0.88, 0.95) setFill];
        [shard fill];
        [rgba(0.82, 0.86, 1.0, 0.95) setFill];
        [litFacet fill];
        shard.lineWidth = std::max(0.7, r * 0.022);
        shard.lineJoinStyle = NSLineJoinStyleMiter;
        [edge setStroke];
        [shard stroke];
    }

    // ---- Disc: a pane of pale violet glass...
    const CGFloat discR = r * 1.03;
    NSBezierPath* disc = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(c.x - discR, c.y - discR, discR * 2.0, discR * 2.0)];
    NSGradient* glass = [[NSGradient alloc]
        initWithStartingColor:rgba(0.90, 0.92, 1.0, 1.0)
                  endingColor:rgba(0.62, 0.64, 0.96, 1.0)];
    [glass drawInBezierPath:disc angle:-60];

    // ...shattered open onto the void: a jagged hole with the deep cosmos and
    // a few stars, cracks running from the hole out to the rim.
    NSBezierPath* hole = skirk_hole();
    [hole transformUsingAffineTransform:unit];
    NSGradient* cosmos = [[NSGradient alloc] initWithColorsAndLocations:
        rgba(0.24, 0.20, 0.58, 1.0), 0.0, rgba(0.08, 0.07, 0.24, 1.0), 0.6,
        rgba(0.02, 0.02, 0.08, 1.0), 1.0, nil];
    [cosmos drawInBezierPath:hole relativeCenterPosition:NSZeroPoint];
    [NSGraphicsContext saveGraphicsState];
    [hole addClip];
    const NSPoint stars[6] = {{-0.30, -0.30}, {0.34, -0.36}, {0.48, 0.06}, {-0.46, 0.04},
                              {0.18, 0.40}, {-0.14, 0.48}};
    for (int i = 0; i < 6; ++i) {
        const NSPoint p = [unit transformPoint:stars[i]];
        const CGFloat sr = r * (i % 2 ? 0.014 : 0.022);
        [rgba(0.90, 0.92, 1.0, 0.9) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - sr, p.y - sr, sr * 2, sr * 2)] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    hole.lineWidth = std::max(0.8, r * 0.026);
    hole.lineJoinStyle = NSLineJoinStyleMiter;
    [edge setStroke];
    [hole stroke];
    [NSGraphicsContext saveGraphicsState];
    [disc addClip];
    const NSPoint cracks[5][2] = {{{0.30, -0.66}, {0.52, -1.00}}, {{0.62, -0.30}, {1.06, -0.40}},
                                  {{0.66, 0.18}, {1.04, 0.36}}, {{0.30, 0.58}, {0.46, 1.04}},
                                  {{-0.64, 0.10}, {-1.08, 0.18}}};
    for (const auto& ck : cracks) {
        NSBezierPath* crack = [NSBezierPath bezierPath];
        [crack moveToPoint:[unit transformPoint:ck[0]]];
        [crack lineToPoint:[unit transformPoint:ck[1]]];
        crack.lineWidth = std::max(0.6, r * 0.018);
        [deep setStroke];
        [crack stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Cold white rim with a violet line inside.
    [edge setStroke];
    disc.lineWidth = std::max(1.2, r * 0.05);
    [disc stroke];
    NSBezierPath* inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc.bounds, r * 0.085, r * 0.085)];
    inner.lineWidth = std::max(0.6, r * 0.018);
    [rgba(0.50, 0.54, 1.0, 1.0) setStroke];
    [inner stroke];

    // ---- Crystal butterfly floating in the void: slim swept wings, lit
    //      cyan-blue, bright glass edges, a fine spindle body.
    for (int side = 0; side < 2; ++side) {
        NSAffineTransform* t = [NSAffineTransform transform];
        [t translateXBy:c.x yBy:c.y];
        [t scaleXBy:(side == 0 ? r : -r) yBy:r];
        NSBezierPath* upper = [NSBezierPath bezierPath];
        [upper moveToPoint:NSMakePoint(0.03, -0.04)];
        [upper lineToPoint:NSMakePoint(0.20, -0.42)];
        [upper lineToPoint:NSMakePoint(0.42, -0.38)];
        [upper lineToPoint:NSMakePoint(0.34, -0.08)];
        [upper closePath];
        NSBezierPath* lower = [NSBezierPath bezierPath];
        [lower moveToPoint:NSMakePoint(0.03, 0.02)];
        [lower lineToPoint:NSMakePoint(0.30, 0.06)];
        [lower lineToPoint:NSMakePoint(0.22, 0.30)];
        [lower lineToPoint:NSMakePoint(0.08, 0.22)];
        [lower closePath];
        for (NSBezierPath* w in @[upper, lower]) {
            [w transformUsingAffineTransform:t];
            const bool isLower = w == lower;
            NSGradient* ice = [[NSGradient alloc]
                initWithStartingColor:isLower ? rgba(0.64, 0.76, 1.0, 1.0) : rgba(0.84, 0.98, 1.0, 1.0)
                          endingColor:isLower ? rgba(0.34, 0.40, 0.92, 1.0) : rgba(0.36, 0.62, 1.0, 1.0)];
            [ice drawInBezierPath:w angle:side == 0 ? -30 : -150];
            w.lineWidth = std::max(0.7, r * 0.022);
            w.lineJoinStyle = NSLineJoinStyleMiter;
            [edge setStroke];
            [w stroke];
        }
    }
    NSBezierPath* body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(0.0, -0.18)];
    [body lineToPoint:NSMakePoint(0.035, -0.02)];
    [body lineToPoint:NSMakePoint(0.0, 0.22)];
    [body lineToPoint:NSMakePoint(-0.035, -0.02)];
    [body closePath];
    [body transformUsingAffineTransform:unit];
    [edge setFill];
    [body fill];
    for (int side = -1; side <= 1; side += 2) {
        NSBezierPath* antenna = [NSBezierPath bezierPath];
        [antenna moveToPoint:NSMakePoint(0.0, -0.16)];
        [antenna curveToPoint:NSMakePoint(side * 0.12, -0.34)
                controlPoint1:NSMakePoint(side * 0.02, -0.26) controlPoint2:NSMakePoint(side * 0.06, -0.33)];
        [antenna transformUsingAffineTransform:unit];
        antenna.lineWidth = std::max(0.5, r * 0.012);
        [edge setStroke];
        [antenna stroke];
    }

    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

}  // namespace

bool key_overlay_map_ready() {
    return current_key_layout().ready;
}

@interface KeyOverlayView : NSView
@property(nonatomic) PlaybackController* playback;
@property(nonatomic) BOOL preview;   // outline every key for alignment checks
@end

@implementation KeyOverlayView {
    std::vector<Note> _notes;
    std::size_t _revision;
}

- (BOOL)isFlipped { return YES; }

- (void)tick {
    if (_playback != nullptr && self.window.isVisible) {
        self.needsDisplay = YES;
    }
}

// Strength (0…1) of each key's highlight right now, by practice style.
- (void)computeStrengths:(double*)strength {
    std::fill(strength, strength + 21, 0.0);
    if (_playback == nullptr) {
        return;
    }
    const HighwayClock clock = _playback->highway_clock();
    if (!clock.practice || clock.state == PlaybackState::stopped) {
        return;
    }
    if (clock.notes_revision != _revision) {
        _notes = _playback->notes();
        _revision = clock.notes_revision;
    }
    if (clock.practice_index >= _notes.size()) {
        return;
    }

    if (!clock.tempo) {
        // Waiting for input: the target note is simply solid.
        for (Key k : _notes[clock.practice_index].keys) {
            strength[static_cast<int>(k)] = 1.0;
        }
        return;
    }

    // Song speed: solid when the hit window opens, fading to nothing by the
    // time the note would be marked missed. Later notes whose windows are
    // already open (fast passages) show too, each with its own fade.
    const PracticeTimingWindows windows = _playback->practice_timing_windows();
    const double offset = static_cast<double>(_playback->practice_latency_offset().count());
    const double early = static_cast<double>(windows.early.count());
    const double miss = static_cast<double>(windows.miss.count());
    const double span = std::max(1.0, early + miss);
    for (std::size_t i = clock.practice_index; i < _notes.size(); ++i) {
        const double due = static_cast<double>(_notes[i].timestamp.count()) + offset;
        const double opens = due - early;
        if (clock.song_ms < opens) {
            break;   // notes are time-ordered: nothing later is open yet
        }
        const double progress = (clock.song_ms - opens) / span;   // 0 = just opened
        // Ease-in fade: stays near-solid through the sweet spot, then drops.
        const double level = std::clamp(1.0 - progress * progress, 0.0, 1.0);
        for (Key k : _notes[i].keys) {
            double& s = strength[static_cast<int>(k)];
            s = std::max(s, level);
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    const KeyLayout& layout = current_key_layout();
    if (!layout.ready) {
        return;
    }
    double strength[21];
    [self computeStrengths:strength];

    // The game picture: the window minus its title bar (none in full screen,
    // where the window exactly covers its display).
    const NSRect picture = key_picture_rect(self.window, self.bounds);
    const Theme& theme = themes::current();

    for (int k = 0; k < 21; ++k) {
        const KeyPlacement& rel = layout.keys[static_cast<std::size_t>(k)];
        const CGFloat r = rel.radius * NSWidth(picture);
        const NSPoint center = NSMakePoint(NSMinX(picture) + rel.u * NSWidth(picture),
                                           NSMinY(picture) + rel.v * NSHeight(picture));
        if (_preview) {
            // Alignment preview: a thin ring and the key letter on every button.
            NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(center.x - r, center.y - r, r * 2.0, r * 2.0)];
            ring.lineWidth = 2.0;
            [[theme.accent colorWithAlphaComponent:0.9] setStroke];
            [ring stroke];
            static const char* kLetters = "QWERTYUASDFGHJZXCVBNM";
            NSString* letter = [NSString stringWithFormat:@"%c", kLetters[k]];
            NSDictionary* attrs = @{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:std::max(10.0, r * 0.32)],
                NSForegroundColorAttributeName: theme.accent
            };
            const NSSize size = [letter sizeWithAttributes:attrs];
            [letter drawAtPoint:NSMakePoint(center.x - size.width * 0.5, center.y - r - size.height - 2.0)
                 withAttributes:attrs];
        }
        const double level = strength[k];
        if (level <= 0.01) {
            continue;
        }
        // Styled per HUD theme (read every frame, so theme switches apply live).
        if (theme.id == "ronova") {
            draw_ronova_spot(center, r, level);
        } else if (theme.id == "naberius") {
            draw_naberius_spot(center, r, level);
        } else if (theme.id == "istaroth") {
            draw_istaroth_spot(center, r, level);
        } else if (theme.id == "asmoday") {
            draw_asmoday_spot(center, r, level);
        } else if (theme.id == "columbina") {
            draw_columbina_spot(center, r, level);
        } else if (theme.id == "skirk") {
            draw_skirk_spot(center, r, level);
        } else {
            draw_default_spot(theme, center, r, level);
        }
    }
}

@end

@implementation KeyOverlayController {
    KeyOverlayView* _view;
    NSTimer* _timer;
}

- (void)setPreview:(BOOL)preview {
    _view.preview = preview;
    _view.needsDisplay = YES;
}

- (BOOL)preview {
    return _view.preview;
}

- (instancetype)initWithPlayback:(PlaybackController*)playback {
    NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                styleMask:NSWindowStyleMaskBorderless |
                                                          NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    self = [super initWithWindow:panel];
    if (self == nil) {
        return nil;
    }
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;          // clicks go straight to the game
    panel.hidesOnDeactivate = NO;
    // Above the game, below the HUD (NSScreenSaverWindowLevel).
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorIgnoresCycle;

    _view = [[KeyOverlayView alloc] initWithFrame:panel.contentView.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.playback = playback;
    panel.contentView = _view;
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)updateWithGameFrame:(NSRect)gameFrame visible:(BOOL)visible {
    NSWindow* window = self.window;
    if (!visible || !current_key_layout().ready || NSIsEmptyRect(gameFrame)) {
        if (window.isVisible) {
            [window orderOut:nil];
        }
        [_timer invalidate];
        _timer = nil;
        return;
    }
    if (!NSEqualRects(window.frame, gameFrame)) {
        [window setFrame:gameFrame display:NO];
    }
    if (!window.isVisible) {
        [window orderFrontRegardless];
    }
    if (_timer == nil) {
        // 60 fps only while shown: the song-speed fade needs smooth updates.
        _timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                         target:_view
                                       selector:@selector(tick)
                                       userInfo:nil
                                        repeats:YES];
        _timer.tolerance = 0.002;
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

@end
