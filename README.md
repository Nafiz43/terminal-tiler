# terminal-tiler

Background helper for **macOS Apple Terminal**. When you open or close Terminal windows, it automatically resizes them so each gets an equal share of the screen.

## Layout

| Windows | Arrangement |
|--------:|-------------|
| 1 | Full usable screen |
| 2 | Two equal columns |
| 3 | Three equal columns |
| 4+ | Equal grid (e.g. 2×2 for four) |

Uses the main display’s visible area (menu bar and Dock are left free).

## Requirements

- macOS with **Apple Terminal** (`Terminal.app`)
- **Accessibility** permission for resizing windows:
  1. Open **System Settings → Privacy & Security → Accessibility**
  2. Click **+** and add **`/usr/bin/osascript`** (enable the checkbox)
  3. If macOS prompts again later, also allow **Terminal**

Avoid macOS native fullscreen (green button / separate Space). The tiler works on normal desktop windows.

## Install (run at login)

```bash
git clone https://github.com/Nafiz43/terminal-tiler.git
cd terminal-tiler
chmod +x terminal-tiler
./terminal-tiler install
./terminal-tiler status
```

That installs a LaunchAgent (`com.user.terminal-tiler`) that starts on login and keeps running in the background.

**One-shot tile (no install):**

```bash
./terminal-tiler once
```

## Commands

Run these from the repo directory (or pass the full path to `terminal-tiler`):

```bash
./terminal-tiler              # watch in the foreground
./terminal-tiler once         # tile current windows, then exit
./terminal-tiler install      # install & start at login
./terminal-tiler start        # same as install
./terminal-tiler stop         # stop the background agent
./terminal-tiler uninstall    # stop and remove the LaunchAgent
./terminal-tiler status       # agent + window count
./terminal-tiler snapshot     # print current window geometry (debug)
./terminal-tiler help
```

## Verify it works

1. Run `./terminal-tiler status` — should say `LaunchAgent: running`.
2. Open **Terminal → Shell → New Window** a few times.
3. Windows should snap into equal tiles within about a second.
4. If nothing moves, grant Accessibility (see Requirements) and run `./terminal-tiler once`.

## Logs

```
~/Library/Logs/terminal-tiler.log
```

## Uninstall

```bash
./terminal-tiler uninstall
```

## Notes

- Only manages **Apple Terminal** windows (not iTerm, Ghostty, Cursor’s integrated terminal, etc.).
- Windows are re-tiled whenever their geometry changes, not just when one opens or closes. Increasing the font size (`Ctrl` + `+`) grows an Apple Terminal window, since it sizes in character cells; the tiler snaps it back to its tile so only the text gets bigger. Manually resizing or dragging a window snaps back for the same reason.
- Poll interval defaults to `0.6s`. Override with `TERMINAL_TILER_POLL` if needed.
- This is a small local automation script, not an App Store product.

## Music terminal

The first Terminal window of a session opens a second window titled `music`, pinned to the top-left cell.
Keys: `1` Bhoot FM, `2` Sunday Suspense, `3` Tech Podcast, `n`/`b` next/back, `p` play/pause, `s` shuffle, `u` sync, `q` quit.
Audio is downloaded once with `yt-dlp` into `~/Music/TerminalTiler/` and played from Music.app playlists named `TT <show>`.

```bash
brew install yt-dlp ffmpeg
terminal-tiler music sync              # all shows; or: terminal-tiler music sync "Bhoot FM" 3
terminal-tiler music history           # favourites from Chrome history -> ~/.config/terminal-tiler/catalog.tsv
```

Edit `music/catalog.tsv` (show, count, YouTube search or URL, channel regex) to change the defaults.

## Rafin (coach)

`coach/Coach.swift` is a click-through glass card with a breathing star (lights up, dims) that slides in at the top-right:

- **Scroll guard:** 3 min of scrolling on a blocklisted Chrome site gets a warning; still scrolling 60 s later and the tab is closed (Cmd+Shift+T restores it).
- **Eye breaks:** 20-20-20 every 20 min of active input.
- **Low-activity nudges:** after 5 min without typing, rotates AI news TLDRs (TLDR AI/Tech, OpenAI, Anthropic), tech hard-work quotes, personal advice and a starter for the focused window.
- **Deadlines:** the next aideadlines.org deadline appears once a day, in the first greeting.
- **Greeting:** on login and after 30+ min away.

It stays quiet in Zoom/FaceTime/Teams/Webex/Keynote.

```bash
terminal-tiler coach install    # build + LaunchAgent (grant Accessibility; allow Chrome automation)
terminal-tiler coach demo | refresh | report | uninstall
```

Personal settings live in `~/.config/terminal-tiler/profile.json` (see `coach/profile.example.json`): name, advice, window-keyword starters, blocklist, priority conferences.
The repo must not live under `~/Desktop`, `~/Documents` or `~/Downloads`, because launchd agents cannot read those folders.
