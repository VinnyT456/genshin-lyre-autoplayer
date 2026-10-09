#import "song_library.h"

#include <algorithm>

#include "settings_window.h"
#include "strings.h"
#include "theme.h"

namespace {

enum LibraryPage : NSInteger { kPageAll = 0, kPageFavorites = 1, kPageRecent = 2 };

NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSTextField* l = [NSTextField labelWithString:text ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.cell.truncatesLastVisibleLine = YES;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

}  // namespace

// ---- Icon button ------------------------------------------------------------------

// A borderless SF Symbol button that draws itself. AppKit's own NSButton sizes
// itself through SwiftUI on current macOS (about a millisecond each), which
// made every song row slow to build; this costs next to nothing.
@interface LibraryIconButton : NSControl
@property(nonatomic, strong) NSImage* symbol;
@property(nonatomic, strong) NSColor* tint;
@end

@implementation LibraryIconButton {
    BOOL _pressed;
}

+ (instancetype)buttonWithSymbol:(NSString*)name target:(id)target action:(SEL)action {
    LibraryIconButton* b = [[LibraryIconButton alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    b.symbol = [LibraryIconButton imageNamed:name];
    b.target = target;
    b.action = action;
    return b;
}

// Symbol images are looked up once and shared by every row.
+ (NSImage*)imageNamed:(NSString*)name {
    static NSMutableDictionary<NSString*, NSImage*>* cache = [NSMutableDictionary dictionary];
    NSImage* image = cache[name];
    if (image == nil) {
        image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                configurationWithPointSize:12 weight:NSFontWeightSemibold]];
        cache[name] = image;
    }
    return image;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled) {
        return;
    }
    _pressed = YES;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent*)event {
    if (!_pressed) {
        return;
    }
    _pressed = NO;
    self.needsDisplay = YES;
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) {
        [self sendAction:self.action to:self.target];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    if (_symbol == nil) {
        return;
    }
    const NSSize size = _symbol.size;
    const NSRect r = NSMakeRect(round(NSMidX(self.bounds) - size.width / 2),
                                round(NSMidY(self.bounds) - size.height / 2), size.width, size.height);
    // Tint the template symbol: draw it, then paint the color over its pixels.
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, !self.enabled ? 0.3 : _pressed ? 0.6 : 1.0);
    CGContextBeginTransparencyLayer(ctx, nullptr);
    [_symbol drawInRect:r];
    [(_tint ?: NSColor.labelColor) setFill];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString*)accessibilityLabel { return self.toolTip; }
- (BOOL)accessibilityPerformPress {
    [self sendAction:self.action to:self.target];
    return YES;
}

@end

// ---- One song -----------------------------------------------------------------

// A song row. Built once and reused by the table (configure: refills it), and
// laid out with plain frames: no stack views or constraints, so scrolling and
// refreshing cost almost nothing.
@interface SongLibraryRow : NSView
@property(nonatomic) NSInteger songIndex;
@property(nonatomic, copy) void (^onPick)(NSInteger songIndex);
- (instancetype)initWithOwner:(id)owner;
- (void)configureWithQueue:(id<PlayerQueueDelegate>)q index:(NSInteger)i
               reorderable:(BOOL)reorderable count:(NSInteger)count;
@end

@implementation SongLibraryRow {
    NSTrackingArea* _tracking;
    BOOL _hovering;
    BOOL _current;
    BOOL _favorite;
    BOOL _reorderable;
    NSTextField* _number;
    NSImageView* _speaker;
    NSTextField* _title;
    NSTextField* _details;
    NSPopUpButton* _versions;
    LibraryIconButton* _star;
    LibraryIconButton* _up;
    LibraryIconButton* _down;
    LibraryIconButton* _remove;
    CGFloat _versionsWidth;
    __weak id _owner;
}

