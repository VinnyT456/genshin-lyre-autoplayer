# Genshin Lyre Autoplayer

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
- **Plays sheets for you.** Open one or many `.genshinsheet` files (or a folder) as a playlist. Play / pause / stop, seek, loop, and change speed.
- **Shows what it's doing.** The 21-key lyre grid lights up in real time; a progress bar and a pulsing status dot track playback.
- **Plays by hand too.** Click keys on the HUD grid to send that note to Genshin yourself.
- **Feels human.** Variable key-hold and chord stagger, a 3-second count-in before it starts, and auto-advance to the next song.
- **Stays targeted.** Keystrokes are posted only to the Genshin process (`CGEventPostToPid`) — nothing is injected into the game.

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

Then in the HUD: **Open songs…** → pick `.genshinsheet` files (export them from [Genshin Music](https://specy.github.io/genshinMusic/)) → press play. A 3-second count-in runs, then the keys go to Genshin.

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
| Loop | Repeat the current song |
| Prev / next | Skip within the playlist (shown when 2+ songs loaded) |
| Seek bar | Click or drag to scrub |
| Speed button | Click to cycle presets (0.5× → 2×); scroll over the HUD for fine steps (0.25×–3×) |
| Click a lyre key | Send that note to Genshin manually |
| `+` (header) | Add more songs to the playlist |
| Chevron | Collapse to a mini bar |
| `×` | Hide the HUD and stop |
| Drag the HUD | Move it anywhere; it starts docked top-right and keeps your spot as the game window moves |
| Right-click HUD | Toggle auto-pause-on-blur, reset speed |

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
./macauto.out song.genshinsheet folder/
./macauto.out --no-hud song.genshinsheet
```

Quote paths that contain spaces or `()`. The playlist is remembered between launches; with no arguments the HUD restores the last one.

### Local settings

HUD state — the playlist, collapsed toggle, and auto-pause preference — is saved to **`hud-settings.json` next to the binary** (the project root), not in macOS preferences. It's per-user and machine-local: nothing is shared or committed (the file is git-ignored), so it never carries your songs to anyone else. Delete the file to reset.

## Accessibility (required — no keys without it)

Sending keystrokes to Genshin (`CGEventPostToPid`) is gated by macOS's **Accessibility** permission for the process that's running. Grant it to the terminal you launch from, or the first play will silently do nothing:

1. Run it once. When prompted, click **Open Accessibility Settings** (or open System Settings → Privacy & Security → Accessibility yourself).
2. Enable your terminal (Terminal, iTerm, etc.) in the list.
3. Relaunch and try again.

## Sheets

The parser currently accepts **[Specy's Genshin Music](https://specy.github.io/genshinMusic/)** `.genshinsheet` JSON (`name`, `bpm`, `notes`). Export from the [Player](https://specy.github.io/genshinMusic/); note indices 0–20 map to `Q…M` as shown above. Other formats are planned.

## How it works

- **PlayerWindow** (`src/PlayerWindow.mm`) — the HUD: a borderless `NSPanel` at screen-saver window level, custom-drawn lyre grid / seek bar / status dot, window-follow and focus logic.
- **PlaybackController** (`src/playback_controller.cpp`) — a worker thread that fires notes on schedule; handles play/pause/stop, seek, loop, speed, and count-in.
- **parser** (`src/parser.cpp`) — `.genshinsheet` → timed `Note`s.
- **keyboard** (`src/keyboard.mm`) — posts `CGEvent` key presses to the Genshin pid, with human-like jitter.
- **genshin** (`src/genshin.mm`) — locates and focuses the Genshin process.
- **settings** (`src/settings.cpp`) — reads/writes the local `hud-settings.json`.

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
