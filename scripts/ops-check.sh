#!/usr/bin/env bash
#
# ops-check.sh - lightweight Linux operations health check.
#
# Collects CPU, memory, root filesystem and load average metrics, optionally
# checks systemd services and listening TCP ports, and raises alerts for
# configurable thresholds. Alerts are written to stderr and syslog.
#
# Dependencies: bash and common Linux userland tools (awk, df, logger, sleep,
# date, hostname). Service checks need systemctl and a running systemd; port
# checks need ss or netstat. No third-party dependencies are used.

set -u
set -o pipefail

# Keep numeric output from df/awk predictable regardless of the caller's locale.
export LC_ALL=C

EXIT_OK=0
EXIT_ALERT=1
EXIT_ERROR=2

DISK_WARN=85
MEM_WARN=90
LOAD_FACTOR=2
CPU_INTERVAL=60
JSON_OUTPUT=0
SERVICES_SPEC=""
PORTS_SPEC=""

CPU_PERCENT=""
MEM_PERCENT=""
MEM_TOTAL_KB=""
MEM_AVAILABLE_KB=""
DISK_PERCENT=""
LOAD1=""
LOAD5=""
LOAD15=""
LOAD_LIMIT=""
CPU_CORES=""

SERVICE_REQUESTS=()
PORT_REQUESTS=()
SERVICE_NAMES=()
SERVICE_STATES=()
PORT_NUMBERS=()
PORT_LISTENING=()
PORT_TOOL=""
PORT_SNAPSHOT=""

ALERTS=()
NOTES=()
SYSLOG_WARNED=0

TIMESTAMP=""
SYS_HOSTNAME=""

usage() {
  cat <<'EOF'
Usage: ops-check.sh [OPTIONS]

Collect Linux system health metrics and alert when thresholds are exceeded.

Options:
  --json                 Print a machine-readable JSON report to stdout
  --services "a b"       systemd services that must be active (space separated)
  --ports "22 80"        TCP ports that must be listening (space separated)
  --disk-warn PERCENT    Disk usage alert threshold (default: 85)
  --mem-warn PERCENT     Memory usage alert threshold (default: 90)
  --load-factor NUMBER   Alert when load1 > NUMBER * CPU cores (default: 2)
  --cpu-interval SECONDS CPU sampling window in seconds (default: 60)
  -h, --help             Show this help and exit

Alerts go to stderr and to syslog with "logger -t ops-check". Port checks are
skipped with a note when neither ss nor netstat is available.

Exit status:
  0  all checks passed
  1  one or more alerts
  2  script execution error (invalid arguments, missing /proc, failed checks)
EOF
}

die() {
  printf 'ops-check: error: %s\n' "$*" >&2
  exit "$EXIT_ERROR"
}

add_note() {
  NOTES+=("$1")
}

warn_syslog() {
  if [ "$SYSLOG_WARNED" -eq 0 ]; then
    printf 'ops-check: warning: failed to write alerts to syslog with logger\n' >&2
    SYSLOG_WARNED=1
  fi
}

alert() {
  local message=$1
  ALERTS+=("$message")
  printf 'ALERT: %s\n' "$message" >&2
  if command -v logger >/dev/null 2>&1; then
    if ! logger -t ops-check "$message" 2>/dev/null; then
      warn_syslog
    fi
  else
    warn_syslog
  fi
}

is_number() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_percent() {
  local value=$1
  is_number "$value" || return 1
  awk -v v="$value" 'BEGIN { exit !(v >= 0 && v <= 100) }'
}

is_positive_number() {
  local value=$1
  is_number "$value" || return 1
  awk -v v="$value" 'BEGIN { exit !(v > 0) }'
}

normalize_number() {
  awk -v v="$1" 'BEGIN { printf "%.10g", v }'
}

