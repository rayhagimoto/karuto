#!/bin/bash
# Read-only memory budget check. The caller establishes the app's UI state.
set -euo pipefail

pid=${1:-}
metric=${2:-footprint}
budget=${3:-50}
if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || [[ ! "$budget" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   [[ "$metric" != footprint && "$metric" != rss ]]; then
  echo "Usage: bash scripts/memory.sh PID [footprint|rss] [budget-MiB]" >&2
  exit 2
fi

report=$(vmmap -summary "$pid")
rss_kib=$(ps -p "$pid" -o rss=)
if [[ -z "$rss_kib" ]]; then
  echo "Process exited during measurement." >&2
  exit 2
fi
printf '%s\n' "$report" | awk -v rss_kib="$rss_kib" -v metric="$metric" -v budget="$budget" '
function mib(value, unit) {
  unit = substr(value, length(value), 1)
  if (unit == "K") return (value + 0) / 1024
  if (unit == "M") return value + 0
  if (unit == "G") return (value + 0) * 1024
  return (value + 0) / 1048576
}
/^Physical footprint:/ { footprint = mib($NF); found = 1 }
/^Physical footprint \(peak\):/ { peak = mib($NF) }
END {
  if (!found) { print "Could not read physical footprint." > "/dev/stderr"; exit 2 }
  rss = rss_kib / 1024
  printf "Physical footprint: %.1f MiB; peak: %.1f MiB; RSS: %.1f MiB\n", footprint, peak, rss
  value = metric == "rss" ? rss : footprint
  printf "%s: %s %.1f MiB; target < %.1f MiB\n", (value < budget ? "PASS" : "FAIL"), metric, value, budget
  exit (value < budget ? 0 : 1)
}'