- (instancetype)initWithOwner:(id)owner {
    self = [super initWithFrame:NSMakeRect(0, 0, 400, 48)];
    if (self == nil) {
        return nil;
    }
    self.identifier = @"song";
    _number = label(@"", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    _number.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    _number.alignment = NSTextAlignmentCenter;
    _speaker = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:nil]];
    _speaker.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightSemibold];
    _title = label(@"", 13, NSFontWeightMedium, NSColor.labelColor);
    _details = label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _owner = owner;
    _star = [LibraryIconButton buttonWithSymbol:@"star" target:owner action:@selector(toggleFavorite:)];
    _up = [LibraryIconButton buttonWithSymbol:@"chevron.up" target:owner action:@selector(moveUp:)];
    _down = [LibraryIconButton buttonWithSymbol:@"chevron.down" target:owner action:@selector(moveDown:)];
    _remove = [LibraryIconButton buttonWithSymbol:@"xmark" target:owner action:@selector(removeSong:)];
    for (NSView* v in @[_number, _speaker, _title, _details, _star, _up, _down, _remove]) {
        [self addSubview:v];
    }
    return self;
}

- (void)configureWithQueue:(id<PlayerQueueDelegate>)q index:(NSInteger)i
               reorderable:(BOOL)reorderable count:(NSInteger)count {
    const Theme& theme = themes::current();
    _songIndex = i;
    _current = i == [q queueCurrentIndex];
    _favorite = [q queueIsFavoriteAtIndex:i];
    _reorderable = reorderable;

    _number.stringValue = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
    _number.textColor = theme.ink_faint;
    _number.hidden = _current;
    _speaker.hidden = !_current;
    _speaker.contentTintColor = theme.accent;

    _title.stringValue = [q queueTitleAtIndex:i] ?: @"";
    _title.toolTip = _title.stringValue;
    _title.font = [NSFont systemFontOfSize:13 weight:_current ? NSFontWeightSemibold : NSFontWeightMedium];
    _title.textColor = _current ? theme.accent : theme.ink;

    // Details: current marker, file type, BPM, versions.
    NSMutableArray<NSString*>* details = [NSMutableArray array];
    if (_current) {
        [details addObject:strings::get(Str::library_now_playing)];
    }
    const NSInteger sources = [q queueSourceCountAtIndex:i];
    const NSInteger selected = [q queueSelectedSourceIndexAtIndex:i];
    NSString* ext = [q queueSourceTitleAtIndex:i sourceIndex:std::max<NSInteger>(0, selected)]
                        .pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mid"] || [ext isEqualToString:@"midi"]) {
        [details addObject:@"MIDI"];
    } else if (ext.length > 0) {
        [details addObject:@"Genshin sheet"];
    }
    const NSInteger bpm = [q queueBpmAtIndex:i];
    if (bpm > 0) {
        [details addObject:[NSString stringWithFormat:@"%ld BPM", (long)bpm]];
    }
    if (sources > 1) {
        [details addObject:[NSString stringWithFormat:strings::get(Str::library_sources), (long)sources]];
    }
    _details.stringValue = [details componentsJoinedByString:@" · "];
    _details.textColor = theme.ink_faint;

    // A .genshinsheet/.mid pair: choose which version plays.
    _versions.hidden = sources <= 1;
    if (sources > 1 && _versions == nil) {
        // Only songs with several versions get the (costly) popup.
        _versions = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        _versions.controlSize = NSControlSizeSmall;
        _versions.font = [NSFont systemFontOfSize:11];
        _versions.target = _owner;
        _versions.action = @selector(sourceChanged:);
        [self addSubview:_versions];
    }
    if (sources > 1) {
        [_versions removeAllItems];
        for (NSInteger src = 0; src < sources; ++src) {
            [_versions addItemWithTitle:[q queueSourceTitleAtIndex:i sourceIndex:src]];
            _versions.lastItem.tag = src;
        }
        [_versions selectItemWithTag:selected];
        _versions.tag = i;
        // Sized from the longest file name (measuring the popup itself is slow).
        CGFloat widest = 0;
        NSDictionary* attrs = @{NSFontAttributeName: _versions.font};
        for (NSMenuItem* item in _versions.itemArray) {
            widest = std::max(widest, [item.title sizeWithAttributes:attrs].width);
        }
        _versionsWidth = std::min<CGFloat>(150, widest + 34);
    }

    _star.symbol = [LibraryIconButton imageNamed:_favorite ? @"star.fill" : @"star"];
    _star.toolTip = strings::get(_favorite ? Str::menu_queue_unfavorite : Str::menu_queue_favorite);
    _star.tint = _favorite ? theme.accent : theme.ink_soft;
    _up.toolTip = strings::get(Str::menu_queue_move_up);
    _down.toolTip = strings::get(Str::menu_queue_move_down);
    _remove.toolTip = strings::get(Str::menu_queue_remove);
    _up.enabled = i > 0;
    _down.enabled = i + 1 < count;
    for (LibraryIconButton* b in @[_up, _down, _remove]) {
        b.tint = theme.ink_soft;
        b.needsDisplay = YES;
    }
    _star.needsDisplay = YES;
    _star.tag = _up.tag = _down.tag = _remove.tag = i;
    [self applyHover];
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

