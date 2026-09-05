#pragma once

#import <Foundation/Foundation.h>
#include <string>

// Two-language UI strings (English / Simplified Chinese), toggled at runtime.
enum class Lang { english, chinese };

// Message keys — one per user-visible string.
enum class Str {
    open_songs,
    no_song_selected,
    open_to_begin,
    lyre,
    songs_suffix,       // "songs" as in "12 songs"
    playing,
    paused,
    idle,
    no_song,
    counting_in,
    starting_in,        // "starting in %lld…" — caller appends
    // tooltips
    tip_collapse,
    tip_close,
    tip_add,
    tip_settings,
    tip_previous,
    tip_loop,
    tip_playpause,
    tip_stop,
    tip_next,
    tip_speed,
    tip_playlist,
    // menu
    menu_autopause,
    menu_reset_speed,
    menu_learn,
    menu_tempo_practice,
    menu_restart_phrase,
    menu_practice_insights,
    menu_theme,
    menu_language,
    menu_lang_english,
    menu_lang_chinese,
    // open panel
    panel_message,
    panel_add,
    learn_ready,
    learn_note,
    learn_complete,
    learn_wrong,
    learn_partial,
    learn_early,
    learn_late,
    learn_missed,
    dashboard_title,
    dashboard_no_data,
    dashboard_accuracy,
    dashboard_notes,
    dashboard_wrong,
    dashboard_partials,
    dashboard_chords,
    dashboard_response,
    dashboard_phrases,
    dashboard_mastered,
    dashboard_phrase,
    dashboard_best,
    dashboard_focus,
};

namespace strings {

Lang current();
void set_current(Lang lang);

// Localized string for a key.
NSString* get(Str key);

}  // namespace strings
