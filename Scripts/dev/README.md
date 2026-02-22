# x86 local development scripts

This folder contains helper scripts to build/run FEX locally on x86_64 for development.

## Scripts

- `setup_x86_dev.sh`
  - Installs dependencies (Fedora), configures, builds, and installs to a local prefix.
- `build_x86_dev.sh`
  - Incremental rebuild helper for `Build-x86dev`.
- `run_x86_dev.sh`
  - Runs programs under FEX with x86-host-safe defaults.
- `undo_x86_dev.sh`
  - Removes local artifacts and optionally purges system packages/cache.

## Typical loop

1. `./Scripts/dev/build_x86_dev.sh`
2. `./Scripts/dev/run_x86_dev.sh /path/to/test_binary [args...]`

## Runtime defaults used by `run_x86_dev.sh`

- `FEX_TSOENABLED=0`
- `FEX_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS=0`

These defaults avoid known x86-host simulator crashes encountered during local development in this repository.
