# Agent Guide

Bifrost is an unofficial Tailscale plugin for the KoolCenter/Koolshare 386/388
software center. Read `docs/PLAN.md` before changing the design.

## Hard Rules

- Use `bifrost` as the module and dbus prefix. Do not reuse the original
  plugin's `tailscale` module name, dbus keys, or file paths.
- Router scripts run under BusyBox `/bin/sh`. Avoid bashisms. Check with
  `busybox sh -n` and `shellcheck -s sh`.
- `core/recipe.json` is the only source of core build settings. Do not use
  Tailscale's `--extra-small`: it removes subnet routing. Do not UPX-compress
  the core by default.
- Do not copy scripts, pages, icons, or text from koolshare/rogsoft or other
  repositories without a compatible license.
- Never commit router addresses, tailnet names, credentials, private LAN
  details, or local absolute paths. Keep router access notes in
  `AGENTS.local.md` (gitignored). If it is missing, ask the user.
- Before changing a router, back up the files you replace and state the
  rollback. Stop plugins through their own scripts, not by killing processes.
