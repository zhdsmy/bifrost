# Third-Party Notices

Bifrost is an unofficial Tailscale plugin for the KoolCenter / Koolshare
software center. Bifrost is not affiliated with, endorsed by, or sponsored by
Tailscale Inc. or Cloudflare, Inc. Tailscale is a trademark of Tailscale Inc.

The Bifrost plugin code is released under the MIT License (see `LICENSE`).
Packages and web bundles include or adapt the following third-party software:

## Bundled Core (`bifrostd`)

- **Tailscale** (`tailscale.com`, v1.104.7)
  - License: BSD-3-Clause (full text in `LICENSE.tailscale`)
  - Built from official upstream source using the public recipe in
    `core/recipe.json`.
- **Statically linked Go modules** (including `github.com/tailscale/wireguard-go`,
  `golang.org/x/*`, `github.com/google/nftables`, `github.com/coreos/go-iptables`,
  `github.com/aws/aws-sdk-go-v2/*`, etc.):
  - The module inventory and accompanying license and notice texts derived
    from `go version -m` and the corresponding module sources are shipped in `THIRD_PARTY_NOTICES.core.md`
    (`packaging/THIRD_PARTY_NOTICES.core.md` in this repository).

## Adapted Code (MIT)

- **po0fw (`asus-merlin/`, commit `0d9532d`)** — MIT License (same author)
  - Patterns and structure adapted in:
    - `plugin/bifrost/install.sh` (atomic web asset & ASP replacement, dbus registration)
    - `plugin/bifrost/uninstall.sh` (hashed asset cleanup, dbus removal)
    - `plugin/bifrost/webs/Module_bifrost.asp` (firmware chrome shell)
    - `packaging/build.sh` (KoolCenter offline package structure)
    - `tests/install/t_install.sh` (BusyBox 1.25 install/upgrade/publish-failure/uninstall checks)
    - `.github/workflows/release.yml` (tag/branch/version validation and GitHub Release publishing)
    - `web/build.mjs`, `web/src/main.tsx`, `web/src/styles.css`, `web/src/core/api.ts`, `web/preview/`, and `web/test/` (Shadow DOM build, mount, preview server, and Playwright fixtures)

## Web Application Dependencies (Bundled into `bifrost-app.<hash>.{js,css}`)

The production JS bundle includes the following npm packages. The list covers
esbuild inputs with nonzero output, upstream components included in Kumo's
prebuilt chunks, and the Tailwind CSS imported by the stylesheet. Versions and
licenses correspond to `web/package-lock.json`.

| Package | Version | License and attribution |
|---|---|---|
| `@base-ui/react` | 1.9.0 | MIT · Copyright (c) 2019 Material-UI SAS |
| `@base-ui/utils` | 0.5.0 | MIT · Copyright (c) 2019 Material-UI SAS |
| `@cloudflare/kumo` | 2.19.0 | MIT · Copyright (c) 2026 Cloudflare, Inc. |
| `@floating-ui/core` | 1.8.0 | MIT · Copyright (c) 2021-present Floating UI contributors |
| `@floating-ui/dom` | 1.8.0 | MIT · Copyright (c) 2021-present Floating UI contributors |
| `@floating-ui/react-dom` | 2.1.9 | MIT · Copyright (c) 2021-present Floating UI contributors |
| `@floating-ui/utils` | 0.2.12 | MIT · Copyright (c) 2021-present Floating UI contributors |
| `@phosphor-icons/react` | 2.1.10 | MIT · Copyright (c) 2020 Phosphor Icons |
| `cn` | 0.4.0 | MIT · Copyright (c) 2026 shadcn |
| `react` | 19.3.1 | MIT · Copyright (c) Meta Platforms, Inc. and affiliates. |
| `react-dom` | 19.3.1 | MIT · Copyright (c) Meta Platforms, Inc. and affiliates. |
| `scheduler` | 0.28.0 | MIT · Copyright (c) Meta Platforms, Inc. and affiliates. |
| `tailwindcss` | 4.3.5 | MIT · Copyright (c) Tailwind Labs, Inc. |
| `uqr` | 0.1.3 | MIT · Copyright (c) Project Nayuki; Copyright (c) 2023 Anthony Fu <https://github.com/antfu> |
| `use-sync-external-store` | 1.7.0 | MIT · Copyright (c) Meta Platforms, Inc. and affiliates. |

The following MIT terms apply to the packages listed above.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
