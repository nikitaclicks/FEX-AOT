[中文](https://github.com/FEX-Emu/FEX/blob/main/docs/Readme_CN.md)

## Fork Focus: AOT App Caching and Static Cache Prebuilds

This fork is focused on adding practical AOT-style app caching workflows to improve runtime behavior and reduce repeated JIT cost.

### Why it exists

- Prebuild executable + dependency cache artifacts before first run.
- Shift work from runtime JIT to offline cache generation.
- Improve startup/stutter behavior by increasing cache reuse.

### What this adds

- Static codemap generation + offline cache compilation workflow.
- Dependency-aware static seeding (main binary + transitive shared libraries).
- Unified cache naming keys across runtime/server/offline compiler.
- Runtime cache load/fallback diagnostics.
- Benchmark framework for baseline vs prebuilt-cache performance comparison (Markdown+JSON output).
- Validation tooling to confirm cache-enabled behavior remains aligned with JIT.

### Impact

- Better practical performance characteristics from more reusable prebuilt caches.
- Lower warm-up overhead in repeated app runs.
- Clearer observability when cache load paths fall back.

### Sample benchmark result (heavy canary)

Command used:

```sh
./Scripts/dev/run_aot_perf_benchmark_x86_dev.sh \
	--app ./Build-x86dev/Bin/aot_canary \
	--app-name canary-heavy \
	--app-arg 3735928559 \
	--app-arg 600000 \
	--app-arg 2 \
	--no-canary \
	--runs 3 \
	--warmup 0 \
	--timer python \
	--report-dir ./Build-x86dev/AOTBenchmarks/canary-heavy-fast
```

Measured output:

| Workload | Baseline median (s) | Prebuilt median (s) | Delta prebuilt vs baseline |
|---|---:|---:|---:|
| app-canary-heavy | 16.337991 | 15.528765 | -4.95% |

Interpretation: this heavier synthetic canary profile is tuned to surface prebuilt-cache effects while still finishing in reasonable time. This measurement used the Python timing fallback backend on an x86-host dev setup.

### Sample benchmark result (real app: uname)

Command used:

```sh
./Scripts/dev/run_aot_perf_benchmark_x86_dev.sh \
	--app /usr/bin/uname \
	--app-name uname \
	--app-arg -a \
	--no-canary \
	--runs 5 \
	--warmup 1 \
	--timer python \
	--report-dir ./Build-x86dev/AOTBenchmarks/uname-sample
```

Measured output:

| Workload | Baseline median (s) | Prebuilt median (s) | Delta prebuilt vs baseline |
|---|---:|---:|---:|
| app-uname | 0.427574 | 0.458252 | +7.17% |

Interpretation: this real-app sample is more representative than the synthetic canary, but still reflects this specific local x86-host dev environment and Python timing backend.

Implementation and day-to-day commands are documented in [Scripts/dev/README.md](Scripts/dev/README.md).

Note: x86-host scripts in this fork are a practical development path (used because ARM Linux hardware is not always available). The primary goal is the AOT caching functionality itself.

# FEX: Emulate x86 Programs on ARM64
FEX allows you to run x86 applications on ARM64 Linux devices, similar to qemu-user and box64.
It offers broad compatibility with both 32-bit and 64-bit binaries, and it can be used alongside Wine/Proton to play Windows games.

It supports forwarding API calls to host system libraries like OpenGL or Vulkan to reduce emulation overhead.
An experimental code cache helps minimize in-game stuttering as much as possible.
Furthermore, a per-app configuration system allows tweaking performance per game, e.g. by skipping costly memory model emulation.
We also provide a user-friendly FEXConfig GUI to explore and change these settings.

## Prerequisites
FEX requires ARMv8.0+ hardware. It has been tested with the following Linux distributions, though others are likely to work as well:

- Arch Linux
- Fedora Linux
- openSUSE
- Ubuntu 22.04/24.04/24.10/25.04

An x86-64 RootFS is required and can be downloaded using our `FEXRootFSFetcher` tool for many distributions.
For other distributions you will need to generate your own RootFS (our [wiki page](https://wiki.fex-emu.com/index.php/Development:Setting_up_RootFS) might help).

## Quick Start
### For Ubuntu 22.04, 24.04, 24.10 and 25.04
Execute the following command in the terminal to install FEX through a PPA.

```sh
curl --silent https://raw.githubusercontent.com/FEX-Emu/FEX/main/Scripts/InstallFEX.py | python3
```

This command will walk you through installing FEX through a PPA, and downloading a RootFS for use with FEX.

### For other Distributions
Follow the guide on the official FEX-Emu Wiki [here](https://wiki.fex-emu.com/index.php/Development:Setting_up_FEX).

### Navigating the Source
See the [Source Outline](docs/SourceOutline.md) for more information.