// Frames, right to left: star, then remove / down / up (hover only; up and
// down in the all-songs view), then the version picker; the title takes
// what's left.
- (void)layout {
    [super layout];
    const NSRect b = self.bounds;
    const CGFloat midY = NSMidY(b);
    CGFloat right = NSMaxX(b) - 14;
    auto place = [&](NSView* v, CGFloat width, CGFloat height) {
        right -= width;
        v.frame = NSMakeRect(right, round(midY - height / 2), width, height);
        right -= 6;
    };
    place(_star, 24, 24);
    place(_remove, 24, 24);
    if (_reorderable) {
        place(_down, 24, 24);
        place(_up, 24, 24);
    }
    if (_versions != nil && !_versions.hidden) {
        place(_versions, _versionsWidth, 22);
    }
    [self applyHover];

    _number.frame = NSMakeRect(14, round(midY - 8), 26, 16);
    _speaker.frame = NSMakeRect(18, round(midY - 9), 18, 18);
    const CGFloat textX = 48;
    const CGFloat textWidth = std::max<CGFloat>(40, right - 4 - textX);
    _title.frame = NSMakeRect(textX, round(midY - 17), textWidth, 18);
    _details.frame = NSMakeRect(textX, round(midY + 2), textWidth, 15);
}

// Reorder / remove appear on hover; the star stays when favorited.
- (void)applyHover {
    _remove.hidden = !_hovering;
    _up.hidden = _down.hidden = !(_hovering && _reorderable);
    _star.hidden = !(_hovering || _favorite);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setHovering:(BOOL)hovering {
    _hovering = hovering;
    [self applyHover];
    self.needsDisplay = YES;
}

- (void)mouseEntered:(NSEvent*)e { [self setHovering:YES]; }
- (void)mouseExited:(NSEvent*)e { [self setHovering:NO]; }

- (void)prepareForReuse {
    [super prepareForReuse];
    [self setHovering:NO];
}

- (void)mouseUp:(NSEvent*)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.bounds) && self.onPick) {
        self.onPick(_songIndex);
    }
}

- (void)mouseDown:(NSEvent*)event {
    // Swallow so mouseUp arrives here; picking happens on release.
}

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const NSRect b = NSInsetRect(self.bounds, 6, 1);
    if (_current) {
        [[theme.accent colorWithAlphaComponent:0.16] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7] fill];
        [theme.accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(b), NSMinY(b) + 9, 3, NSHeight(b) - 18)
                                         xRadius:1.5 yRadius:1.5] fill];
    } else if (_hovering) {
        [[theme.ink colorWithAlphaComponent:0.06] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7] fill];
    }
}

