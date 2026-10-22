# Seafile for Omarchy

Bar widget for [Seafile](https://www.seafile.com/) / `seaf-cli` on [Omarchy](https://omarchy.org/).

## Install

```bash
omarchy plugin add git@github.com:juangalt/omarchy-seafile-plugin.git --enable
```

(`omarchy plugin add` disables interactive git prompts, so the SSH URL is the reliable option.)

Requires the AUR package `seafile` (provides `seaf-cli`). The panel can install it via `yay` if missing.

## Features

- Bar icon for sync / error / paused
- Sync now, pause, snooze (15m / 1h)
- Open synced folder, show daemon logs
- Terminal setup wizard for server + library

## Notes

Seafile syncs continuously; there is no native “sync every N minutes” setting. Snooze pauses the daemon temporarily.