numeric_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)
        JSON_OUTPUT=1
        ;;
      -h|--help)
        usage
        exit "$EXIT_OK"
        ;;
      --services)
        [ $# -ge 2 ] || die "option --services requires a value"
        SERVICES_SPEC=$2
        shift
        ;;
      --services=*)
        SERVICES_SPEC=${1#*=}
        ;;
      --ports)
        [ $# -ge 2 ] || die "option --ports requires a value"
        PORTS_SPEC=$2
        shift
        ;;
      --ports=*)
        PORTS_SPEC=${1#*=}
        ;;
      --disk-warn)
        [ $# -ge 2 ] || die "option --disk-warn requires a value"
        DISK_WARN=$2
        shift
        ;;
      --disk-warn=*)
        DISK_WARN=${1#*=}
        ;;
      --mem-warn)
        [ $# -ge 2 ] || die "option --mem-warn requires a value"
        MEM_WARN=$2
        shift
        ;;
      --mem-warn=*)
        MEM_WARN=${1#*=}
        ;;
      --load-factor)
        [ $# -ge 2 ] || die "option --load-factor requires a value"
        LOAD_FACTOR=$2
        shift
        ;;
      --load-factor=*)
        LOAD_FACTOR=${1#*=}
        ;;
      --cpu-interval)
        [ $# -ge 2 ] || die "option --cpu-interval requires a value"
        CPU_INTERVAL=$2
        shift
        ;;
      --cpu-interval=*)
        CPU_INTERVAL=${1#*=}
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
    shift
  done
}

validate_config() {
  is_percent "$DISK_WARN" || die "invalid --disk-warn value: $DISK_WARN (expected 0-100)"
  is_percent "$MEM_WARN" || die "invalid --mem-warn value: $MEM_WARN (expected 0-100)"
  is_positive_number "$LOAD_FACTOR" || die "invalid --load-factor value: $LOAD_FACTOR (expected a positive number)"
  [[ $CPU_INTERVAL =~ ^[1-9][0-9]*$ ]] || die "invalid --cpu-interval value: $CPU_INTERVAL (expected a positive integer)"

  DISK_WARN=$(normalize_number "$DISK_WARN")
  MEM_WARN=$(normalize_number "$MEM_WARN")
  LOAD_FACTOR=$(normalize_number "$LOAD_FACTOR")
}

parse_requested_services() {
  local service
  SERVICE_REQUESTS=()
  read -r -a SERVICE_REQUESTS <<< "$SERVICES_SPEC"
  if [ ${#SERVICE_REQUESTS[@]} -gt 0 ]; then
    for service in "${SERVICE_REQUESTS[@]}"; do
      case "$service" in
        *[[:cntrl:]]*)
          die "invalid service name (control characters are not allowed): $service"
          ;;
      esac
    done
  fi
}

parse_requested_ports() {
  local port
  PORT_REQUESTS=()
  read -r -a PORT_REQUESTS <<< "$PORTS_SPEC"
  if [ ${#PORT_REQUESTS[@]} -gt 0 ]; then
    for port in "${PORT_REQUESTS[@]}"; do
      [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid port: $port (expected 1-65535)"
      [ "$port" -le 65535 ] || die "invalid port: $port (expected 1-65535)"
    done
  fi
}

require_proc() {
  [ -r /proc/stat ] || die "/proc/stat is missing or unreadable (Linux with procfs is required)"
  [ -r /proc/meminfo ] || die "/proc/meminfo is missing or unreadable"
  [ -r /proc/loadavg ] || die "/proc/loadavg is missing or unreadable"
}

collect_memory() {
  local total available
  total=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null) || total=""
  available=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null) || available=""
  [ -n "$total" ] || die "MemTotal not found in /proc/meminfo"
  [ -n "$available" ] || die "MemAvailable not found in /proc/meminfo (Linux 3.14+ is required)"
  case "$total" in
    ''|*[!0-9]*) die "unexpected MemTotal value: $total" ;;
  esac
  case "$available" in
    ''|*[!0-9]*) die "unexpected MemAvailable value: $available" ;;
  esac
  [ "$total" -gt 0 ] || die "MemTotal is zero in /proc/meminfo"
  [ "$available" -le "$total" ] || die "MemAvailable is greater than MemTotal in /proc/meminfo"

  MEM_TOTAL_KB=$total
  MEM_AVAILABLE_KB=$available
  MEM_PERCENT=$(awk -v t="$total" -v a="$available" 'BEGIN { printf "%.1f", (t - a) * 100 / t }')
}