@end

// ---- Sidebar action button ------------------------------------------------------

// Themed pill with an icon: filled with the accent (primary) or a quiet
// outline that warms to red on hover (destructive).
@interface LibraryActionButton : NSControl
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* symbol;
@property(nonatomic) BOOL primary;
@end

@implementation LibraryActionButton {
    NSTrackingArea* _tracking;
    BOOL _hovering;
    BOOL _pressed;
}

- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 32); }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking != nil) {
        [self removeTrackingArea:_tracking];
    }
    _tracking = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)e { _hovering = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { _hovering = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled) {
        return;
    }
    _pressed = YES;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent*)event {
    if (!_pressed) {
        return;
    }
    _pressed = NO;
    self.needsDisplay = YES;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.bounds)) {
        [self sendAction:self.action to:self.target];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const CGFloat alpha = self.enabled ? 1.0 : 0.4;
    const BOOL hot = self.enabled && _hovering;
    const NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath* pill = [NSBezierPath bezierPathWithRoundedRect:b xRadius:8 yRadius:8];
    NSColor* danger = [NSColor colorWithSRGBRed:0.95 green:0.42 blue:0.42 alpha:1.0];
    NSColor* fg;
    if (_primary) {
        [[theme.accent colorWithAlphaComponent:alpha * (_pressed ? 0.75 : hot ? 1.0 : 0.88)] setFill];
        [pill fill];
        fg = [theme.on_accent colorWithAlphaComponent:alpha];
    } else {
        [[(hot ? danger : theme.ink) colorWithAlphaComponent:alpha * (_pressed ? 0.16 : hot ? 0.10 : 0.05)] setFill];
        [pill fill];
        [[(hot ? danger : theme.ink) colorWithAlphaComponent:alpha * (hot ? 0.55 : 0.14)] setStroke];
        pill.lineWidth = 1.0;
        [pill stroke];
        fg = [(hot ? danger : theme.ink_soft) colorWithAlphaComponent:alpha];
    }

    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: fg
    };
    const NSSize ts = [_title sizeWithAttributes:attrs];
    NSImage* icon = [[NSImage imageWithSystemSymbolName:_symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration
            configurationWithPointSize:11 weight:NSFontWeightBold]];
    icon = [icon copy];
    [icon lockFocus];
    [fg set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, icon.size.width, icon.size.height),
                             NSCompositingOperationSourceAtop);
    [icon unlockFocus];
    const CGFloat gap = 6;
    const CGFloat total = icon.size.width + gap + ts.width;
    CGFloat x = round(NSMidX(b) - total / 2);
    [icon drawInRect:NSMakeRect(x, round(NSMidY(b) - icon.size.height / 2),
                                icon.size.width, icon.size.height)];
    x += icon.size.width + gap;
    [_title drawAtPoint:NSMakePoint(x, NSMidY(b) - ts.height / 2) withAttributes:attrs];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString*)accessibilityLabel { return _title; }
- (BOOL)accessibilityPerformPress {
    [self sendAction:self.action to:self.target];
    return YES;
}

@end

// ---- Window -------------------------------------------------------------------

@interface SongLibraryWindowController () <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SongLibraryWindowController {
    __weak id<SongLibraryHost> _host;
    NSView* _root;
    NSStackView* _sidebar;
    NSMutableArray<SettingsSidebarRow*>* _pageRows;
    LibraryActionButton* _addButton;
    LibraryActionButton* _clearButton;
    NSTextField* _heading;
    NSTextField* _countLabel;
    NSSearchField* _search;
    NSView* _card;                // rounded, bordered frame around the list
    NSScrollView* _scroll;
    NSTableView* _table;          // builds only the rows on screen
    NSTextField* _emptyLabel;
    NSArray<NSNumber*>* _visible; // song indexes shown, in order
    BOOL _reorderable;
    NSInteger _page;
    NSTimer* _timer;
    NSString* _signature;
}

