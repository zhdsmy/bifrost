# Third-Party Notices

Bifrost is an unofficial Tailscale plugin for the KoolCenter / Koolshare
software center. Bifrost is not affiliated with, endorsed by, or sponsored by
Tailscale Inc. or Cloudflare, Inc. Tailscale is a trademark of Tailscale Inc.

The Bifrost plugin code is released under the MIT License (see `LICENSE`).
The packages and web bundle include or adapt the following third-party
software:

## Bundled Core

- **Tailscale** (`tailscale.com`, v1.104.7)
  - License: BSD-3-Clause (full text in `LICENSE.tailscale`)
  - Built from official upstream source using the public recipe in
    `core/recipe.json`.

## Adapted Code (MIT)

- **po0fw (`asus-merlin/`, commit `0d9532d`)** — MIT License (same author)
  - Patterns and structure adapted in:
    - `plugin/bifrost/install.sh` (atomic web asset & ASP replacement, dbus registration)
    - `plugin/bifrost/uninstall.sh` (hashed asset cleanup, dbus removal)
    - `packaging/build.sh` (KoolCenter offline package structure)
    - `tests/install/t_install.sh` (BusyBox 1.25 install/upgrade/publish-failure/uninstall checks)
    - `.github/workflows/release.yml` (tag/branch/version validation and GitHub Release publishing)
    - `web/` build, Shadow DOM mount, preview server, and Playwright test fixtures (see `web/` file headers)

## Web Application Dependencies

The following runtime libraries are bundled into `bifrost-app.<hash>.js` and
`bifrost-app.<hash>.css` (exact versions to be verified against
`web/package-lock.json` before release):

- **@cloudflare/kumo** — MIT License (Cloudflare, Inc.; Bifrost is not affiliated with Cloudflare)
- **@base-ui/react** — MIT License
- **react** / **react-dom** — MIT License (Meta Platforms, Inc.)
- **tailwindcss** — MIT License (Tailwind Labs, Inc.)
- **@phosphor-icons/react** — MIT License (Phosphor Icons)
- **class-variance-authority** — Apache-2.0 License (when transitively bundled by Kumo)
- **QR code generator library** — MIT License (exact package name and version updated from `web/package-lock.json`)