collect_disk() {
  local df_output percent
  df_output=$(df -P / 2>/dev/null) || die "df -P / failed"
  percent=$(printf '%s\n' "$df_output" | awk '
    NR == 2 {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+%$/) {
          sub(/%/, "", $i)
          print $i
          exit
        }
      }
    }')
  [ -n "$percent" ] || die "failed to determine disk usage of / from df -P /"
  case "$percent" in
    ''|*[!0-9]*) die "unexpected disk usage value from df: $percent" ;;
  esac
  DISK_PERCENT=$percent
}

collect_load() {
  local rest
  read -r LOAD1 LOAD5 LOAD15 rest < /proc/loadavg || die "failed to read /proc/loadavg"
  is_number "$LOAD1" || die "unexpected load1 value: $LOAD1"
  is_number "$LOAD5" || die "unexpected load5 value: $LOAD5"
  is_number "$LOAD15" || die "unexpected load15 value: $LOAD15"
  : "$rest"
}

collect_cores() {
  local cores=""
  if command -v nproc >/dev/null 2>&1; then
    cores=$(nproc 2>/dev/null) || cores=""
  fi
  if [ -z "$cores" ] && command -v getconf >/dev/null 2>&1; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=""
  fi
  if [ -z "$cores" ]; then
    cores=$(awk '/^processor[[:space:]]*:/ { count++ } END { print count + 0 }' /proc/cpuinfo 2>/dev/null) || cores=""
  fi
  case "$cores" in
    ''|*[!0-9]*) die "failed to determine CPU core count" ;;
  esac
  [ "$cores" -ge 1 ] || die "failed to determine CPU core count"
  CPU_CORES=$cores
}