- (instancetype)initWithHost:(id<SongLibraryHost>)host {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 660, 500)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:panel];
    if (self == nil) {
        return nil;
    }
    _host = host;
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;   // the search field still takes typing
    panel.contentMinSize = NSMakeSize(560, 380);
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    _root = [[NSView alloc] init];
    _root.wantsLayer = YES;
    panel.contentView = _root;

    // Sidebar: pages on top, playlist actions pinned to the bottom.
    _sidebar = [[NSStackView alloc] init];
    _sidebar.orientation = NSUserInterfaceLayoutOrientationVertical;
    _sidebar.alignment = NSLayoutAttributeLeading;
    _sidebar.spacing = 2;
    _sidebar.edgeInsets = NSEdgeInsetsMake(14, 4, 16, 4);
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebar.wantsLayer = YES;
    _pageRows = [NSMutableArray array];
    static NSString* const kIcons[] = {@"music.note.list", @"star.fill", @"clock.fill"};
    for (NSInteger i = 0; i < 3; ++i) {
        SettingsSidebarRow* row = [[SettingsSidebarRow alloc] init];
        row.icon = [NSImage imageWithSystemSymbolName:kIcons[i] accessibilityDescription:nil];
        row.tag = i;
        row.target = self;
        row.action = @selector(selectPage:);
        [_pageRows addObject:row];
        [_sidebar addView:row inGravity:NSStackViewGravityTop];
        [row.widthAnchor constraintEqualToConstant:170].active = YES;
    }
    // Playlist actions, centered at the bottom of the sidebar.
    _addButton = [[LibraryActionButton alloc] init];
    _addButton.symbol = @"plus";
    _addButton.primary = YES;
    _addButton.target = self;
    _addButton.action = @selector(addSongs:);
    _clearButton = [[LibraryActionButton alloc] init];
    _clearButton.symbol = @"trash";
    _clearButton.target = self;
    _clearButton.action = @selector(clearSongs:);
    NSStackView* actions = [NSStackView stackViewWithViews:@[_addButton, _clearButton]];
    actions.orientation = NSUserInterfaceLayoutOrientationVertical;
    actions.spacing = 8;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    // Header: page title + song count on the left, search on the right.
    _heading = label(@"", 20, NSFontWeightSemibold, NSColor.labelColor);
    _countLabel = label(@"", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSStackView* titles = [NSStackView stackViewWithViews:@[_heading, _countLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 1;
    _search = [[NSSearchField alloc] init];
    _search.delegate = self;
    _search.sendsSearchStringImmediately = YES;
    [_search.widthAnchor constraintEqualToConstant:190].active = YES;
    NSStackView* header = [NSStackView stackViewWithViews:@[titles, _search]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.distribution = NSStackViewDistributionFill;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [titles setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Song list: a table in a card-styled scroll view. A table only creates
    // views for the rows on screen, so big playlists open and update fast.
    _table = [[NSTableView alloc] init];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"song"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 48;
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.backgroundColor = NSColor.clearColor;
    _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.style = NSTableViewStylePlain;
    _table.dataSource = self;
    _table.delegate = self;
    _scroll = [[NSScrollView alloc] init];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.automaticallyAdjustsContentInsets = NO;
    _scroll.contentInsets = NSEdgeInsetsMake(6, 0, 6, 0);
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _table;
    _card = [[NSView alloc] init];
    _card.wantsLayer = YES;
    _card.layer.cornerRadius = 10;
    _card.layer.borderWidth = 1;
    _card.layer.masksToBounds = YES;
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_scroll];
    _emptyLabel = label(@"", 13, NSFontWeightMedium, NSColor.secondaryLabelColor);
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [_root addSubview:_sidebar];
    [_root addSubview:actions];
    [_root addSubview:header];
    [_root addSubview:_card];
    [_root addSubview:_emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:_root.topAnchor],
        [_sidebar.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor],
        [_sidebar.widthAnchor constraintEqualToConstant:178],
        [actions.centerXAnchor constraintEqualToAnchor:_sidebar.centerXAnchor],
        [actions.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor constant:-16],
        [_addButton.widthAnchor constraintEqualToConstant:150],
        [_clearButton.widthAnchor constraintEqualToConstant:150],
        [header.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor constant:22],
        [header.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-22],
        [header.topAnchor constraintEqualToAnchor:_root.topAnchor constant:18],
        [_card.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor constant:22],
        [_card.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-22],
        [_card.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [_card.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor constant:-22],
        [_scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_emptyLabel.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:34],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:_scroll.widthAnchor constant:-24],
    ]];

    [self reload];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                            selector:@selector(periodicReload)
                                            userInfo:nil repeats:YES];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)periodicReload {
    if (self.window.isVisible && ![[self signature] isEqualToString:_signature]) {
        [self reload];
    }
}

