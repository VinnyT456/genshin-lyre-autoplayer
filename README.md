# Genshin Lyre Autoplayer

<p align="center">
  <strong>English</strong> | <a href="README.zh-CN.md">简体中文</a>
</p>

A native macOS HUD that plays the Genshin Impact lyre for you by posting keystrokes to the game.

**This is built specifically for [PlayCover](https://playcover.io/) Genshin on Apple Silicon Macs** — it drives the game through PlayCover's keyboard keymapping and finds the PlayCover "Genshin Impact" window. It is a separate floating panel docked next to that window and **does not inject into, modify, or read the game process**. It will not work with the official mobile/PC client, cloud versions, or anything that isn't the PlayCover build on macOS.

<p align="center">
  <img src="assets/HUD.png" alt="Genshin Lyre Autoplayer HUD" width="440">
</p>

<p align="center">
  <em>The HUD follows the Genshin window, lights each lyre key as it plays, and hides itself when Genshin isn't focused.</em>
</p>

### Demo

https://github.com/user-attachments/assets/bd77c3c4-1861-40bd-bfb5-8b45bca6b689

If the video doesn't play inline, download <a href="assets/demo.mp4">assets/demo.mp4</a>.

---

> [!WARNING]
> **Use at your own risk. Automating gameplay can get your account banned.**
> This tool posts synthetic keystrokes to Genshin Impact, which likely violates
> HoYoverse's Terms of Service. It is still in **early development**, so whether
> or not it triggers bans is **not known for certain** — there is no guarantee
> either way. If you use it, you accept that risk entirely. Consider a throwaway
> account, and don't use it on anything you'd hate to lose.

---

## What it does

- **Docks to Genshin.** Starts at the game window's top-right and follows it as it moves; drag it anywhere and it keeps your spot. Hides when Genshin isn't frontmost.
- **Plays songs for you.** Open one or many `.genshinsheet`, `.mid`, or `.midi` files (or a folder) as a playlist. Matching sheet and MIDI files in the same folder are grouped as one song, with the alternate version selectable in the [song library](#song-library). Play / pause / stop, seek, loop, and change speed.
- **Shows what it's doing.** The 21-key lyre grid lights up in real time; a progress bar and a pulsing status dot track playback.
- **Helps you learn.** Learn mode breaks a song into phrase-sized groups, highlights the expected note or chord, and advances only when you play it from the keyboard or HUD, without automatic playback. Turn on **Practice at song speed** to follow the song's timestamps with early, late, and missed-note feedback. A phrase is **mastered** after three clean runs in a row. See [Practice mode](#practice-mode) for everything it can do. Loop always repeats the currently loaded song.
- **Highlights keys on the game's lyre.** During practice, the next key glows right on Genshin's own lyre, styled to the HUD theme — solid while Learn mode waits for you, fading out over the timing window at song speed. Calibrate once by clicking Q and M.
- **Plays by hand too.** Click keys on the HUD grid to send that note to Genshin yourself.
- **Feels human.** Variable key-hold and chord stagger, a 3-second count-in before it starts, and auto-advance to the next song.
- **Stays targeted.** Keystrokes are posted only to the Genshin process (`CGEventPostToPid`) — nothing is injected into the game.
- **Can play in the background by default.** Playback keeps running without bringing Genshin to the foreground, while the HUD follows Genshin's focus and reappears when Genshin returns. Disable **Play in Background** in the HUD's Playback settings for foreground-only playback. Input remains process-targeted and never falls back to global posting.

## Practice mode

Learn mode turns the HUD into a lyre teacher. Everything below lives on the **Practice** page of the Settings window (gear button).

**Drilling**
- **Loop phrase until mastered** — a phrase repeats in place until you play it cleanly three times in a row, then moves on.
- **Click a phrase to loop it** — click any column in Practice Insights' phrase chart to jump straight there and loop it; click it again to release.
- **Drill weakest phrases** — picks your five weakest phrases across the whole playlist (from saved history) and runs through them one by one, switching songs as needed and moving on as each is mastered.

**Tempo**
- **Gradual speed-up** — Off, climb from your current speed, or restart every run at 50% / 60% / 75% and gain 0.05× per clean phrase until full speed.
- **Timing difficulty** — Easy (350 ms early / 700 ms miss), Normal (220 / 450 ms), or Strict (120 / 250 ms, and both keys of a chord must land within 120 ms).
- **Metronome** — *Note cues* ticks as each timed note becomes due; *Steady beat* clicks on the song's BPM (accented downbeat, count-in included).

**Feedback**
- **Streak** — consecutive correct notes; the HUD shows it once you reach 5.
- **Session summary** — when a run ends (stop or finish), Practice Insights opens with your grade, accuracy, change vs. your best, best streak, and weakest phrase. Turn it off with **Show summary after practice**.
- **Practice Insights** — a letter grade (S–D), accuracy vs. your previous best, phrases mastered, notes, wrong keys, response time, streak, partial chords, and clean runs on the current phrase, plus:
  - a **timing breakdown** (on time / early / late / missed) and a histogram of how far each note landed from the beat, with a *rushing / dragging / on the beat* verdict;
  - a **progress chart** of your accuracy over the last 30 sessions;
  - a **phrase heatmap** colored by accuracy, with dashed lines marking your best from before this session so you can see yourself beat it.

Each press of play after a stop starts a new session; history (bests, per-phrase bests, and the session log) is saved locally per song title, even if Insights is never opened.

## Song library

Click the song name on the HUD to open the **Song library**, a themed window laid out like Settings:

- **All songs / Favorites / Recently played** in the sidebar, with **Open songs…** and **Clear playlist** underneath.
- **Search** filters by title as you type (case- and accent-insensitive, works with Chinese and Japanese titles).
- Each row shows the song's position, title, file type, BPM, and how many versions it has; the current song is highlighted. Click a row to load it.
- Hover a row for its controls: **★** favorite, **⌃ / ⌄** move it up or down the playlist (All songs, unfiltered), and **×** remove it (asks first; files are never deleted). Songs with both a `.genshinsheet` and a `.mid` get a version picker.

Right-click the song name for the quick playlist menu instead.

## Key highlights

With **Key highlights** on (Settings → Key highlights), practice runs light up the expected key on Genshin's lyre itself. Each HUD theme has its own highlight design.

- **Calibrate keys…** — click the center of Q, then M; all 21 positions are derived and shown for review. Before saving you can fix any key on its own: **drag** a ring to move it, **scroll** over it (or press **+ / −**) to resize, and use the **arrow keys** to nudge the selected key by 1 pt (**⇧** for 10 pt); **Tab** steps through keys. Enter saves, R redoes, Esc cancels. Calibration is stored as fractions of the game picture, so it survives moving or resizing the window.
- **Adjust keys…** — open the current layout straight in that review step to fine-tune individual keys without redoing the Q / M clicks.
- **Preview key positions** — rings and letters on every key to check alignment.
- **Reset key calibration** — return to the built-in map (measured on a 16:10 windowed game).

## Background input

Background input depends on the installed PlayCover version accepting targeted keyboard events while its Genshin process is inactive. If PlayCover only handles mapped input while active, use foreground playback; this app will still never post keys globally.

## Requirements

- macOS on **Apple Silicon**
- [PlayCover](https://playcover.io/) + Genshin Impact
- Xcode Command Line Tools (`xcode-select --install`) — provides `clang++` and the macOS SDK. Full Xcode is not required.
- [nlohmann/json](https://github.com/nlohmann/json) — `brew install nlohmann-json`
- **Accessibility permission** for the terminal you run it from (System Settings → Privacy & Security → Accessibility)

## Quick start

```bash
brew install nlohmann-json
make build
make run
```

Then in the HUD: **Open songs…** → pick `.genshinsheet` or MIDI files (export sheets from [Genshin Music](https://specy.github.io/genshinMusic/)) → press play. A 3-second count-in runs, then the keys go to Genshin.

> First, import the keymap and equip the lyre — see [PlayCover keymap](#playcover-keymap) below. Without it, the synthetic keys never reach the lyre.

## PlayCover keymap

PlayCover maps keyboard keys to the on-screen lyre buttons. This project ships `Genshin Impact.playmap` (bundle `com.miHoYo.GenshinImpact`) for the standard 21-key layout:

```
Q  W  E  R  T  Y  U
A  S  D  F  G  H  J
Z  X  C  V  B  N  M
```

Import it in PlayCover's keymapping for Genshin, then equip the lyre in-game.

## HUD controls

| Control | Action |
| --- | --- |
| Play / pause | Start or pause (3-second count-in on play) |
| Stop | Stop and rewind |
| Loop | Repeat only the currently loaded song; do not advance the playlist |
| Prev / next | Skip within the playlist (shown when 2+ songs loaded) |
| Seek bar | Click or drag to scrub |
| Speed button | Click to cycle presets (0.5× → 2×); scroll over the HUD for fine steps (0.25×–3×) |
| Click a lyre key | Send that note to Genshin manually |
| Now / Next practice cue | See the expected note and optional upcoming note without leaving the HUD |
| Learn mode (Practice menu) | Practice the current song note-by-note; automatic playback is disabled |
| Practice at song speed (Practice menu) | Follow the song's timing at the selected speed with early/late/missed feedback |
| Gradual speed-up (Practice menu) | Off, climb from the current speed, or start each run at 50/60/75% and gain 0.05× per clean phrase up to 1× |
| Timing difficulty (Practice menu) | Easy, Normal, or Strict timing windows for song-speed practice |
| Loop phrase until mastered (Practice menu) | Repeat each phrase until three clean runs in a row |
| Drill weakest phrases (Practice menu) | Practice your five weakest phrases across the playlist, one after another |
| Show summary after practice (Practice menu) | Open Practice Insights with a recap when a run ends |
| Practice timing offset (settings menu) | Compensate for input/display latency from −150 ms to +150 ms |
| Count-in (settings menu) | Choose no count-in or 1–5 seconds |
| Metronome (Practice menu) | Off, *Note cues* (tick as each timed note is due), or *Steady beat* on the song's BPM |
| Reduce motion (settings menu) | Disable HUD shimmer, pulsing, and collapse animations |
| High contrast (Accessibility menu) | Strengthen key borders and labels without changing the active theme |
| Practice Insights (Practice menu) | Grade, accuracy vs. best, streak, timing histogram, progress chart, and a clickable phrase heatmap |
| Song name (click) | Open the song library: browse, search, favorite, reorder, remove, and pick versions |
| Song name (right-click) | Quick playlist menu: reorder, favorite, remove, clear, recent songs, favorites only |
| Restart phrase (Practice menu / `⌘↩`) | Return to the beginning of the current inferred phrase |
| `+` (header) | Add more songs to the playlist |
| Chevron | Collapse to a mini bar |
| `×` | Hide the HUD and stop |
| Drag the HUD | Move it anywhere; it starts docked top-right and keeps your spot as the game window moves |
| Gear (header) | Open the Settings window: Practice, Key highlights, Playback, and Appearance pages |
| Right-click HUD | The same settings as a quick menu |

**Global hotkeys** (while Genshin is focused): `⌘⌥Space` play/pause · `⌘⌥.` stop · `⌘⌥L` loop · `⌘⌥H` raise HUD.

## Running from the terminal

```bash
make run                                  # HUD; open songs from the UI
make run SHEET="path/to/song.genshinsheet"  # HUD with a sheet queued
make run SHEET="path/to/folder"             # HUD with a folder queued
make run SHEET="path/to/song.genshinsheet" NO_HUD=1   # headless autoplay
```

Or call the binary directly:

```bash
./macauto.out
./build/macauto.out song.genshinsheet song.mid folder/
./build/macauto.out --no-hud song.mid
```

Quote paths that contain spaces or `()`. The playlist is remembered between launches; with no arguments the HUD restores the last one.

### Local settings

HUD state — the playlist, collapsed toggle, background-playback and other playback/practice preferences, favorites, and practice dashboard history — is saved to **`build/hud-settings.json` next to the binary**, not in macOS preferences. Practice history — best accuracy, per-phrase bests, and a log of your last 30 sessions per song — is stored under the native `practice_history` JSON object. It's per-user and machine-local: nothing is shared or committed (the file is git-ignored), so it never carries your songs to anyone else. Delete the file to reset.

## Accessibility (required — no keys without it)

Sending keystrokes to Genshin (`CGEventPostToPid`) is gated by macOS's **Accessibility** permission for the process that's running. Grant it to the terminal you launch from, or the first play will silently do nothing:

1. Run it once. When prompted, click **Open Accessibility Settings** (or open System Settings → Privacy & Security → Accessibility yourself).
2. Enable your terminal (Terminal, iTerm, etc.) in the list.
3. Relaunch and try again.

## Supported song files

The parser accepts **[Specy's Genshin Music](https://specy.github.io/genshinMusic/)** `.genshinsheet` JSON and PPQ-based Standard MIDI Files in formats 0 and 1 (`.mid` / `.midi`). MIDI note-on events are converted to timed chords using the file's division and tempo map. When a valid MIDI key signature is present, notes are uniformly transposed toward C major or A minor and then shifted by octaves to maximize playable lyre notes. Non-standard key-signature metadata is ignored so otherwise valid MIDI files can still load. Only the lyre's 21 natural notes, C3–B5 (`Z…M`, `A…J`, `Q…U`), can be played exactly; remaining accidentals and out-of-range pitches are skipped. Notes that start within 30 ms of each other (common in humanized MIDI and recorded sheets) are merged into one chord, so they're played — and practiced — together.

## How it works

- **PlayerWindow** (`src/ui/PlayerWindow.mm`) — the HUD: a borderless `NSPanel` at screen-saver window level, custom-drawn lyre grid / seek bar / status dot, window-follow and focus logic.
- **Settings window** (`src/ui/settings_window.mm`) — themed pages rendered from the HUD's settings menu, so both always match.
- **Song library** (`src/ui/song_library.mm`) — the themed playlist browser.
- **Key overlay** (`src/ui/key_overlay.mm`, `key_layout.mm`, `key_calibration.mm`) — click-through highlights over the game window, per-theme designs, and click-to-calibrate.
- **Practice Insights** (`src/ui/practice_dashboard.mm`) — grade, timing, progress, and phrase heatmap.
- **PlaybackController** (`src/playback/playback_controller.cpp`) — a worker thread that fires notes on schedule; handles play/pause/stop, seek, loop, speed, count-in, and practice scoring.
- **parser** (`src/playback/parser.cpp`) — `.genshinsheet` / MIDI → timed `Note`s.
- **keyboard** (`src/app/keyboard.mm`) — posts `CGEvent` key presses to the Genshin pid, with human-like jitter.
- **genshin** (`src/app/genshin.mm`) — locates and focuses the Genshin process.
- **settings** (`src/app/settings.cpp`) — reads/writes the local `hud-settings.json`.

## Status

**Early development.** Expect rough edges, changing behavior, and bugs. Features and file formats may change without notice.

## Credits

- **[PlayCover](https://playcover.io/)** — the tool that runs Genshin (and other iOS apps) on Apple Silicon macOS and provides the keyboard keymapping this project drives. This project only works because of it.
- **[Specy's Genshin Music](https://specy.github.io/genshinMusic/)** ([source](https://github.com/Specy/genshin-music)) — the sheet editor/player and the `.genshinsheet` format this tool reads.
- **[nlohmann/json](https://github.com/nlohmann/json)** — JSON parsing.

This is a fan-made, unofficial project. It is **not affiliated with, endorsed by, or connected to HoYoverse/miHoYo, PlayCover, or Specy.** "Genshin Impact" and related marks belong to their respective owners.

## Disclaimer

Provided "as is", without warranty of any kind. Using it to automate gameplay may violate HoYoverse's Terms of Service and **could result in account suspension or a ban** — see the warning at the top. You use this software entirely at your own risk; the author accepts no liability for anything that happens to your account or system.

## License

MIT — see [`LICENSE`](LICENSE).
