# Changelog

All notable changes to Bifrost will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
plugin versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Text on every tab balances its last line, so a description no longer ends with one word ("console.") or one Chinese character ("希。") alone. Browsers without `text-wrap: pretty` wrap as before.
- English UI: the route status "Awaiting approval" uses sentence case, like the other status values.
- The out-of-space error for a core update names plugin storage instead of JFFS, as the Diagnostics tab has since v0.2.6.
- README screenshots show the current page and plugin version.

### Fixed

- The environment check also reports a changed `--snat-subnet-routes` (`NoSNAT`). The daemon already restored it with the other three fixed settings, but the Overview tab did not warn about it.

## [0.2.8] - 2026-11-26

### Added

- Logging out records the device's tags. The login card and the Re-authenticate confirmation have a Request Previous Tags checkbox, checked by default when the device has tags, that requests them again with `--advertise-tags`, only from the control server that gave them. Without it, an interactive login made the router a device of the account that logged in and removed its tags. When the server refuses the tags, the page says so (`tags_rejected`) and asks to clear the checkbox and try again. An interactive login whose tags are refused can only time out; the expiry notice then mentions the tags. A login that succeeds without the requested tags shows a warning instead of the success message; headscale can do this with a user's auth key.

### Changed

- Page contract: `login` takes a third parameter and `relogin` one parameter, whether to request the previous tags. The status file has `self.tags` and `saved_tags`, and the login job data has `tags` and `tags_applied`.
- The fallback of Connect for a stopped device mentions the profile's advertised tags, which a login with Request Previous Tags sets, so Tailscale's check for unmentioned settings accepts it.

## [0.2.7] - 2026-11-26

### Changed

- English UI: buttons, links, card titles, and field labels use title case throughout. "Log out", "Open Core tab", "Log in to your tailnet", "Reset column widths", and the build recipe labels on the Core tab were the exceptions. Confirmation questions, status values, and descriptions keep sentence case.

### Fixed

- Logging out no longer clears the advertised routes, exit node, accepted routes, and device name. `tailscale logout` replaces the profile with a new one that has default settings, and the next login used those defaults. Bifrost now saves the four settings before logout, sets them on the new profile (again after each daemon start, since that profile is not saved until login), and the next login uses them. A change on the Settings tab while logged out replaces the saved value.
- After logging out, the Overview tab no longer briefly shows "fixed settings drifted": the fixed settings are set on the new profile right away instead of at the next watchdog check.
- Devices tab: the OS column is wide enough for "windows" and "android", and the English Handshake header no longer runs into the fade of the pinned Action column on a router-width page. Widths you set yourself are kept.
- Confirmation popovers balance their lines, so a Chinese sentence no longer leaves one character ("断。") alone on its last line.
- Settings: the unchecked "Advertise router LAN subnet" checkbox has a visible border in dark and light mode. Its border was about 1.2:1 against the card and is now about 4:1.

## [0.2.6] - 2026-11-26

### Changed

- Settings: each Save button is enabled only when its value differs from the stored one. The Save button for advertised routes is a secondary button like the others, and the routes description no longer starts with "when enabled", since the list is not a switch.
- Yes/no and on/off values are status badges, and names and numbers are text, on every tab: "not advertised" for the exit node on the Overview tab and "mapping varies by destination" on the Diagnostics tab are now badges, and the preferred DERP region on the Diagnostics tab is text with its latency, as on the Overview tab.
- Diagnostics: "JFFS free space" is now "plugin storage free space". It has always measured the partition that holds `/koolshare`, which is a USB disk on some routers.
- Overview: a device whose key never expires shows "Never" instead of "—".
- Devices: a peer without a WireGuard handshake yet shows "Not yet" instead of "Never". Idle peers have no handshake.
- Core tab: the build revision no longer shows the internal serial number (`r2 (#2)` is now `r2`).
- The copied diagnostics show the router's local time and offset next to the epoch seconds.

### Fixed

- The folded list of omitted features on the Core tab, and the advanced login options, no longer draw a second line on the left inside their box.
- Password managers no longer offer to fill the router login into the auth key field of the login card.

## [0.2.5] - 2026-11-26

### Added

- Core tab: the previous core backup shows its version, type, architecture, and size, and has a Delete button. The rollback confirmation names the version it restores. The tab also shows where the core is stored (router internal flash, external USB storage, or unknown, with the filesystem type) and the free space there.
- Core tab: the expected SHA-256 from the signed core manifest is shown under the hash command, and the arm64 switch explains when it helps.

### Changed

- The previous core is no longer kept on internal flash (jffs2, ubifs, yaffs, or an mtd/ubi device). Internal flash is small and shared with the firmware and other plugins. A failed update still restores the current core automatically; only the manual rollback is unavailable there. Upgrading the plugin removes a previous core that an older release left on internal flash.
- On other storage, the previous core is kept only when the free space left afterwards still holds one more copy of the current core (the next update unpacks beside it) plus 2 MB, the minimum the software center requires for upgrades.
- The UPX hint on the Core tab depends on the storage: on jffs2 or ubifs, the filesystem already compresses the uncompressed core, so UPX saves less than the file sizes suggest; on external storage, UPX is not needed to save space.
- Core tab layout: Update Core is the main button only when a newer core is known, and it is disabled when the last check found the core up to date. The type and architecture switches have their own group. Field pairs are tidier, and the list of omitted features is folded.
- Core tab values (architecture, core type, filesystem, previous backup) are plain text instead of badges. Outline badges (header version, advertised routes, path, omitted features) use the `kumo-line` border, the same as secondary buttons, so they stay visible in dark and light mode.
- Sizes use decimal units (1 MB = 1,000,000 bytes), as in the docs. They used 1024-based values with MB and GB labels before.
- Update checks and core downloads use the GitHub API (`api.github.com` and its file CDN) before `github.com`, which is often slow or blocked in some networks. A download mirror, when set, is still tried first, and now falls back to GitHub when it fails. The API allows 60 unauthenticated requests an hour per IP address; a check or an update uses about five, and `github.com` is used when the limit is reached. Signatures and hashes are checked as before.

### Fixed

- The Core tab no longer says that reinstalling the plugin package restores a missing previous core. A package with an older core does not replace a newer installed core.
- Updating when the channel offers the installed core now reports `up_to_date` ("already up to date") instead of `old_serial`, which said the channel core was older.

## [0.2.4] - 2026-11-25

### Changed

- Buttons are sized by their role, the same way as in po0fw. Main actions use the default size: the overview status card actions (Enable, Connect, Disable, Re-authenticate, Log out, Migrate & Switch, Open Core tab), the migrate card button, and the advertised-routes save button, which were small before. Helper actions (refresh and copy logs, jump to another tab, reset column widths), device-table actions, and confirmation popovers stay small.
- Card headers center their actions against the title and description instead of aligning them to the top.
- On narrow widths, the header icon stays next to the first line of the title instead of moving to the middle of a wrapped description.

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
