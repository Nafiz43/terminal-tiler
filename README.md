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
  - System Settings → Privacy & Security → Accessibility
  - Enable **osascript** (and Terminal if prompted)

Avoid macOS native fullscreen (green button / separate Space). The tiler works on normal desktop windows.

## Install (run at login)

```bash
chmod +x ~/Desktop/terminal-tiler
~/Desktop/terminal-tiler install
```

This installs a LaunchAgent (`com.user.terminal-tiler`) that starts on login and keeps running in the background.

If you already installed from `~/.local/bin/terminal-tiler`, that copy is what the agent uses until you reinstall from this Desktop path.

## Commands

```bash
./terminal-tiler              # watch in the foreground
./terminal-tiler once         # tile current windows, then exit
./terminal-tiler install      # install & start at login
./terminal-tiler start        # same as install
./terminal-tiler stop         # stop the background agent
./terminal-tiler uninstall    # stop and remove the LaunchAgent
./terminal-tiler status       # agent + window count
./terminal-tiler help
```

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
- Poll interval defaults to `0.6s`. Override with `TERMINAL_TILER_POLL` if needed.
- This is a small local automation script, not an App Store product.
