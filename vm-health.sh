#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

threshold=60

case "${1:-}" in
  ""|explain) ;;
  *)
    echo "Usage: $0 [explain]" >&2
    exit 2
    ;;
esac

# Read total and idle CPU counters. Exclude guest fields because they are
# already included in user/nice.
read_cpu_counters() {
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= 9; i++) total += $i
    idle = $5 + $6
    print total, idle
    exit
  }' /proc/stat
}

read -r total1 idle1 < <(read_cpu_counters)
sleep 1
read -r total2 idle2 < <(read_cpu_counters)

cpu_usage=$(awk -v t1="$total1" -v i1="$idle1" \
                -v t2="$total2" -v i2="$idle2" 'BEGIN {
  total_delta = t2 - t1
  idle_delta = i2 - i1
  if (total_delta <= 0) {
    print "error"
  } else {
    printf "%.2f", 100 * (total_delta - idle_delta) / total_delta
  }
}')

if [[ "$cpu_usage" == "error" ]]; then
  echo "Error: unable to measure CPU usage." >&2
  exit 1
fi

memory_usage=$(awk '
  /^MemTotal:/     { total = $2 }
  /^MemAvailable:/ { available = $2 }
  END {
    if (total <= 0 || available < 0) exit 1
    printf "%.2f", 100 * (total - available) / total
  }
' /proc/meminfo) || {
  echo "Error: unable to measure memory usage." >&2
  exit 1
}

disk_usage=$(df -P / | awk 'NR == 2 {
  gsub(/%/, "", $5)
  print $5
}')

if [[ -z "$disk_usage" ]]; then
  echo "Error: unable to measure disk usage for /." >&2
  exit 1
fi

is_at_or_above_threshold() {
  awk -v value="$1" -v limit="$threshold" \
    'BEGIN { exit !(value >= limit) }'
}

unhealthy=0
for usage in "$cpu_usage" "$memory_usage" "$disk_usage"; do
  if is_at_or_above_threshold "$usage"; then
    unhealthy=1
  fi
done

if (( unhealthy )); then
  status="NOT HEALTHY"
else
  status="HEALTHY"
fi

printf 'VM health: %s\n' "$status"

if [[ "${1:-}" == "explain" ]]; then
  explain_metric() {
    local name="$1"
    local usage="$2"

    if is_at_or_above_threshold "$usage"; then
      printf '%s: %s%% — at or above the %s%% limit.\n' \
        "$name" "$usage" "$threshold"
    else
      printf '%s: %s%% — below the %s%% limit.\n' \
        "$name" "$usage" "$threshold"
    fi
  }

  explain_metric "CPU utilization" "$cpu_usage"
  explain_metric "Memory utilization" "$memory_usage"
  explain_metric "Disk utilization (/)" "$disk_usage"
fi
