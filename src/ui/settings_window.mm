#import "settings_window.h"

#import <objc/runtime.h>

#include <algorithm>

#include "strings.h"
#include "theme.h"

NSString* const kSettingsActionIdentifier = @"settings.action";

namespace {

void invoke(NSMenuItem* item) {
    if (item.action != nullptr) {
        [NSApp sendAction:item.action to:item.target from:item];
    }
}

}  // namespace

// ---- Themed toggle switch ---------------------------------------------------

@interface ThemeToggle : NSControl
@property(nonatomic) BOOL on;
@property(nonatomic, strong) NSMenuItem* item;
@end

@implementation ThemeToggle

- (NSSize)intrinsicContentSize { return NSMakeSize(38, 22); }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const NSRect track = NSInsetRect(self.bounds, 1, 1);
    const CGFloat alpha = self.enabled ? 1.0 : 0.4;
    [(_on ? [theme.accent colorWithAlphaComponent:alpha]
          : [theme.ink colorWithAlphaComponent:0.16 * alpha]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:NSHeight(track) / 2
                                     yRadius:NSHeight(track) / 2] fill];
    const CGFloat d = NSHeight(track) - 4;
    const CGFloat x = _on ? NSMaxX(track) - d - 2 : NSMinX(track) + 2;
    [(_on ? [theme.on_accent colorWithAlphaComponent:alpha]
          : [theme.ink colorWithAlphaComponent:0.75 * alpha]) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, NSMinY(track) + 2, d, d)] fill];
}

- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled) {
        return;
    }
    _on = !_on;
    self.needsDisplay = YES;
    invoke(_item);
    [self sendAction:self.action to:self.target];   // let the window refresh
}

@end

// ---- Sidebar row --------------------------------------------------------------

@implementation SettingsSidebarRow

- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 34); }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    const Theme& theme = themes::current();
    const NSRect b = NSInsetRect(self.bounds, 6, 2);
    if (_selected) {
        [[theme.accent colorWithAlphaComponent:0.16] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7] fill];
        [theme.accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(b), NSMinY(b) + 7, 3, NSHeight(b) - 14)
                                         xRadius:1.5 yRadius:1.5] fill];
    }
    NSColor* color = _selected ? theme.accent : theme.ink_soft;
    CGFloat x = NSMinX(b) + 12;
    if (_icon != nil) {
        NSImage* tinted = [_icon imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
        tinted = [tinted copy];
        [tinted lockFocus];
        [color set];
        NSRectFillUsingOperation(NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
                                 NSCompositingOperationSourceAtop);
        [tinted unlockFocus];
        [tinted drawInRect:NSMakeRect(x, NSMidY(b) - tinted.size.height / 2,
                                      tinted.size.width, tinted.size.height)];
        x += 24;
    }
    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:_selected ? NSFontWeightSemibold
                                                                          : NSFontWeightMedium],
        NSForegroundColorAttributeName: color
    };
    const NSSize s = [_title sizeWithAttributes:attrs];
    [_title drawAtPoint:NSMakePoint(x, NSMidY(b) - s.height / 2) withAttributes:attrs];
}

- (void)mouseDown:(NSEvent*)event {
    [self sendAction:self.action to:self.target];
}

@end

// ---- Flipped container so pages lay out top-down in the scroll view --------

@interface SettingsFlippedView : NSView
@end

@implementation SettingsFlippedView
- (BOOL)isFlipped { return YES; }
@end

// ---- Shared chrome -------------------------------------------------------------

NSStackView* settings_new_card() {
    const Theme& theme = themes::current();
    NSStackView* card = [[NSStackView alloc] init];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeLeading;
    card.spacing = 0;
    card.edgeInsets = NSEdgeInsetsMake(6, 16, 6, 16);
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10;
    card.layer.backgroundColor = [theme.ink colorWithAlphaComponent:0.05].CGColor;
    card.layer.borderWidth = 1;
    card.layer.borderColor = theme.border.CGColor;
    return card;
}

void settings_paint_chrome(NSWindow* window, NSView* root, NSView* sidebar) {
    window.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0];
    root.layer.backgroundColor = themes::current().panel_tint.CGColor;
    sidebar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.22].CGColor;
}

// ---- Window -------------------------------------------------------------------

