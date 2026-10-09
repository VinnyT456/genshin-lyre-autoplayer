#pragma once

#import <AppKit/AppKit.h>

// Supplies the settings as a menu: each top-level item with a submenu is one
// page (its image is the sidebar icon). The window renders items as controls:
//   submenu                 → dropdown (checked item = current choice)
//   identifier == "action"  → button
//   item with an action     → themed toggle (state = on/off)
//   item without an action  → caption
// Choosing a control invokes the menu item's own action with the item as the
// sender, so the menu and this window share one implementation.
@protocol SettingsWindowHost <NSObject>
- (NSMenu*)settingsMenu;
@end

// Marks a one-shot menu item (rendered as a button, not a toggle).
extern NSString* const kSettingsActionIdentifier;

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithHost:(id<SettingsWindowHost>)host;
// Rebuild from a fresh menu (state, language, or theme changed).
- (void)reload;
@end

// Shared themed pieces, reused by the song library window.
@interface SettingsSidebarRow : NSControl
@property(nonatomic, copy) NSString* title;
@property(nonatomic, strong) NSImage* icon;
@property(nonatomic) BOOL selected;
@end

// Rounded, bordered card that groups rows (vertical stack, theme-tinted).
NSStackView* settings_new_card();

// Paints the window and sidebar backgrounds with the current theme.
void settings_paint_chrome(NSWindow* window, NSView* root, NSView* sidebar);