// Everything the window shows, so the periodic check rebuilds only on change.
- (NSString*)signature {
    id<PlayerQueueDelegate> q = [_host queueDelegate];
    NSMutableString* sig = [NSMutableString stringWithFormat:@"%s|%d|%ld|%@|",
        themes::current().id.c_str(), static_cast<int>(strings::current()), (long)_page,
        _search.stringValue];
    if (q == nil) {
        return sig;
    }
    const NSInteger count = [q queueCount];
    [sig appendFormat:@"%ld:%ld|", (long)count, (long)[q queueCurrentIndex]];
    for (NSInteger i = 0; i < count; ++i) {
        [sig appendFormat:@"%@:%d:%ld:%ld;", [q queueTitleAtIndex:i], [q queueIsFavoriteAtIndex:i],
            (long)[q queueBpmAtIndex:i], (long)[q queueSelectedSourceIndexAtIndex:i]];
    }
    [sig appendString:[[q queueRecentIndexes] componentsJoinedByString:@","]];
    return sig;
}

- (void)selectPage:(SettingsSidebarRow*)sender {
    _page = sender.tag;
    [self reload];
    [_table scrollRowToVisible:0];
}

- (void)controlTextDidChange:(NSNotification*)notification {
    [self reload];
}

// Songs on the current page, in display order, filtered by the search text.
- (NSArray<NSNumber*>*)visibleIndexes {
    id<PlayerQueueDelegate> q = [_host queueDelegate];
    NSMutableArray<NSNumber*>* result = [NSMutableArray array];
    if (q == nil) {
        return result;
    }
    NSArray<NSNumber*>* source;
    if (_page == kPageRecent) {
        source = [q queueRecentIndexes];
    } else {
        NSMutableArray<NSNumber*>* all = [NSMutableArray array];
        for (NSInteger i = 0; i < [q queueCount]; ++i) {
            [all addObject:@(i)];
        }
        source = all;
    }
    NSString* needle = [_search.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    for (NSNumber* n in source) {
        const NSInteger i = n.integerValue;
        if (_page == kPageFavorites && ![q queueIsFavoriteAtIndex:i]) {
            continue;
        }
        if (needle.length > 0 &&
            [[q queueTitleAtIndex:i] rangeOfString:needle
                options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        [result addObject:n];
    }
    return result;
}

- (void)reload {
    id<SongLibraryHost> host = _host;
    id<PlayerQueueDelegate> q = [host queueDelegate];
    const Theme& theme = themes::current();
    _signature = [self signature];

    self.window.title = strings::get(Str::library_title);
    settings_paint_chrome(self.window, _root, _sidebar);
    static const Str kPageTitles[] = {Str::library_all, Str::library_favorites, Str::menu_recent};
    for (SettingsSidebarRow* row in _pageRows) {
        row.title = strings::get(kPageTitles[row.tag]);
        row.selected = row.tag == _page;
        row.needsDisplay = YES;
    }
    _addButton.title = strings::get(Str::open_songs);
    _addButton.needsDisplay = YES;
    _clearButton.title = strings::get(Str::menu_queue_clear);
    const NSInteger count = q != nil ? [q queueCount] : 0;
    _clearButton.enabled = count > 0;
    _clearButton.needsDisplay = YES;
    _search.placeholderString = strings::get(Str::library_search);

    _heading.stringValue = strings::get(kPageTitles[_page]);
    _heading.textColor = theme.ink;
    NSArray<NSNumber*>* visible = [self visibleIndexes];
    _countLabel.stringValue = [NSString stringWithFormat:@"%ld %@",
        (long)visible.count, strings::get(Str::songs_suffix)];
    _countLabel.textColor = theme.ink_faint;

    _card.layer.backgroundColor = [theme.ink colorWithAlphaComponent:0.05].CGColor;
    _card.layer.borderColor = theme.border.CGColor;
    _emptyLabel.hidden = visible.count > 0;
    _emptyLabel.textColor = theme.ink_faint;
    _emptyLabel.stringValue = count == 0 ? strings::get(Str::library_empty)
        : _search.stringValue.length > 0 ? strings::get(Str::library_no_match)
        : _page == kPageFavorites ? strings::get(Str::menu_no_favorites)
        : strings::get(Str::library_empty);

    // Reordering only makes sense in the full, unfiltered list.
    _reorderable = _page == kPageAll && _search.stringValue.length == 0;
    _visible = visible;
    [_table reloadData];   // keeps the scroll position; builds visible rows only
}

// ---- Table ----------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return static_cast<NSInteger>(_visible.count);
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column
                 row:(NSInteger)row {
    id<PlayerQueueDelegate> q = [_host queueDelegate];
    if (q == nil || row < 0 || row >= static_cast<NSInteger>(_visible.count)) {
        return nil;
    }
    SongLibraryRow* view = [tableView makeViewWithIdentifier:@"song" owner:self];
    if (view == nil) {
        view = [[SongLibraryRow alloc] initWithOwner:self];
        __weak SongLibraryWindowController* weakSelf = self;
        view.onPick = ^(NSInteger index) {
            [weakSelf pickSong:index source:-1];
        };
    }
    [view configureWithQueue:q index:_visible[static_cast<NSUInteger>(row)].integerValue
                 reorderable:_reorderable count:[q queueCount]];
    return view;
}

- (BOOL)tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row {
    return NO;   // rows handle their own clicks and highlight
}

// ---- Actions ------------------------------------------------------------------

- (void)pickSong:(NSInteger)index source:(NSInteger)source {
    [_host libraryLoadSong:index source:source];
    [self reload];
}

- (void)sourceChanged:(NSPopUpButton*)popup {
    [self pickSong:popup.tag source:popup.selectedTag];
}

- (void)toggleFavorite:(NSControl*)sender {
    [[_host queueDelegate] queueToggleFavoriteAtIndex:sender.tag];
    [_host libraryQueueChanged];
    [self reload];
}

- (void)moveBy:(NSInteger)offset sender:(NSControl*)sender {
    if ([[_host queueDelegate] queueMoveIndex:sender.tag to:sender.tag + offset]) {
        [_host libraryQueueChanged];
        [self reload];
    }
}

- (void)moveUp:(NSControl*)sender { [self moveBy:-1 sender:sender]; }
- (void)moveDown:(NSControl*)sender { [self moveBy:1 sender:sender]; }

- (void)removeSong:(NSControl*)sender {
    [_host libraryRemoveSong:sender.tag];
    [self reload];
}

- (void)addSongs:(id)sender {
    [_host libraryAddSongs];
}

- (void)clearSongs:(id)sender {
    [_host libraryClearSongs];
    [self reload];
}

@end
