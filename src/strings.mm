#include "strings.h"

#include <unordered_map>

namespace strings {
namespace {

Lang g_lang = Lang::english;

const std::unordered_map<Str, NSString*>& table_en() {
    static const std::unordered_map<Str, NSString*> t = {
        {Str::open_songs,       @"Open songs…"},
        {Str::no_song_selected, @"No song selected"},
        {Str::open_to_begin,    @"open a song to begin"},
        {Str::lyre,             @"Lyre"},
        {Str::songs_suffix,     @"songs"},
        {Str::playing,          @"playing"},
        {Str::paused,           @"paused"},
        {Str::idle,             @"idle"},
        {Str::no_song,          @"no song"},
        {Str::counting_in,      @"counting in"},
        {Str::starting_in,      @"starting in"},
        {Str::tip_collapse,     @"Collapse / expand"},
        {Str::tip_close,        @"Close and quit"},
        {Str::tip_add,          @"Add songs"},
        {Str::tip_settings,     @"Settings"},
        {Str::tip_previous,     @"Previous"},
        {Str::tip_loop,         @"Loop"},
        {Str::tip_playpause,    @"Play / Pause"},
        {Str::tip_stop,         @"Stop"},
        {Str::tip_next,         @"Next"},
        {Str::tip_speed,        @"Playback speed — click to cycle, scroll to fine-tune"},
        {Str::tip_playlist,     @"Playlist"},
        {Str::menu_autopause,   @"Auto-pause when Genshin loses focus"},
        {Str::menu_reset_speed, @"Reset speed to 1×"},
        {Str::menu_theme,       @"Theme"},
        {Str::menu_language,    @"Language"},
        {Str::menu_lang_english,@"English"},
        {Str::menu_lang_chinese,@"中文"},
        {Str::panel_message,    @"Choose .genshinsheet files or folders"},
        {Str::panel_add,        @"Add"},
    };
    return t;
}

const std::unordered_map<Str, NSString*>& table_zh() {
    static const std::unordered_map<Str, NSString*> t = {
        {Str::open_songs,       @"打开乐谱…"},
        {Str::no_song_selected, @"未选择乐曲"},
        {Str::open_to_begin,    @"打开乐谱以开始"},
        {Str::lyre,             @"风物之诗琴"},
        {Str::songs_suffix,     @"首"},
        {Str::playing,          @"播放中"},
        {Str::paused,           @"已暂停"},
        {Str::idle,             @"空闲"},
        {Str::no_song,          @"无乐曲"},
        {Str::counting_in,      @"准备中"},
        {Str::starting_in,      @"倒计时"},
        {Str::tip_collapse,     @"折叠 / 展开"},
        {Str::tip_close,        @"关闭并退出"},
        {Str::tip_add,          @"添加乐曲"},
        {Str::tip_settings,     @"设置"},
        {Str::tip_previous,     @"上一首"},
        {Str::tip_loop,         @"循环"},
        {Str::tip_playpause,    @"播放 / 暂停"},
        {Str::tip_stop,         @"停止"},
        {Str::tip_next,         @"下一首"},
        {Str::tip_speed,        @"播放速度 — 点击切换，滚动微调"},
        {Str::tip_playlist,     @"播放列表"},
        {Str::menu_autopause,   @"原神失去焦点时自动暂停"},
        {Str::menu_reset_speed, @"重置速度为 1×"},
        {Str::menu_theme,       @"主题"},
        {Str::menu_language,    @"语言"},
        {Str::menu_lang_english,@"English"},
        {Str::menu_lang_chinese,@"中文"},
        {Str::panel_message,    @"选择 .genshinsheet 文件或文件夹"},
        {Str::panel_add,        @"添加"},
    };
    return t;
}

}  // namespace

Lang current() { return g_lang; }
void set_current(Lang lang) { g_lang = lang; }

NSString* get(Str key) {
    const auto& t = (g_lang == Lang::chinese) ? table_zh() : table_en();
    const auto it = t.find(key);
    return it != t.end() ? it->second : @"";
}

}  // namespace strings
