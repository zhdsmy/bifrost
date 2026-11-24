# Bifrost Core Build

`core/recipe.json` is the single source of truth for building the Tailscale
combined binary (`bifrostd`) used by Bifrost. Local builds and GitHub Actions
(`core.yml`) both run `core/build.sh`.

## Requirements

- Go matching `go` in `core/recipe.json` (`GOTOOLCHAIN=local`, `GOWORK=off`,
  and `GOENV=off` are enforced; caller `GOFLAGS`/`GOEXPERIMENT`/etc. are cleared)
- All modes check the local Go version before fetching source or running featuretags.
  HTTP, HTTPS, ALL and NO proxy variables (both cases) and `GOPROXY` pass through.
- `git`, `jq`, `openssl`, `gzip`, `curl`, and UPX 5.3.0 (the script downloads and verifies the pinned archive when `upx` is not on `PATH`)

## Usage

### 1. Build release cores and manifest

Builds every target in `core/recipe.json` once, checks embedded tags and
version metadata, and writes uncompressed and optional UPX assets to
`core/out/`. Normal assets are named
`bifrost-core-<version>-<revision>-linux-<target>.gz`. UPX assets add `-upx`
before `-linux-<target>.gz`. Both use `gzip -9 -n`. The manifest and
`LICENSE.tailscale` are written to the same directory.

```sh
core/build.sh [--serial N] [--min-plugin X.Y.Z] [--out DIR] [--src DIR]
```

`--serial` (or `CORE_SERIAL`, default `1`) sets the monotonically increasing
`serial` number in `core.json`.

### 2. Validate recipe only (`--check-recipe`)

Checks `core/recipe.json` schema, clones/verifies the upstream Tailscale tag
and commit, checks `go.mod` against `recipe.json`, and runs Tailscale's
`cmd/featuretags --remove=...` dependency validation without compiling.

```sh
core/build.sh --check-recipe [--src DIR]
```

### 3. Build a test binary (`--test-arch`)

Compiles an uncompressed Linux binary for the container test environment using
the exact same recipe tags and build flags, outputting to
`core/out/test/bifrostd-linux-<arch>` without generating a manifest.

```sh
core/build.sh --test-arch amd64
core/build.sh --test-arch arm64
```

## Reproducibility and Notes

- **Cross-platform comparison**: Compare `raw_sha256` (the uncompressed ELF
  binary) when verifying macOS vs. Linux builds. Apple/BSD `gzip` on macOS and
  GNU `gzip` on Linux can produce different `.gz` bytes even with `gzip -9 -n`.
- **Release `.gz` archives**: Official release `.gz` files and published
  `core.json` manifests are generated exclusively on Linux CI
  (`.github/workflows/core.yml`), where two independent runners verify
  byte-identical `.gz` files and manifests before signing and publishing.
- **Source checkout safety**: By default, upstream source is cloned into
  `<out>/src/<commit>` (override with `--src DIR` or
  `CORE_SRC_DIR`). Existing checkouts must be clean and match the pinned commit.
  The build never resets or cleans a checkout.
- Never use Tailscale's `--extra-small` (it removes subnet routing and exit node
  features required on routers).
- The uncompressed core is the default. UPX is optional and fixed to
  `--best --no-lzma` because it reduces file size while keeping decompression
  faster than the default LZMA mode. Each process still pays the decompression
  cost and cannot share the resulting memory.


## Retrying a release

Rerun the failed workflow for the same tag. The publisher checks an existing
tag release against the rebuild and verifies its signatures. It uploads missing
assets to the reserved tag and publishes the draft after readback. A pending manifest
on `channel-stable` reserves the serial until the signed pair passes readback.
During replacement the manifest URL can briefly return 404. A retry of an older,
already-published tag preserves a newer stable channel.
