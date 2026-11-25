# Changelog

All notable changes to Bifrost will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
plugin versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.3] - 2026-11-25

### Changed

- App shell: the header and page padding match the po0fw layout so both plugins read as one family in the software center. The header keeps a fixed 24px padding at every width, shows a 44px icon without an extra rounded crop, uses a larger title, and centers the language, theme, and back controls (now at the default size) against the title block. The tabs strip, error banners, and content area keep the same 24px horizontal padding instead of shrinking on narrow widths.

## [0.2.2] - 2026-11-25

### Changed

- Devices tab: columns have set widths per language, smaller headers, and long device names stay on one line with an ellipsis (hover shows the full name). Drag a column edge in the header, or focus it and use the arrow keys, to change a width. Double-click an edge to reset that column. The widths are kept in the browser; "Reset column widths" restores the defaults.
- Diagnostics tab: DERP latencies are a compact list instead of a two-column table. Each region shows its code, a latency bar on a shared scale, and the time in ms, in up to three columns. The preferred region is highlighted. At most 10 rows show; the rest scroll inside the list.

## [0.2.1] - 2026-11-25

### Fixed

- After the daemon started without a cached network map (a restart, a core update, or an upgrade), the firewall was applied before the tailnet address was known. The DNAT rules for the router admin page over the tailnet were missing until the next watchdog run, up to 2 minutes later. The start sequence now waits up to 10 seconds for the first network map.

## [0.2.0] - 2026-11-24

### Added

- Optional UPX core (`upx 5.3.0 --best --no-lzma`) for `arm` and `arm64`, as online assets from `core-1.104.7-2` and as `hnd-upx` / `hnd-arm64-upx` offline packages. The uncompressed core stays the default: the UPX core file is about a third of the size, but each CLI call takes about 0.33 s instead of 0.02 s on an RT-AX86U.
- Core type switching on the Core tab, through the signed update transaction with automatic rollback.
- A silent background update check when the page opens and the last check is more than 24 hours old. The result is kept on JFFS. The Core tab shows a new core and a new plugin version (with a release-page link); installing stays manual.
- A signed `plugin.json` on the `channel-stable` release, published by `release.yml`.
- `upstream-follow.yml`: once a day, when Tailscale publishes a new stable release, it updates the recipe and the full feature-tag list, builds the cores, runs them under qemu-user, runs the container tests, commits to `main`, and starts `core.yml`. Failed checks and new feature tags open issues.
- `core.yml` runs all four cores under qemu-user, can be started by hand for an existing tag, and opens an issue when a manual run fails.

### Changed

- Core manifests keep the v0.1.0 `.assets` shape and list UPX files in a new top-level `upx_assets` field, which v0.1.0 ignores.
- An offline package now replaces an installed core with the same serial, so the package's architecture and core type apply. An identical core is not written again.

## [0.1.0] - 2026-11-24

### Added

- Initial Bifrost plugin for the KoolCenter / Koolshare software center (HND platform).
- Reproducible core build recipe (`core/recipe.json`, Tailscale v1.104.7, 25 omitted feature tags, no UPX, gzipped inside offline packages).
- Open-source BusyBox `/bin/sh` runtime, daemon watchdog, settings management, and interactive, pre-auth key, and headscale client login.
- Migration from the original plugin: stops the original plugin through its own script, disables its autostart, copies state read-only, rebuilds the firewall to clear leftover NAT rules, and restores the original service automatically if verification fails.
- Dedicated `BIFROST_*` IPv4/IPv6 firewall chains (`--netfilter-mode=off`) with local access toggle, LAN masquerade, configurable inbound SNAT (`auto` / `on` / `off`), and dnsmasq MagicDNS forwarding.
- Crash recovery for core updates and migrations interrupted by signals or power loss: flash journals complete or roll back at boot, and an interrupted migration restores the original plugin.
- ECDSA P-256 + SHA-256 signed core update checks, monotonic `serial` anti-downgrade enforcement, automatic rollback on startup failure, and manual rollback support.
- Kumo-based Shadow DOM web UI with 5 tabs (Overview, Devices, Settings, Core, Diagnostics), Simplified Chinese / English switching, dark / light / system modes, and redacted diagnostic export.
- Atomic installer/upgrader (`install.sh`), uninstaller (`uninstall.sh`) preserving `/koolshare/configs/bifrost/`, reproducible packaging (`packaging/build.sh`), BusyBox 1.25 shell and install tests, headscale v0.29.7 container integration suite, and GitHub Actions CI/release workflows.
- System-log events for daemon exits, firewall repairs, init hooks, migration results, and page jobs, with redacted exit records retained across reboots.
