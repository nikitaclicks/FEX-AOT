#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/Build-x86dev}"

RUNNER_SCRIPT="${SCRIPT_DIR}/run_x86_dev.sh"
STATIC_SEED_SCRIPT="${SCRIPT_DIR}/build_static_seed_cache_x86_dev.sh"
CANARY_SRC="${SCRIPT_DIR}/aot_canary.c"
CANARY_BIN="${BUILD_DIR}/Bin/aot_canary"

APP_PATH=""
APP_NAME=""
APP_ARGS=()
INCLUDE_CANARY=1
INCLUDE_DYNAMIC=0
RUNS=7
WARMUP=2
SEED="${SEED:-3735928559}"
CANARY_ITERS="${CANARY_ITERS:-200000}"
CANARY_WORK="${CANARY_WORK:-1}"
KEEP_WORKDIR=0
TIMER="auto"
TIMER_BACKEND=""

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${BUILD_DIR}/AOTBenchmarks/${TIMESTAMP}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --app <path> [options]

Benchmarks AOT/static-cache impact for:
  - deterministic canary workload (default enabled)
  - one application workload (required via --app)

Produces:
  - Markdown report: <report-dir>/benchmark-report.md
  - JSON report:     <report-dir>/benchmark-report.json

Required:
  --app PATH             App binary to benchmark under FEX

Options:
  --app-name NAME        Friendly app label (default: basename of --app)
  --app-arg ARG          App arg (repeatable)
  --no-canary            Benchmark only the app workload
  --include-dynamic      Include dynamic cache scenario (cache enabled without static prebuild)
  --runs N               Timing runs per scenario (default: ${RUNS})
  --warmup N             Warmup runs per scenario (default: ${WARMUP})
  --seed N               Canary seed (default: ${SEED})
  --canary-iters N       Canary iteration count when canary workload is enabled (default: ${CANARY_ITERS})
  --canary-work N        Canary inner work factor when canary workload is enabled (default: ${CANARY_WORK})
  --timer MODE           auto|hyperfine|python (default: ${TIMER})
  --report-dir PATH      Output report directory
  --keep-workdir         Keep temporary benchmark workdir
  -h, --help             Show help

Environment overrides:
  BUILD_DIR, SEED, CANARY_ITERS, CANARY_WORK
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --app-arg)
      APP_ARGS+=("${2:-}")
      shift 2
      ;;
    --no-canary)
      INCLUDE_CANARY=0
      shift
      ;;
    --include-dynamic)
      INCLUDE_DYNAMIC=1
      shift
      ;;
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --warmup)
      WARMUP="${2:-}"
      shift 2
      ;;
    --seed)
      SEED="${2:-}"
      shift 2
      ;;
    --canary-iters)
      CANARY_ITERS="${2:-}"
      shift 2
      ;;
    --canary-work)
      CANARY_WORK="${2:-}"
      shift 2
      ;;
    --timer)
      TIMER="${2:-}"
      shift 2
      ;;
    --report-dir)
      REPORT_DIR="${2:-}"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_tool() {
  local Tool="$1"
  if ! command -v "${Tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${Tool}" >&2
    exit 1
  fi
}

require_tool python3

case "${TIMER}" in
  auto)
    if command -v hyperfine >/dev/null 2>&1; then
      TIMER_BACKEND="hyperfine"
    else
      TIMER_BACKEND="python"
    fi
    ;;
  hyperfine)
    require_tool hyperfine
    TIMER_BACKEND="hyperfine"
    ;;
  python)
    TIMER_BACKEND="python"
    ;;
  *)
    echo "Invalid --timer mode: ${TIMER}" >&2
    exit 1
    ;;
esac

if [[ -z "${APP_PATH}" ]]; then
  echo "--app is required" >&2
  usage
  exit 1
fi

if [[ ! -x "${RUNNER_SCRIPT}" ]]; then
  echo "Missing runner script: ${RUNNER_SCRIPT}" >&2
  exit 1
fi

if [[ ! -x "${STATIC_SEED_SCRIPT}" ]]; then
  echo "Missing static seed script: ${STATIC_SEED_SCRIPT}" >&2
  exit 1
fi

if [[ ! -x "${APP_PATH}" ]]; then
  echo "App is not executable: ${APP_PATH}" >&2
  exit 1
fi

if [[ -z "${APP_NAME}" ]]; then
  APP_NAME="$(basename -- "${APP_PATH}")"
fi

mkdir -p "${BUILD_DIR}/Bin"
if [[ ${INCLUDE_CANARY} -eq 1 && ! -x "${CANARY_BIN}" ]]; then
  CC_BIN="${CC:-cc}"
  "${CC_BIN}" -O2 -std=c11 "${CANARY_SRC}" -o "${CANARY_BIN}"