@implementation SettingsWindowController {
    __weak id<SettingsWindowHost> _host;
    NSView* _root;
    NSStackView* _sidebar;
    NSScrollView* _scroll;
    NSStackView* _page;
    NSInteger _selected;
    NSTimer* _timer;
    NSString* _signature;   // what the page was last built from
}

- (instancetype)initWithHost:(id<SettingsWindowHost>)host {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 600, 470)
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
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.contentMinSize = NSMakeSize(520, 360);
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    _root = [[NSView alloc] init];
    _root.wantsLayer = YES;
    panel.contentView = _root;

    _sidebar = [[NSStackView alloc] init];
    _sidebar.orientation = NSUserInterfaceLayoutOrientationVertical;
    _sidebar.alignment = NSLayoutAttributeLeading;
    _sidebar.spacing = 2;
    _sidebar.edgeInsets = NSEdgeInsetsMake(14, 4, 14, 4);
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebar.wantsLayer = YES;

    _page = [[NSStackView alloc] init];
    _page.orientation = NSUserInterfaceLayoutOrientationVertical;
    _page.alignment = NSLayoutAttributeLeading;
    _page.spacing = 14;
    _page.edgeInsets = NSEdgeInsetsMake(20, 22, 22, 22);
    _page.translatesAutoresizingMaskIntoConstraints = NO;
    SettingsFlippedView* document = [[SettingsFlippedView alloc] init];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:_page];

    _scroll = [[NSScrollView alloc] init];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = document;

    [_root addSubview:_sidebar];
    [_root addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:_root.topAnchor],
        [_sidebar.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor],
        [_sidebar.widthAnchor constraintEqualToConstant:178],
        [_scroll.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:_root.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor],
        [document.widthAnchor constraintEqualToAnchor:_scroll.contentView.widthAnchor],
        [_page.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [_page.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [_page.topAnchor constraintEqualToAnchor:document.topAnchor],
        [_page.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
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
    if (self.window.isVisible) {
        [self reloadIfChanged];
    }
}

// Rebuild only when something visible differs (state, enabled, titles, theme),
// so the periodic check never flickers or disturbs an open control.
- (void)reloadIfChanged {
    id<SettingsWindowHost> host = _host;
    if (host == nil) {
        return;
    }
    if (![[self signatureOf:[host settingsMenu]] isEqualToString:_signature]) {
        [self reload];
    }
}

- (NSString*)signatureOf:(NSMenu*)menu {
    NSMutableString* sig = [NSMutableString stringWithFormat:@"%s|%ld|",
        themes::current().id.c_str(), (long)_selected];
    for (NSMenuItem* item in menu.itemArray) {
        [sig appendFormat:@"%@:%ld:%d;", item.title, (long)item.state, item.enabled];
        if (item.hasSubmenu) {
            [sig appendString:[self signatureOf:item.submenu]];
        }
    }
    return sig;
}

- (void)toggleChanged:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; });
}

- (void)selectPage:(SettingsSidebarRow*)sender {
    _selected = sender.tag;
    [self reload];
    [_scroll.documentView scrollPoint:NSZeroPoint];
}

