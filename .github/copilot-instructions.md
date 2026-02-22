# Copilot instructions for FEX local x86 development

When the user is developing in this repository on an x86_64 host (not AArch64), use the local dev scripts under `Scripts/dev`.

## Preferred workflow

1. Initial setup/build/install:
   - `./Scripts/dev/setup_x86_dev.sh`
2. Incremental rebuilds after source edits:
   - `./Scripts/dev/build_x86_dev.sh`
   - or targeted: `./Scripts/dev/build_x86_dev.sh --target FEX`
3. Run guest programs under local x86-host development mode:
   - `./Scripts/dev/run_x86_dev.sh /path/to/program [args...]`

## Important x86-host runtime notes

- x86-host builds require `ENABLE_X86_HOST_DEBUG=ON` (already handled by setup script).
- For stable x86-host runtime in this environment, use:
  - `FEX_TSOENABLED=0`
  - `FEX_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS=0`
- `run_x86_dev.sh` already applies these defaults.

## Cleanup / reclaim space

- Remove local build/install artifacts:
  - `./Scripts/dev/undo_x86_dev.sh --yes`
- Optional aggressive cleanup (includes package/cache removal):
  - `./Scripts/dev/undo_x86_dev.sh --purge-system-deps --remove-ccache --yes`

## Practical guidance for future coding sessions

- Prefer using these scripts instead of ad-hoc command variants.
- If CMake cache is stale or compiler mismatch appears, rerun setup:
  - `./Scripts/dev/setup_x86_dev.sh --skip-deps`
- If build dir is corrupted, recreate:
  - `rm -rf Build-x86dev && ./Scripts/dev/setup_x86_dev.sh --skip-deps`