collect_cpu() {
  local first second usage
  first=$(awk '/^cpu / { print; exit }' /proc/stat 2>/dev/null) || first=""
  [ -n "$first" ] || die "failed to read CPU statistics from /proc/stat"
  sleep "$CPU_INTERVAL" || die "interrupted while sampling CPU usage"
  second=$(awk '/^cpu / { print; exit }' /proc/stat 2>/dev/null) || second=""
  [ -n "$second" ] || die "failed to read CPU statistics from /proc/stat"

  usage=$(awk -v s1="$first" -v s2="$second" '
    BEGIN {
      n1 = split(s1, a, " ")
      n2 = split(s2, b, " ")
      if (n1 < 6 || n2 < 6) exit 1
      total1 = 0
      total2 = 0
      for (i = 2; i <= 9 && i <= n1; i++) total1 += a[i]
      for (i = 2; i <= 9 && i <= n2; i++) total2 += b[i]
      idle1 = a[5] + a[6]
      idle2 = b[5] + b[6]
      dtotal = total2 - total1
      dbusy = (total2 - idle2) - (total1 - idle1)
      if (dtotal <= 0) exit 1
      printf "%.1f\n", 100 * dbusy / dtotal
    }')
  is_number "$usage" || die "failed to compute CPU usage from /proc/stat samples"
  CPU_PERCENT=$usage
}

collect_services() {
  local service state
  if [ ${#SERVICE_REQUESTS[@]} -eq 0 ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    for service in "${SERVICE_REQUESTS[@]}"; do
      state=$(systemctl is-active -- "$service" 2>/dev/null)
      [ -n "$state" ] || state="unknown"
      SERVICE_NAMES+=("$service")
      SERVICE_STATES+=("$state")
      if [ "$state" != "active" ]; then
        alert "systemd service $service is $state (expected active)"
      fi
    done
  else
    add_note "systemd/systemctl is not available; skipped service checks: ${SERVICE_REQUESTS[*]}"
    for service in "${SERVICE_REQUESTS[@]}"; do
      SERVICE_NAMES+=("$service")
      SERVICE_STATES+=("unavailable")
    done
  fi
}

port_is_listening() {
  local port=$1 snapshot=$2
  printf '%s\n' "$snapshot" | awk -v p="$port" '
    $4 ~ ("[:.]" p "$") { found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}

collect_ports() {
  local port output have_tool
  if [ ${#PORT_REQUESTS[@]} -eq 0 ]; then
    return 0
  fi

  have_tool=0
  PORT_TOOL=""
  PORT_SNAPSHOT=""
  if command -v ss >/dev/null 2>&1; then
    have_tool=1
    if output=$(ss -ltn 2>/dev/null); then
      PORT_TOOL=ss
      PORT_SNAPSHOT=$output
    fi
  fi
  if [ -z "$PORT_TOOL" ] && command -v netstat >/dev/null 2>&1; then
    have_tool=1
    if output=$(netstat -ltn 2>/dev/null); then
      PORT_TOOL=netstat
      PORT_SNAPSHOT=$output
    fi
  fi

  if [ -z "$PORT_TOOL" ]; then
    if [ "$have_tool" -eq 1 ]; then
      die "failed to list listening TCP sockets with ss/netstat"
    fi
    add_note "neither ss nor netstat is available; skipped port checks: ${PORT_REQUESTS[*]}"
    for port in "${PORT_REQUESTS[@]}"; do
      PORT_NUMBERS+=("$port")
      PORT_LISTENING+=(2)
    done
    return 0
  fi

  for port in "${PORT_REQUESTS[@]}"; do
    PORT_NUMBERS+=("$port")
    if port_is_listening "$port" "$PORT_SNAPSHOT"; then
      PORT_LISTENING+=(1)
    else
      PORT_LISTENING+=(0)
      alert "TCP port $port is not listening"
    fi
  done
}

evaluate_thresholds() {
  if numeric_gt "$DISK_PERCENT" "$DISK_WARN"; then
    alert "disk usage on / is ${DISK_PERCENT}% (warning threshold ${DISK_WARN}%)"
  fi
  if numeric_gt "$MEM_PERCENT" "$MEM_WARN"; then
    alert "memory usage is ${MEM_PERCENT}% (warning threshold ${MEM_WARN}%)"
  fi
  LOAD_LIMIT=$(awk -v cores="$CPU_CORES" -v factor="$LOAD_FACTOR" 'BEGIN { printf "%.10g", cores * factor }')
  if numeric_gt "$LOAD1" "$LOAD_LIMIT"; then
    alert "load1 ${LOAD1} exceeds ${LOAD_FACTOR} x ${CPU_CORES} CPU cores (${LOAD_LIMIT})"
  fi
}

collect() {
  require_proc
  collect_memory
  collect_disk
  collect_load
  collect_cores
  collect_services
  collect_ports
  collect_cpu
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

print_human() {
  local i mem_used_mib mem_total_mib state port_state
  printf 'ops-check report: %s (%s)\n' "$TIMESTAMP" "$SYS_HOSTNAME"
  printf '  CPU usage:   %s%% (sample interval: %ss)\n' "$CPU_PERCENT" "$CPU_INTERVAL"
  mem_used_mib=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAILABLE_KB" 'BEGIN { printf "%.1f", (t - a) / 1024 }')
  mem_total_mib=$(awk -v t="$MEM_TOTAL_KB" 'BEGIN { printf "%.1f", t / 1024 }')
  printf '  Memory:      %s%% used (%s MiB of %s MiB)\n' "$MEM_PERCENT" "$mem_used_mib" "$mem_total_mib"
  printf '  Disk /:      %s%% used (warning threshold: %s%%)\n' "$DISK_PERCENT" "$DISK_WARN"
  printf '  Load:        %s %s %s (CPU cores: %s, warning threshold: load1 > %s)\n' \
    "$LOAD1" "$LOAD5" "$LOAD15" "$CPU_CORES" "$LOAD_LIMIT"

  if [ ${#SERVICE_NAMES[@]} -gt 0 ]; then
    for ((i = 0; i < ${#SERVICE_NAMES[@]}; i++)); do
      state=${SERVICE_STATES[$i]}
      if [ "$state" = "unavailable" ]; then
        printf '  Service %s: not checked\n' "${SERVICE_NAMES[$i]}"
      else
        printf '  Service %s: %s\n' "${SERVICE_NAMES[$i]}" "$state"
      fi
    done
  fi

  if [ ${#PORT_NUMBERS[@]} -gt 0 ]; then
    for ((i = 0; i < ${#PORT_NUMBERS[@]}; i++)); do
      case "${PORT_LISTENING[$i]}" in
        1) port_state="listening" ;;
        0) port_state="NOT listening" ;;
        *) port_state="not checked" ;;
      esac
      printf '  Port %s: %s\n' "${PORT_NUMBERS[$i]}" "$port_state"
    done
  fi

  if [ ${#NOTES[@]} -gt 0 ]; then
    for ((i = 0; i < ${#NOTES[@]}; i++)); do
      printf '  Note: %s\n' "${NOTES[$i]}"
    done
  fi

  if [ ${#ALERTS[@]} -eq 0 ]; then
    printf 'Result: OK\n'
  else
    printf 'Result: ALERT (%s)\n' "${#ALERTS[@]}"
  fi
}

print_json() {
  local i separator status exit_code active_json listening_json
  if [ ${#ALERTS[@]} -eq 0 ]; then
    status="ok"
    exit_code=$EXIT_OK
  else
    status="alert"
    exit_code=$EXIT_ALERT
  fi

  printf '{\n'
  printf '  "status": "%s",\n' "$status"
  printf '  "exit_code": %s,\n' "$exit_code"
  printf '  "timestamp": "%s",\n' "$(json_escape "$TIMESTAMP")"
  printf '  "hostname": "%s",\n' "$(json_escape "$SYS_HOSTNAME")"
  printf '  "cpu": {"usage_percent": %s, "sample_interval_seconds": %s},\n' "$CPU_PERCENT" "$CPU_INTERVAL"
  printf '  "memory": {"usage_percent": %s, "total_kb": %s, "available_kb": %s},\n' \
    "$MEM_PERCENT" "$MEM_TOTAL_KB" "$MEM_AVAILABLE_KB"
  printf '  "disk": {"mount": "/", "usage_percent": %s},\n' "$DISK_PERCENT"
  printf '  "load": {"load1": %s, "load5": %s, "load15": %s, "cpu_cores": %s},\n' \
    "$LOAD1" "$LOAD5" "$LOAD15" "$CPU_CORES"
  printf '  "thresholds": {"disk_warn_percent": %s, "mem_warn_percent": %s, "load_factor": %s},\n' \
    "$DISK_WARN" "$MEM_WARN" "$LOAD_FACTOR"

  printf '  "services": ['
  separator=""
  for ((i = 0; i < ${#SERVICE_NAMES[@]}; i++)); do
    case "${SERVICE_STATES[$i]}" in
      active) active_json="true" ;;
      unavailable) active_json="null" ;;
      *) active_json="false" ;;
    esac
    printf '%s{"name": "%s", "state": "%s", "active": %s}' \
      "$separator" "$(json_escape "${SERVICE_NAMES[$i]}")" \
      "$(json_escape "${SERVICE_STATES[$i]}")" "$active_json"
    separator=", "
  done
  printf '],\n'

  printf '  "ports": ['
  separator=""
  for ((i = 0; i < ${#PORT_NUMBERS[@]}; i++)); do
    case "${PORT_LISTENING[$i]}" in
      1) listening_json="true" ;;
      0) listening_json="false" ;;
      *) listening_json="null" ;;
    esac
    printf '%s{"port": %s, "listening": %s}' \
      "$separator" "${PORT_NUMBERS[$i]}" "$listening_json"
    separator=", "
  done
  printf '],\n'

  printf '  "alerts": ['
  separator=""
  for ((i = 0; i < ${#ALERTS[@]}; i++)); do
    printf '%s"%s"' "$separator" "$(json_escape "${ALERTS[$i]}")"
    separator=", "
  done
  printf '],\n'

  printf '  "notes": ['
  separator=""
  for ((i = 0; i < ${#NOTES[@]}; i++)); do
    printf '%s"%s"' "$separator" "$(json_escape "${NOTES[$i]}")"
    separator=", "
  done
  printf ']\n'
  printf '}\n'
}

print_output() {
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    print_json
  else
    print_human
  fi
}

main() {
  parse_args "$@"
  validate_config
  parse_requested_services
  parse_requested_ports

  SYS_HOSTNAME=$(hostname 2>/dev/null) || SYS_HOSTNAME=""
  if [ -z "$SYS_HOSTNAME" ]; then
    SYS_HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null) || SYS_HOSTNAME="unknown"
  fi

  collect
  evaluate_thresholds

  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || die "failed to get the current time"
  print_output

  if [ ${#ALERTS[@]} -gt 0 ]; then
    exit "$EXIT_ALERT"
  fi
  exit "$EXIT_OK"
}

main "$@"
