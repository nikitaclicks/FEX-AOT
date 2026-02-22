# x86 local development scripts

This folder contains helper scripts to build/run FEX locally on x86_64 for development.

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

- `--rootfs /path/to/rootfs`
- `--search-path /path/one --search-path /path/two`

The generated cache set can be tested with `FEX_APP_CACHE_LOCATION=<cache-dir>`.

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
