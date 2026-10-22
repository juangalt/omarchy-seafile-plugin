# Seafile for Omarchy

Bar widget for [Seafile](https://www.seafile.com/) / `seaf-cli` on [Omarchy](https://omarchy.org/).

It sits on top of an existing `seaf-cli` setup: status in the bar, sync now, pause/snooze, open folder, logs, and a terminal wizard to install or repair a library binding.

## Install

```bash
omarchy plugin add git@github.com:juangalt/omarchy-seafile-plugin.git --enable
```

Use the SSH URL (`omarchy plugin add` disables interactive HTTPS prompts).

Needs the `seafile` package (provides `seaf-cli`). The panel can install it with `yay` if it is missing.

## Use

| Action | What it does |
| --- | --- |
| Left-click icon | Open the panel |
| Middle-click | Sync now |
| Right-click | Refresh status |
| Pause switch | Stops the Seafile daemon (and your user `seaf-daemon.service` if present) |
| Snooze 15m / 1h | Pause, then auto-resume |
| Connect / repair | Terminal wizard: re-attach a saved library, or sign in and sync |

Server URLs need a scheme (`https://…` or `http://…`). The wizard adds `https://` if you omit it, and asks before using cleartext HTTP.

The public hostname (for example `https://seafile.zombie.enterprises`) is supported. Cloudflare sometimes blocks Python’s default User-Agent with error **1010**; the setup wizard sends a normal browser User-Agent so that host works like it does for you elsewhere.

## Important

- **One Seafile client.** Do not run `seafile-client` (GUI) alongside this. Both use the same data directory and will fight.
- **Pause stops the whole daemon**, not a single library. If you manage sync with `systemctl --user seaf-daemon.service`, the plugin stops that unit too.
- **Setup log:** `~/.local/state/omarchy/plugins/juangalt.seafile/setup.log` (mode `600`). Passwords are not written there; account email and server URL may be.

## Development

```bash
git clone git@github.com:juangalt/omarchy-seafile-plugin.git
# edit, then:
omarchy plugin update juangalt.seafile
# or symlink the clone into ~/.config/omarchy/plugins/juangalt.seafile
```

Validate: `omarchy plugin validate .`

## License

MIT — see [LICENSE](LICENSE).
