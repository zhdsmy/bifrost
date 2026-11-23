# Bifrost Core Build

`core/recipe.json` is the single source of truth for building the Tailscale
combined binary (`bifrostd`) used by Bifrost. Local builds and GitHub Actions
(`core.yml`) both run `core/build.sh`.

## Requirements

- Go matching `go` in `core/recipe.json` (`GOTOOLCHAIN=local` is enforced)
- `git`, `jq`, `openssl`, `gzip`

## Usage

### 1. Build release cores and manifest

Builds every target in `core/recipe.json`, checks embedded tags and version
metadata, writes `bifrost-core-<version>-<revision>-linux-<target>.gz`
(`gzip -9 -n`), `core.json`, and `LICENSE.tailscale` to `core/out/`.

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

## Notes

- Never use Tailscale's `--extra-small` (it removes subnet routing and exit node
  features required on routers).
- Do not UPX-compress the core.
- Build from a clean git checkout at the pinned commit so `mkversion` and Go's
  VCS metadata are deterministic. By default, upstream source is cloned into
  `${TMPDIR:-/tmp}/bifrost-tailscale-src` (override with `--src DIR` or
  `CORE_SRC_DIR`).