fi

WORK_DIR="$(mktemp -d -t fex-aot-bench-XXXXXX)"
RAW_DIR="${REPORT_DIR}/raw"
WORKLOAD_DIR="${WORK_DIR}/workload"
CODEMAP_DIR="${WORK_DIR}/codemaps"
PREBUILT_CACHE_DIR="${WORK_DIR}/cache-prebuilt"
BASELINE_CACHE_DIR="${WORK_DIR}/cache-baseline"
DYNAMIC_CACHE_DIR="${WORK_DIR}/cache-dynamic"

cleanup() {
  if [[ ${KEEP_WORKDIR} -eq 0 ]]; then
    rm -rf "${WORK_DIR}"
  else
    echo "Kept benchmark workdir: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

mkdir -p "${RAW_DIR}" "${WORKLOAD_DIR}" "${BASELINE_CACHE_DIR}" "${DYNAMIC_CACHE_DIR}"

cp -f -- "${APP_PATH}" "${WORKLOAD_DIR}/${APP_NAME}"
if [[ ${INCLUDE_CANARY} -eq 1 ]]; then
  cp -f -- "${CANARY_BIN}" "${WORKLOAD_DIR}/aot_canary"
fi

echo "[1/4] Generating prebuilt cache bundle"
"${STATIC_SEED_SCRIPT}" \
  --input-dir "${WORKLOAD_DIR}" \
  --codemap-dir "${CODEMAP_DIR}" \
  --cache-dir "${PREBUILT_CACHE_DIR}" \
  --clean

quote_cmd() {
  local Out=""
  for Arg in "$@"; do
    Out+="$(printf '%q' "${Arg}") "
  done
  printf '%s' "${Out% }"
}

run_hyperfine_case() {
  local WorkloadName="$1"
  local ScenarioName="$2"
  local Command="$3"
  local OutFile="${RAW_DIR}/${WorkloadName}-${ScenarioName}.json"

  hyperfine \
    --runs "${RUNS}" \
    --warmup "${WARMUP}" \
    --export-json "${OutFile}" \
    "${Command}"
}

run_python_case() {
  local WorkloadName="$1"
  local ScenarioName="$2"
  local Command="$3"
  local OutFile="${RAW_DIR}/${WorkloadName}-${ScenarioName}.json"

  python3 - "${Command}" "${RUNS}" "${WARMUP}" "${OutFile}" <<'PY'
import json
import math
import os
import statistics
import subprocess
import sys
import time

command = sys.argv[1]
runs = int(sys.argv[2])
warmup = int(sys.argv[3])
outfile = sys.argv[4]

for _ in range(warmup):
    subprocess.run(command, shell=True, check=True)

times = []
for _ in range(runs):
    start = time.perf_counter()
    subprocess.run(command, shell=True, check=True)
    end = time.perf_counter()
    times.append(end - start)

mean = statistics.fmean(times)
median = statistics.median(times)
stddev = statistics.stdev(times) if len(times) > 1 else 0.0

payload = {
    "results": [
        {
            "command": command,
            "mean": mean,
            "median": median,
            "stddev": stddev,
            "times": times,
        }
    ]
}

os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY
}

run_case() {
  local WorkloadName="$1"
  local ScenarioName="$2"
  local Command="$3"
  if [[ "${TIMER_BACKEND}" == "hyperfine" ]]; then
    run_hyperfine_case "${WorkloadName}" "${ScenarioName}" "${Command}"
  else
    run_python_case "${WorkloadName}" "${ScenarioName}" "${Command}"
  fi
}

benchmark_workload() {
  local WorkloadName="$1"
  local BinaryPath="$2"
  shift 2
  local Args=("$@")

  local Invoked
  Invoked="$(quote_cmd "${RUNNER_SCRIPT}" "${BinaryPath}" "${Args[@]}")"

  local BaselineCommand="FEX_APP_CACHE_LOCATION=\"${BASELINE_CACHE_DIR}/\" FEX_ENABLECODECACHINGWIP=0 ${Invoked} >/dev/null"
  local PrebuiltCommand="FEX_APP_CACHE_LOCATION=\"${PREBUILT_CACHE_DIR}/\" FEX_ENABLECODECACHINGWIP=1 ${Invoked} >/dev/null"

  run_case "${WorkloadName}" "baseline" "${BaselineCommand}"
  run_case "${WorkloadName}" "prebuilt" "${PrebuiltCommand}"

  if [[ ${INCLUDE_DYNAMIC} -eq 1 ]]; then
    local DynamicCommand="rm -rf \"${DYNAMIC_CACHE_DIR}\" && mkdir -p \"${DYNAMIC_CACHE_DIR}\" && FEX_APP_CACHE_LOCATION=\"${DYNAMIC_CACHE_DIR}/\" FEX_ENABLECODECACHINGWIP=1 ${Invoked} >/dev/null"
    run_case "${WorkloadName}" "dynamic" "${DynamicCommand}"
  fi
}

echo "[2/4] Running benchmark scenarios"
if [[ ${INCLUDE_CANARY} -eq 1 ]]; then
  benchmark_workload "canary" "${CANARY_BIN}" "${SEED}" "${CANARY_ITERS}" "${CANARY_WORK}"
fi
benchmark_workload "app-${APP_NAME}" "${APP_PATH}" "${APP_ARGS[@]}"

echo "[3/4] Aggregating JSON + Markdown reports"
REPORT_JSON="${REPORT_DIR}/benchmark-report.json"
REPORT_MD="${REPORT_DIR}/benchmark-report.md"

python3 - "${RAW_DIR}" "${REPORT_JSON}" "${REPORT_MD}" "${APP_PATH}" "${APP_NAME}" "${RUNS}" "${WARMUP}" "${TIMER_BACKEND}" <<'PY'
import glob
import json
import os
import statistics
import sys
from datetime import datetime, timezone

raw_dir, report_json, report_md, app_path, app_name, runs, warmup, timer_backend = sys.argv[1:]

def load_case(path):
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    result = payload["results"][0]
    median = result.get("median", result.get("mean"))
    mean = result.get("mean", median)
    stddev = result.get("stddev", 0.0)
    return {
        "median_s": float(median),
        "mean_s": float(mean),
        "stddev_s": float(stddev),
    }

workloads = {}
for path in glob.glob(os.path.join(raw_dir, "*.json")):
    name = os.path.basename(path)
    if not name.endswith(".json"):
        continue
    stem = name[:-5]
    if "-" not in stem:
        continue
    workload, scenario = stem.rsplit("-", 1)
    workloads.setdefault(workload, {})[scenario] = load_case(path)

summary = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "app": {
        "name": app_name,
        "path": app_path,
    },
    "runs": int(runs),
    "warmup": int(warmup),
    "timer_backend": timer_backend,
    "workloads": {},
}

