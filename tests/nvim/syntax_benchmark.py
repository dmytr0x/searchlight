"""Compare identical syntax workloads in fresh processes; kernel peak RSS includes parses."""
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[2]


def percentile(values, fraction=0.95):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def run(enabled):
    with tempfile.TemporaryDirectory(prefix="searchlight-syntax-") as directory:
        base = Path(directory)
        env = os.environ.copy()
        for key, suffix in (
            ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
            ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
        ):
            env[key] = str(base / suffix)
        env["NVIM_LOG_FILE"] = str(base / "nvim.log")
        env["SEARCHLIGHT_SYNTAX"] = "1" if enabled else "0"
        env["SEARCHLIGHT_BENCH_OUTPUT"] = str(base / "result.json")
        command = ["nvim", "--headless", "-u", "tests/nvim/minimal_init.lua", "-l",
                   "tests/nvim/syntax_benchmark.lua"]
        if os.uname().sysname == "Darwin":
            command = ["/usr/bin/time", "-l", *command]
        else:
            command = ["/usr/bin/time", "-v", *command]
        completed = subprocess.run(command, cwd=REPO, env=env, capture_output=True,
                                   text=True, timeout=90)
        if completed.returncode:
            raise RuntimeError(completed.stdout + completed.stderr)
        result = json.loads((base / "result.json").read_text())
        mac = re.search(r"(\d+)\s+maximum resident set size", completed.stderr)
        linux = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", completed.stderr)
        result["kernel_peak_rss"] = int(mac[1]) if mac else int(linux[1]) * 1024
        return result


def main():
    runs = {False: [], True: []}
    for trial in range(int(os.environ.get("SEARCHLIGHT_BENCH_TRIALS", "3"))):
        for enabled in (False, True) if trial % 2 == 0 else (True, False):
            result = run(enabled)
            runs[enabled].append(result)
            print(json.dumps({"trial": trial + 1, "enabled": enabled,
                              "peak_rss_mib": result["kernel_peak_rss"] / 2**20,
                              "parses": result["working_set"]["parses"],
                              "worker_gap_ms": result["longest_worker_heartbeat_gap_ms"]}),
                  flush=True)
    summaries = {}
    for enabled, results in runs.items():
        summaries[enabled] = {
            "first_results_median_ms": statistics.median(
                [value for run in results for value in run["first_results_ms"]]),
            **{key + "_p95_ms": percentile(
                [value for run in results for value in run[key + "_ms"]])
               for key in ("navigation", "drawing", "scroll")},
            "peak_rss_mib": statistics.median([run["kernel_peak_rss"] / 2**20 for run in results]),
            "worker_gap_p95_ms": percentile([value for run in results for value in run["worker_heartbeat_gaps_ms"]]),
            "worker_gap_max_ms": max(run["longest_worker_heartbeat_gap_ms"] for run in results),
            "recovered_heap_mib": statistics.median([run["recovered_lua_heap"] / 2**20 for run in results]),
        }
    off, on = summaries[False], summaries[True]
    added = {key: on[key] - off[key] for key in off}
    gates = {
        "first_results": added["first_results_median_ms"] < max(5, off["first_results_median_ms"] * .05),
        "warm_navigation": added["navigation_p95_ms"] < 2,
        "navigation": off["navigation_p95_ms"] < 5,
        "cached_drawing": added["drawing_p95_ms"] < 3,
        "heartbeat": added["worker_gap_p95_ms"] < 10 and on["worker_gap_max_ms"] < 25,
        "rss": max(run["kernel_peak_rss"] for run in runs[True]) -
               min(run["kernel_peak_rss"] for run in runs[False]) <= 32 * 2**20,
    }
    report = {"disabled": off, "enabled": on, "added": added, "gates": gates,
              "runs": {"disabled": runs[False], "enabled": runs[True]}}
    output = Path(os.environ.get("SEARCHLIGHT_BENCH_REPORT", "/tmp/searchlight-syntax-benchmark.json"))
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"disabled": off, "enabled": on, "added": added, "gates": gates}, indent=2))
    print("Full measurements: " + str(output))
    if not all(gates.values()):
        raise SystemExit("Syntax release gates failed")


if __name__ == "__main__":
    main()
