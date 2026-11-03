# Changelog

## 0.2.0

- Rename the plugin to Seafile Sync and refresh the marketplace hero preview.
- Add per-library auto sync and sync interval controls, including the last focused library from More.
- Improve Connect / repair to reuse saved identity and request only a password when necessary; force editing invalid saved server URLs.
- Keep account tokens and encrypted library passwords out of process arguments.
- Recover stuck daemons from Sync now and improve status settling.
- Bound live sync-settings reads and preserve cached settings if RPC stalls.
- Terminate and reap timed-out sync RPC workers so helpers can exit promptly.
- Kill sync RPC workers when the helper is terminated or dies, and keep Sync now within the bar watchdog budget.
- Isolate repair tests from user logs and cover timeout cleanup and cached-settings fallback.

## 0.1.0

- Initial Seafile status widget with sync, pause, snooze, folder and log actions, and Connect / repair.