for workload, scenarios in sorted(workloads.items()):
    baseline = scenarios.get("baseline", {}).get("median_s")
    prebuilt = scenarios.get("prebuilt", {}).get("median_s")
    delta_pct = None
    if baseline and prebuilt:
        delta_pct = ((prebuilt - baseline) / baseline) * 100.0

    summary["workloads"][workload] = {
        "scenarios": scenarios,
        "delta_prebuilt_vs_baseline_pct": delta_pct,
    }

os.makedirs(os.path.dirname(report_json), exist_ok=True)
with open(report_json, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)

lines = []
lines.append("# AOT Cache Benchmark Report")
lines.append("")
lines.append(f"- Timestamp (UTC): {summary['timestamp_utc']}")
lines.append(f"- App: {app_name} ({app_path})")
lines.append(f"- Timer backend: {timer_backend}")
lines.append(f"- Runs: {runs}, warmup: {warmup}")
lines.append("")
lines.append("| Workload | Baseline median (s) | Prebuilt median (s) | Delta prebuilt vs baseline |")
lines.append("|---|---:|---:|---:|")

for workload, info in sorted(summary["workloads"].items()):
    baseline = info["scenarios"].get("baseline", {}).get("median_s")
    prebuilt = info["scenarios"].get("prebuilt", {}).get("median_s")
    delta_pct = info.get("delta_prebuilt_vs_baseline_pct")

    baseline_s = f"{baseline:.6f}" if baseline is not None else "n/a"
    prebuilt_s = f"{prebuilt:.6f}" if prebuilt is not None else "n/a"
    delta_s = f"{delta_pct:+.2f}%" if delta_pct is not None else "n/a"
    lines.append(f"| {workload} | {baseline_s} | {prebuilt_s} | {delta_s} |")

lines.append("")
lines.append("## Scenario notes")
lines.append("")
lines.append("- baseline: cache disabled")
lines.append("- prebuilt: cache enabled with statically prebuilt cache bundle")
if any("dynamic" in info.get("scenarios", {}) for info in summary["workloads"].values()):
    lines.append("- dynamic: cache enabled without static prebuild (cache dir reset per run)")

with open(report_md, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY

echo "[4/4] Done"
echo "Report (Markdown): ${REPORT_MD}"
echo "Report (JSON): ${REPORT_JSON}"
