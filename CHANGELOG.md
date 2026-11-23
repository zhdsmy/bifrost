# Changelog

All notable changes to Bifrost will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
plugin versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- Initial Bifrost plugin for KoolCenter / Koolshare software center (HND platform).
- Reproducible core build recipe (`core/recipe.json`, Tailscale v1.104.7, 25 omitted feature tags, no UPX, gzipped in offline packages).
- Open-source BusyBox `/bin/sh` runtime, daemon watchdog, login/pre-auth key/headscale client support, settings management, and one-click migration from the original plugin with automatic rollback.
- Dedicated `BIFROST_*` IPv4/IPv6 firewall chains (`--netfilter-mode=off`) with local access toggle, LAN masquerade, configurable inbound SNAT (`auto` / `on` / `off`), and dnsmasq MagicDNS forwarding.
- ECDSA P-256 + SHA-256 signed core update checks, anti-downgrade `serial` enforcement, automatic rollback on startup failure, and manual rollback support.
- Kumo-based Shadow DOM web UI with 5 tabs (Overview, Devices, Settings, Core, Diagnostics), Simplified Chinese / English switching, dark / light / system modes, and redacted diagnostic export.
- Atomic installer/upgrader (`install.sh`), clean uninstaller (`uninstall.sh`) preserving `/koolshare/configs/bifrost/`, reproducible packaging (`packaging/build.sh`), BusyBox 1.25 shell & install tests, headscale v0.29.7 container integration suite, and GitHub Actions CI/release workflows.
