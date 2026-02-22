# AOT app caching workflow

This folder contains the local workflow used in this fork to generate and validate static cache artifacts for applications and their dependencies.

Host note: The scripts are x86-host-oriented because ARM Linux hardware is not always available during development. That is an implementation detail; the main purpose is AOT caching functionality.

## What this fork is about

This fork adds functionality and tooling to prebuild app caches (including dependency closure), then use and validate them reliably.

### Goals

- Pre-generate cache artifacts for binaries and their shared-library dependencies.
- Increase cache reuse to reduce repeated runtime JIT cost.
- Keep cache behavior observable and diagnosable.

### Core implementation pieces

- `FEXStaticCodeMapGen` + `build_static_seed_cache_x86_dev.sh`
  - Generates seed codemaps from ELF entrypoints/segments, resolves dependencies transitively, and compiles caches using `FEXOfflineCompiler`.
- Cache-key completeness
  - Runtime/server/offline cache naming now shares a config fingerprint to avoid mismatched cache filenames.
- Resolver parity hardening
  - Rootfs-aware resolution order was aligned to prefer rootfs paths where applicable.
- Runtime cache validation hooks
  - Added load/fallback reason tracking and periodic cache-load stats logging.
- `run_aot_guardrail_x86_dev.sh`
  - Validation helper: deterministic parity check between JIT and cache-enabled paths.
- `run_local_aot_regressions_x86_dev.sh`
  - Validation helper: runs guardrail + static seeding + runtime smoke checks as a local non-CI regression suite.

### Expected impact

- Faster local iteration on cache/AOT behavior.
- Better app-level cache reuse and lower repeated warm-up overhead.
- Better visibility into cache misses/fallbacks.
- Safer artifact management via `--clean` in static-seed generation.

## Quick functionality-first flow

1. `./Scripts/dev/build_static_seed_cache_x86_dev.sh --input-dir /path/to/x86-binaries --clean`
  - Generates fresh static codemaps/caches for binary sets and dependencies.
2. `FEX_APP_CACHE_LOCATION=<cache-dir> ./Scripts/dev/run_x86_dev.sh /path/to/program [args...]`
  - Runs apps using the prebuilt cache set.
3. `./Scripts/dev/run_aot_guardrail_x86_dev.sh --seed 12345`
  - Optional validation pass for JIT-vs-cache parity.

## Scripts

- `setup_x86_dev.sh`
  - Installs dependencies (Fedora), configures, builds, and installs to a local prefix.
- `build_x86_dev.sh`
  - Incremental rebuild helper for `Build-x86dev`.
- `run_x86_dev.sh`
  - Runs programs under FEX with x86-host-safe defaults.
- `run_aot_guardrail_x86_dev.sh`
  - Builds a deterministic canary and checks JIT vs cache-enabled parity.
- `build_static_seed_cache_x86_dev.sh`
  - Generates static seed codemaps for x86 ELFs in a folder and compiles caches.
- `run_local_aot_regressions_x86_dev.sh`
  - Local non-CI regression runner that chains guardrail parity + static seeding + runtime smoke assertions.
- `undo_x86_dev.sh`
  - Removes local artifacts and optionally purges system packages/cache.

## Typical loop

1. `./Scripts/dev/build_x86_dev.sh`
2. `./Scripts/dev/run_x86_dev.sh /path/to/test_binary [args...]`

For AOT/cache guardrails during development:

1. `./Scripts/dev/build_x86_dev.sh`
2. `./Scripts/dev/run_aot_guardrail_x86_dev.sh --seed 12345`

This guardrail runs the canary in JIT mode and cache-enabled mode and fails if output or exit code differs.

For static cache seeding MVP (entrypoint-seeded):

1. `./Scripts/dev/build_x86_dev.sh --target FEXStaticCodeMapGen`
2. `./Scripts/dev/build_x86_dev.sh --target FEXOfflineCompiler`
3. `./Scripts/dev/build_static_seed_cache_x86_dev.sh --input-dir /path/to/x86-binaries`

Optional dependency-resolution flags:

- `--clean`
- `--rootfs /path/to/rootfs`
- `--search-path /path/one --search-path /path/two`

The generated cache set can be tested with `FEX_APP_CACHE_LOCATION=<cache-dir>`.

To clear stale codemap/cache artifacts before a fresh generation pass, add `--clean`.

For local regression checks (no CI):

1. `./Scripts/dev/run_local_aot_regressions_x86_dev.sh`

Useful options:

- `--skip-build`
- `--guardrail-retries 3`
- `--keep-artifacts`
- `--input-dir /path/to/x86-binaries`
- `--rootfs /path/to/rootfs`
- `--search-path /path/one --search-path /path/two`

## Runtime defaults used by `run_x86_dev.sh`

- `FEX_TSOENABLED=0`
- `FEX_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS=0`

These defaults avoid known x86-host simulator crashes encountered during local development in this repository.