- (void)reload {
    id<SettingsWindowHost> host = _host;
    if (host == nil) {
        return;
    }
    const Theme& theme = themes::current();
    self.window.title = strings::get(Str::settings_title);
    settings_paint_chrome(self.window, _root, _sidebar);

    NSMenu* menu = [host settingsMenu];
    _signature = [self signatureOf:menu];
    NSMutableArray<NSMenuItem*>* sections = [NSMutableArray array];
    for (NSMenuItem* item in menu.itemArray) {
        if (item.hasSubmenu) {
            [sections addObject:item];
        }
    }
    if (sections.count == 0) {
        return;
    }
    _selected = std::clamp<NSInteger>(_selected, 0, sections.count - 1);

    // Sidebar.
    for (NSView* v in [_sidebar.arrangedSubviews copy]) {
        [v removeFromSuperview];
    }
    for (NSUInteger i = 0; i < sections.count; ++i) {
        SettingsSidebarRow* row = [[SettingsSidebarRow alloc] init];
        row.title = sections[i].title;
        row.icon = sections[i].image;
        row.selected = static_cast<NSInteger>(i) == _selected;
        row.tag = static_cast<NSInteger>(i);
        row.target = self;
        row.action = @selector(selectPage:);
        [_sidebar addArrangedSubview:row];
        [row.widthAnchor constraintEqualToConstant:170].active = YES;
    }

    // Page: rows grouped into cards at each separator.
    const NSPoint scroll = _scroll.contentView.bounds.origin;
    for (NSView* v in [_page.arrangedSubviews copy]) {
        [v removeFromSuperview];
    }
    NSTextField* heading = [NSTextField labelWithString:sections[_selected].title];
    heading.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    heading.textColor = theme.ink;
    [_page addArrangedSubview:heading];

    NSStackView* card = nil;
    for (NSMenuItem* item in sections[_selected].submenu.itemArray) {
        if (item.isSeparatorItem) {
            card = nil;
            continue;
        }
        if (card == nil) {
            card = [self newCard];
            [_page addArrangedSubview:card];
            [card.widthAnchor constraintEqualToAnchor:_page.widthAnchor
                                             constant:-(_page.edgeInsets.left + _page.edgeInsets.right)].active = YES;
        }
        NSView* row = [self rowForItem:item];
        [card addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:card.widthAnchor
                                        constant:-(card.edgeInsets.left + card.edgeInsets.right)].active = YES;
    }
    [_scroll.contentView scrollToPoint:scroll];
}

- (NSStackView*)newCard {
    return settings_new_card();
}

- (NSView*)rowForItem:(NSMenuItem*)item {
    const Theme& theme = themes::current();
    NSTextField* label = [NSTextField wrappingLabelWithString:item.title];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = item.enabled ? theme.ink : theme.ink_faint;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    // The label takes the slack, so every control lines up on the right edge.
    [label setContentHuggingPriority:1
                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSView* control = nil;
    if (item.hasSubmenu) {
        NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        NSInteger chosen = -1;
        for (NSMenuItem* option in item.submenu.itemArray) {
            if (option.isSeparatorItem) continue;
            [popup addItemWithTitle:option.title];
            popup.lastItem.representedObject = option;
            popup.lastItem.enabled = option.enabled;
            if (option.state == NSControlStateValueOn) chosen = popup.numberOfItems - 1;
        }
        popup.autoenablesItems = NO;
        if (chosen >= 0) [popup selectItemAtIndex:chosen];
        popup.target = self;
        popup.action = @selector(popupChanged:);
        popup.enabled = item.enabled;
        control = popup;
    } else if ([item.identifier isEqualToString:kSettingsActionIdentifier]) {
        NSButton* button = [NSButton buttonWithTitle:item.title target:self action:@selector(buttonPressed:)];
        button.bezelStyle = NSBezelStyleRounded;
        button.bezelColor = [theme.accent colorWithAlphaComponent:0.55];
        button.enabled = item.enabled;
        objc_setAssociatedObject(button, @selector(buttonPressed:), item, OBJC_ASSOCIATION_RETAIN);
        // A button carries its own title: it is the whole row, left-aligned.
        label = nil;
        control = button;
    } else if (item.action != nullptr) {
        ThemeToggle* toggle = [[ThemeToggle alloc] init];
        toggle.on = item.state == NSControlStateValueOn;
        toggle.enabled = item.enabled;
        toggle.item = item;
        toggle.target = self;
        toggle.action = @selector(toggleChanged:);
        control = toggle;
    } else {
        // Informational line (e.g. the safety note).
        label.font = [NSFont systemFontOfSize:11.5];
        label.textColor = theme.ink_faint;
    }

    NSStackView* row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    row.edgeInsets = NSEdgeInsetsMake(9, 0, 9, 0);
    if (label != nil) {
        [row addArrangedSubview:label];
    }
    if (control != nil) {
        [control setContentHuggingPriority:NSLayoutPriorityRequired
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [row addArrangedSubview:control];
    }
    return row;
}

- (void)popupChanged:(NSPopUpButton*)popup {
    invoke(popup.selectedItem.representedObject);
    dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; });
}

- (void)buttonPressed:(NSButton*)button {
    invoke(objc_getAssociatedObject(button, @selector(buttonPressed:)));
    dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; });
}

@end
