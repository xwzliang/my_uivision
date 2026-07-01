#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVIDER="${PROVIDER:-gemini}"

BASE_CSV="${BASE_CSV:-/Users/broliang/Pictures/short_drama/ui_vision.csv}"
ROW_CONTROL_CSV="${ROW_CONTROL_CSV:-/Users/broliang/Pictures/short_drama/ui_vision_row_control.csv}"

# Generate the File: Open the UI.Vision RPA extension, go to Settings > API tab, and click "Create autorun HTML"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_FILE="${LOG_FILE:-/Users/broliang/uivision/uivision.log}"
APPLE_SCRIPT="${APPLE_SCRIPT:-$SCRIPT_DIR/launch_uivision_macro.scpt}"
LOG_TIMEOUT="${LOG_TIMEOUT:-2400}"
ROW_TIME_LIMIT="${ROW_TIME_LIMIT:-2400}"
FAIL_SETTLE_TIME="${FAIL_SETTLE_TIME:-8}"
MAX_PASSES="${MAX_PASSES:-5}"
RUN_ONE_ROW_ONLY="${RUN_ONE_ROW_ONLY:-0}"
OVERWRITE_OUTPUT="${OVERWRITE_OUTPUT:-0}"
RELAUNCH_CHROME_AFTER_ROW="${RELAUNCH_CHROME_AFTER_ROW:-0}"
INITIAL_CHROME_RELAUNCH_DONE=0
UPLOAD_BACKOFF_SECONDS="${UPLOAD_BACKOFF_SECONDS:-1800}"
SEND_DISABLED_BACKOFF_SECONDS="${SEND_DISABLED_BACKOFF_SECONDS:-1800}"
RATE_LIMIT_BACKOFF_PADDING_SECONDS="${RATE_LIMIT_BACKOFF_PADDING_SECONDS:-180}"
LAST_RATE_LIMIT_BACKOFF_SECONDS=0
HEALTH_CONTEXT_CSV="${HEALTH_CONTEXT_CSV:-/tmp/uivision_health_context.csv}"
AUTOSTART_STUCK_TIMEOUT="${AUTOSTART_STUCK_TIMEOUT:-45}"
AUTOSTART_STUCK_TIMEOUT_CAP="${AUTOSTART_STUCK_TIMEOUT_CAP:-120}"
MAX_LAUNCH_ATTEMPTS="${MAX_LAUNCH_ATTEMPTS:-3}"
UPLOAD_BACKOFF_MARKER="UPLOAD_CAPACITY_RETRY_LATER"
SEND_DISABLED_BACKOFF_MARKER="SEND_DISABLED_RETRY_LATER"
RATE_LIMIT_BACKOFF_MARKER="IMAGE_RATE_LIMIT_RETRY_LATER"
TOO_MANY_REQUESTS_BACKOFF_MARKER="TOO_MANY_REQUESTS_RETRY_LATER"

usage() {
  echo "Usage: $0 [--provider gemini|chatgpt] [--overwrite|--no-overwrite] [--relaunch-chrome-after-row|--keep-chrome-after-row] [image|storyboard|sora|chat|camera] [start_row] [all|single] [overwrite]" >&2
  echo "       $0 [--provider gemini|chatgpt] [--overwrite|--no-overwrite] [--relaunch-chrome-after-row|--keep-chrome-after-row] [image|storyboard|sora|chat|camera] [start_row] [end_row] [all|single] [overwrite]" >&2
  echo "       $0 [--provider gemini|chatgpt] [--overwrite|--no-overwrite] [--relaunch-chrome-after-row|--keep-chrome-after-row] [image|storyboard|sora|chat|camera] [row1,row2,row3] [all|single] [overwrite]" >&2
  echo "       $0 [--provider gemini|chatgpt] [--overwrite|--no-overwrite] [--relaunch-chrome-after-row|--keep-chrome-after-row] [image|storyboard|sora|chat|camera] [start-end] [all|single] [overwrite]" >&2
  exit 2
}

is_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

read_macro_name_from_json() {
  local macro_file="$1"

  python3 - "$macro_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

name = (data.get("Name") or "").strip()
if not name:
    raise SystemExit(1)

print(name)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--provider|--agent)
      shift
      [[ $# -gt 0 ]] || usage
      PROVIDER="$1"
      shift
      ;;
    -o|--overwrite)
      OVERWRITE_OUTPUT=1
      shift
      ;;
    --no-overwrite)
      OVERWRITE_OUTPUT=0
      shift
      ;;
    --relaunch-chrome-after-row)
      RELAUNCH_CHROME_AFTER_ROW=1
      shift
      ;;
    --keep-chrome-after-row|--no-relaunch-chrome-after-row)
      RELAUNCH_CHROME_AFTER_ROW=0
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

PROVIDER="$(printf '%s' "$PROVIDER" | tr '[:upper:]' '[:lower:]')"

MODE="$(printf '%s' "${1:-image}" | tr '[:upper:]' '[:lower:]')"
ROW_ARG="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"
ARG5="${5:-}"

case "$PROVIDER" in
  gemini|chatgpt)
    ;;
  *)
    echo "Unsupported provider: $PROVIDER" >&2
    usage
    ;;
esac

case "$MODE" in
  image)
    SUCCESS_MARKER="ROW_PROCESS_COMPLETED"
    FAILURE_MARKER="ROW_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="image_prompts.csv"
    ;;
  storyboard)
    MACRO_NAME="GeminiStoryboardSingleRow"
    SUCCESS_MARKER="SEGMENT_PROCESS_COMPLETED"
    FAILURE_MARKER="SEGMENT_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="segments_prompts/segments.csv"
    ;;
  sora)
    MACRO_NAME="SoraVideoSingleRow"
    MACRO_FILE="$SCRIPT_DIR/sora_single_row.json"
    LOG_MODE_TAG="sora"
    SUCCESS_MARKER="SORA_PROCESS_COMPLETED"
    FAILURE_MARKER="SORA_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="segments_prompts/video_prompts.csv"
    ;;
  *)
    case "$MODE" in
      chat)
        SUCCESS_MARKER="CHAT_PROCESS_COMPLETED"
        FAILURE_MARKER="CHAT_PROCESS_FAILED"
        SOURCE_RELATIVE_CSV="chat_prompts.csv"
        ;;
      camera)
        SUCCESS_MARKER="CAMERA_PROCESS_COMPLETED"
        FAILURE_MARKER="CAMERA_PROCESS_FAILED"
        SOURCE_RELATIVE_CSV="camera_prompts.csv"
        ;;
      *)
        usage
        ;;
    esac
    ;;
esac

if [[ "$MODE" != "sora" ]]; then
  MACRO_FILE="$SCRIPT_DIR/$PROVIDER/${PROVIDER}_${MODE}_single_row.json"
  LOG_MODE_TAG="${PROVIDER}_${MODE}"
  if [[ ! -f "$MACRO_FILE" ]]; then
    echo "Missing macro for provider '$PROVIDER' and mode '$MODE': $MACRO_FILE" >&2
    exit 1
  fi

  if ! MACRO_NAME="$(read_macro_name_from_json "$MACRO_FILE")"; then
    echo "Could not read macro Name from $MACRO_FILE" >&2
    exit 1
  fi
fi

if [[ ! -f "$MACRO_FILE" ]]; then
  echo "Missing macro file: $MACRO_FILE" >&2
  exit 1
fi

if [[ ! -f "$BASE_CSV" ]]; then
  echo "Missing base CSV: $BASE_CSV" >&2
  exit 1
fi

if [[ ! -f "$APPLE_SCRIPT" ]]; then
  echo "Missing AppleScript launcher: $APPLE_SCRIPT" >&2
  exit 1
fi

base_dir="$(awk -F',' 'NR==1 { print $1; exit }' "$BASE_CSV" | tr -d '\r')"
base_dir="${base_dir#\"}"
base_dir="${base_dir%\"}"

if [[ -z "$base_dir" ]]; then
  echo "Could not read base directory from $BASE_CSV" >&2
  exit 1
fi

source_csv="$base_dir/$SOURCE_RELATIVE_CSV"
if [[ ! -f "$source_csv" ]]; then
  echo "Missing source CSV for $MODE mode: $source_csv" >&2
  exit 1
fi

mkdir -p "$(dirname "$ROW_CONTROL_CSV")"
mkdir -p "$(dirname "$LOG_FILE")"

LOG_DIR="$(dirname "$LOG_FILE")"
LOG_BASENAME="$(basename "$LOG_FILE")"
if [[ "$LOG_BASENAME" == *.* ]]; then
  LOG_STEM="${LOG_BASENAME%.*}"
  LOG_EXT=".${LOG_BASENAME##*.}"
else
  LOG_STEM="$LOG_BASENAME"
  LOG_EXT=""
fi

declare -a target_rows=()
declare -a OPTION_ARGS=()
has_explicit_row_targets=0

if [[ -n "$ROW_ARG" ]]; then
  if [[ "$ROW_ARG" == *,* ]]; then
    IFS=',' read -r -a raw_rows <<< "$ROW_ARG"
    for row_item in "${raw_rows[@]}"; do
      row_item="${row_item//[[:space:]]/}"
      if ! is_positive_int "$row_item"; then
        usage
      fi
      target_rows+=("$row_item")
    done
    has_explicit_row_targets=1
    OPTION_ARGS=("$ARG3" "$ARG4" "$ARG5")
  elif [[ "$ROW_ARG" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
    range_start="${BASH_REMATCH[1]}"
    range_end="${BASH_REMATCH[2]}"
    if (( range_start > range_end )); then
      echo "Invalid range: $ROW_ARG" >&2
      exit 2
    fi
    for ((row=range_start; row<=range_end; row++)); do
      target_rows+=("$row")
    done
    has_explicit_row_targets=1
    OPTION_ARGS=("$ARG3" "$ARG4" "$ARG5")
  elif is_positive_int "$ROW_ARG"; then
    if [[ -n "$ARG3" ]] && is_positive_int "$ARG3"; then
      range_start="$ROW_ARG"
      range_end="$ARG3"
      if (( range_start > range_end )); then
        echo "Invalid range: $ROW_ARG $ARG3" >&2
        exit 2
      fi
      for ((row=range_start; row<=range_end; row++)); do
        target_rows+=("$row")
      done
      has_explicit_row_targets=1
      OPTION_ARGS=("$ARG4" "$ARG5")
    else
      current_row="$ROW_ARG"
      OPTION_ARGS=("$ARG3" "$ARG4" "$ARG5")
    fi
  elif [[ "$ROW_ARG" =~ ^(single|once|one|all|true|false|overwrite|no-overwrite|overwrite=true|overwrite=false|overwrite=1|overwrite=0)$ ]]; then
    OPTION_ARGS=("$ROW_ARG" "$ARG3" "$ARG4" "$ARG5")
  else
    usage
  fi
fi

if (( has_explicit_row_targets == 1 )); then
  if (( ${#target_rows[@]} == 0 )); then
    usage
  fi
  current_row="${target_rows[0]}"
elif [[ -z "${current_row:-}" ]]; then
  if [[ -f "$ROW_CONTROL_CSV" ]]; then
    current_row="$(tr -d '\r\n' < "$ROW_CONTROL_CSV")"
  else
    current_row="1"
  fi
fi

if ! is_positive_int "$current_row"; then
  echo "Invalid start row '$current_row'; defaulting to 1" >&2
  current_row="1"
fi

if [[ ! "$MAX_PASSES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid MAX_PASSES '$MAX_PASSES'; defaulting to 5" >&2
  MAX_PASSES="5"
fi

if [[ ! "$ROW_TIME_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid ROW_TIME_LIMIT '$ROW_TIME_LIMIT'; defaulting to 2400" >&2
  ROW_TIME_LIMIT="2400"
fi

if [[ ! "$FAIL_SETTLE_TIME" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid FAIL_SETTLE_TIME '$FAIL_SETTLE_TIME'; defaulting to 8" >&2
  FAIL_SETTLE_TIME="8"
fi

if [[ ! "$AUTOSTART_STUCK_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid AUTOSTART_STUCK_TIMEOUT '$AUTOSTART_STUCK_TIMEOUT'; defaulting to 45" >&2
  AUTOSTART_STUCK_TIMEOUT="45"
fi

if [[ ! "$AUTOSTART_STUCK_TIMEOUT_CAP" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid AUTOSTART_STUCK_TIMEOUT_CAP '$AUTOSTART_STUCK_TIMEOUT_CAP'; defaulting to 120" >&2
  AUTOSTART_STUCK_TIMEOUT_CAP="120"
fi

if (( AUTOSTART_STUCK_TIMEOUT > AUTOSTART_STUCK_TIMEOUT_CAP )); then
  echo "AUTOSTART_STUCK_TIMEOUT '$AUTOSTART_STUCK_TIMEOUT' is too high for reliable empty-log stuck-page detection; clamping to ${AUTOSTART_STUCK_TIMEOUT_CAP}s." >&2
  AUTOSTART_STUCK_TIMEOUT="$AUTOSTART_STUCK_TIMEOUT_CAP"
fi

if [[ ! "$MAX_LAUNCH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid MAX_LAUNCH_ATTEMPTS '$MAX_LAUNCH_ATTEMPTS'; defaulting to 3" >&2
  MAX_LAUNCH_ATTEMPTS="3"
fi

for option_arg in "${OPTION_ARGS[@]}"; do
  [[ -z "$option_arg" ]] && continue
  case "$option_arg" in
    single|once|one|true|1)
      RUN_ONE_ROW_ONLY=1
      ;;
    all|false|0)
      RUN_ONE_ROW_ONLY=0
      ;;
    overwrite|overwrite=true|overwrite=1)
      OVERWRITE_OUTPUT=1
      ;;
    no-overwrite|overwrite=false|overwrite=0)
      OVERWRITE_OUTPUT=0
      ;;
    *)
      usage
      ;;
  esac
done

if [[ ! "$RUN_ONE_ROW_ONLY" =~ ^[01]$ ]]; then
  echo "Invalid RUN_ONE_ROW_ONLY '$RUN_ONE_ROW_ONLY'; defaulting to 0" >&2
  RUN_ONE_ROW_ONLY=0
fi

if [[ ! "$OVERWRITE_OUTPUT" =~ ^[01]$ ]]; then
  echo "Invalid OVERWRITE_OUTPUT '$OVERWRITE_OUTPUT'; defaulting to 0" >&2
  OVERWRITE_OUTPUT=0
fi

if [[ ! "$RELAUNCH_CHROME_AFTER_ROW" =~ ^[01]$ ]]; then
  echo "Invalid RELAUNCH_CHROME_AFTER_ROW '$RELAUNCH_CHROME_AFTER_ROW'; defaulting to 0" >&2
  RELAUNCH_CHROME_AFTER_ROW=0
fi

if (( has_explicit_row_targets == 1 )) && (( RUN_ONE_ROW_ONLY == 1 )); then
  target_rows=("${target_rows[0]}")
fi

build_log_file_path() {
  local row="$1"
  local pass="$2"
  printf '%s/%s_%s_row_%s_pass_%s%s' \
    "$LOG_DIR" "$LOG_STEM" "$LOG_MODE_TAG" "$row" "$pass" "$LOG_EXT"
}

stop_uivision_instances() {
  local remaining_tabs
  local attempt

  echo "Stopping running UI.Vision tabs before continuing" >&2
  for attempt in 1 2 3 4 5; do
    osascript \
      -e 'tell application "Google Chrome"' \
      -e 'repeat with w in windows' \
      -e 'set tab_list to every tab of w' \
      -e 'repeat with t in tab_list' \
      -e 'try' \
      -e 'set tab_url to URL of t' \
      -e 'if tab_url contains "ui.vision.html" then close t' \
      -e 'end try' \
      -e 'end repeat' \
      -e 'end repeat' \
      -e 'end tell' >/dev/null 2>&1 || true

    remaining_tabs="$(osascript \
      -e 'tell application "Google Chrome"' \
      -e 'set tab_count to 0' \
      -e 'repeat with w in windows' \
      -e 'repeat with t in tabs of w' \
      -e 'try' \
      -e 'set tab_url to URL of t' \
      -e 'if tab_url contains "ui.vision.html" then set tab_count to tab_count + 1' \
      -e 'end try' \
      -e 'end repeat' \
      -e 'end repeat' \
      -e 'return tab_count' \
      -e 'end tell' 2>/dev/null || printf '0')"

    if [[ "$remaining_tabs" == "0" ]]; then
      break
    fi

    sleep 1
  done

  sleep 1
}

restart_chrome() {
  echo "Restarting Google Chrome to recover UI.Vision autorun state" >&2
  osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
  sleep 3
  open -a "Google Chrome" >/dev/null 2>&1 || true
  sleep 5
  echo "Restoring Chrome fullscreen after relaunch" >&2
  osascript \
    -e 'tell application "Google Chrome" to activate' \
    -e 'tell application "System Events" to keystroke "f" using {control down, command down}' \
    >/dev/null 2>&1 || true
  sleep 2
}

count_uivision_tabs() {
  osascript \
    -e 'tell application "Google Chrome"' \
    -e 'set tab_count to 0' \
    -e 'repeat with w in windows' \
    -e 'repeat with t in tabs of w' \
    -e 'try' \
    -e 'set tab_url to URL of t' \
    -e 'if tab_url contains "ui.vision.html" then set tab_count to tab_count + 1' \
    -e 'end try' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'return tab_count' \
    -e 'end tell' 2>/dev/null || printf '0'
}

wait_for_row_result() {
  local started_at
  local now
  local elapsed=0
  local last_reported_minute=-1
  local last_log_size=-1
  local current_log_size=0
  local last_log_activity_at
  local log_idle_seconds=0
  local open_uivision_tabs=0

  started_at="$(date +%s)"
  last_log_activity_at="$started_at"

  while true; do
    now="$(date +%s)"
    elapsed=$(( now - started_at ))

    if (( elapsed > ROW_TIME_LIMIT )); then
      echo "Row $current_row exceeded the time limit of ${ROW_TIME_LIMIT}s; marking for retry." >&2
      return 1
    fi

    if [[ ! -s "$CURRENT_LOG_FILE" ]]; then
      open_uivision_tabs="$(count_uivision_tabs)"
      if (( elapsed >= AUTOSTART_STUCK_TIMEOUT )) && [[ "$open_uivision_tabs" != "0" ]]; then
        echo "Detected UI.Vision autorun page stuck open for row $current_row with an empty log after ${elapsed}s; restarting Chrome and retrying the same row." >&2
        return 4
      fi
      if (( elapsed > LOG_TIMEOUT )); then
        echo "UI.Vision log stayed empty for more than ${LOG_TIMEOUT}s" >&2
        return 1
      fi
    else
      current_log_size="$(wc -c < "$CURRENT_LOG_FILE" | tr -d ' ')"
      if [[ "$current_log_size" != "$last_log_size" ]]; then
        last_log_size="$current_log_size"
        last_log_activity_at="$now"
      fi
      log_idle_seconds=$(( now - last_log_activity_at ))

      if grep -q "ROW_CONTROL_READ_FAILED" "$CURRENT_LOG_FILE" \
        || grep -q "REQUESTED_ROW_NOT_FOUND row=${current_row}" "$CURRENT_LOG_FILE" \
        || grep -q "${FAILURE_MARKER} row=${current_row}" "$CURRENT_LOG_FILE" \
        || grep -q 'Macro completed' "$CURRENT_LOG_FILE" \
        || grep -q "${SUCCESS_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
        return 0
      fi

      if grep -q '\[error\] E225: DOM failed to be ready in 30sec\.' "$CURRENT_LOG_FILE"; then
        echo "Detected UI.Vision DOM-ready failure for row $current_row; forcing relaunch." >&2
        return 5
      fi

      if grep -q 'Macro failed' "$CURRENT_LOG_FILE" \
        && (( log_idle_seconds >= FAIL_SETTLE_TIME )); then
        echo "Detected a stopped UI.Vision macro for row $current_row after ${log_idle_seconds}s of log inactivity; marking for retry." >&2
        return 2
      fi
    fi

    if (( elapsed / 60 > last_reported_minute )); then
      last_reported_minute=$((elapsed / 60))
      echo "Row $current_row running for ${elapsed}s (time limit ${ROW_TIME_LIMIT}s)"
    fi

    sleep 1
  done
}

get_output_paths_for_row() {
  local row="$1"

  python3 - "$source_csv" "$row" "$MODE" "$base_dir" <<'PY' || true
import csv
import os
import sys

source_csv, row_arg, mode, base_dir = sys.argv[1:]
row_number = int(row_arg)

csv.field_size_limit(sys.maxsize)

def clean(value: str) -> str:
    return (value or "").strip().strip('"').strip()

try:
    with open(source_csv, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        for current_index, row in enumerate(reader, start=1):
            if current_index != row_number:
                continue
            cols = [clean(col) for col in row]
            outputs = []
            if mode in {"image", "chat", "camera"}:
                output_path = ""
                if mode == "chat":
                    if len(cols) >= 4 and cols[3]:
                        output_path = cols[3]
                    elif len(cols) >= 3 and cols[2]:
                        output_path = cols[2]
                elif len(cols) >= 3 and cols[2]:
                    output_path = cols[2]
                if output_path:
                    outputs.append(output_path)
                    if mode == "image":
                        outputs.append(os.path.join(os.path.dirname(output_path), "violation.txt"))
            elif mode == "storyboard":
                if len(cols) >= 2 and cols[1]:
                    outputs.append(os.path.join(base_dir, "segments_prompts", cols[1], "output", "storyboard.png"))
                    outputs.append(os.path.join(base_dir, "segments_prompts", cols[1], "output", "violation.txt"))
            elif mode == "sora":
                if len(cols) >= 2 and cols[1]:
                    outputs.append(os.path.join(base_dir, "segments_prompts", cols[1], "output", "clip.mp4"))
                    outputs.append(os.path.join(base_dir, "segments_prompts", cols[1], "output", "sora.mp4"))
            for output in outputs:
                print(output)
            break
except FileNotFoundError:
    pass
PY
}

find_blocking_failed_dependency_row() {
  local row="$1"
  shift || true

  if [[ "$MODE" != "image" ]]; then
    return 1
  fi

  if (( $# == 0 )); then
    return 1
  fi

  python3 - "$source_csv" "$row" "$@" <<'PY'
import csv
import sys

source_csv = sys.argv[1]
target_row = int(sys.argv[2])
csv.field_size_limit(sys.maxsize)
candidate_rows = []
for raw in sys.argv[3:]:
    try:
        candidate_rows.append(int(raw))
    except ValueError:
        pass

candidate_rows = sorted({row for row in candidate_rows if row < target_row})
if not candidate_rows:
    raise SystemExit(1)

def clean(value: str) -> str:
    return (value or "").strip().strip('"').strip()

def split_paths(value: str):
    return [part.strip() for part in clean(value).split("|") if part.strip()]

target_inputs = set()
candidate_outputs = {}

with open(source_csv, newline="", encoding="utf-8") as handle:
    for current_index, row in enumerate(csv.reader(handle), start=1):
        cols = [clean(col) for col in row]
        if current_index == target_row and len(cols) >= 2:
            target_inputs = set(split_paths(cols[1]))
        if current_index in candidate_rows and len(cols) >= 3 and cols[2]:
            candidate_outputs[current_index] = cols[2]

if not target_inputs:
    raise SystemExit(1)

for candidate_row in candidate_rows:
    output_path = candidate_outputs.get(candidate_row, "")
    if output_path and output_path in target_inputs:
        print(candidate_row)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

source_row_exists() {
  local row="$1"

  python3 - "$source_csv" "$row" <<'PY'
import csv
import sys

source_csv, row_arg = sys.argv[1:]
target_row = int(row_arg)

csv.field_size_limit(sys.maxsize)

try:
    with open(source_csv, newline="", encoding="utf-8") as handle:
        for current_index, _row in enumerate(csv.reader(handle), start=1):
            if current_index == target_row:
                raise SystemExit(0)
except FileNotFoundError:
    pass

raise SystemExit(1)
PY
}

find_existing_output_for_row() {
  local row="$1"
  local include_violation_output="${2:-1}"
  local output_path

  while IFS= read -r output_path; do
    [[ -z "$output_path" ]] && continue
    if [[ "$include_violation_output" != "1" ]] && [[ "$(basename "$output_path")" == "violation.txt" ]]; then
      continue
    fi
    if [[ "$MODE" == "chat" || "$MODE" == "camera" ]]; then
      if [[ -s "$output_path" ]]; then
        printf '%s\n' "$output_path"
        return 0
      fi
      continue
    fi
    if [[ -e "$output_path" ]]; then
      printf '%s\n' "$output_path"
      return 0
    fi
  done < <(get_output_paths_for_row "$row")

  return 1
}

get_violation_output_path_for_row() {
  local row="$1"
  local output_path

  while IFS= read -r output_path; do
    [[ -z "$output_path" ]] && continue
    if [[ "$(basename "$output_path")" == "violation.txt" ]]; then
      printf '%s\n' "$output_path"
      return 0
    fi
  done < <(get_output_paths_for_row "$row")

  return 1
}

build_output_backup_path() {
  local output_path="$1"
  local timestamp
  local backup_path
  local suffix=1

  timestamp="$(date '+%Y%m%d_%H%M%S')"
  backup_path="${output_path}.bak.${timestamp}"

  while [[ -e "$backup_path" || -L "$backup_path" ]]; do
    backup_path="${output_path}.bak.${timestamp}.${suffix}"
    suffix=$((suffix + 1))
  done

  printf '%s\n' "$backup_path"
}

prepare_output_paths_for_overwrite() {
  local row="$1"
  local output_path
  local backup_path

  while IFS= read -r output_path; do
    [[ -z "$output_path" ]] && continue
    if [[ -e "$output_path" || -L "$output_path" ]]; then
      backup_path="$(build_output_backup_path "$output_path")"
      mkdir -p "$(dirname "$backup_path")"
      cp -p "$output_path" "$backup_path"
      echo "Backed up existing output for row $row: $output_path -> $backup_path"
      rm -f "$output_path"
      echo "Removed original output path for row $row: $output_path"
    fi
  done < <(get_output_paths_for_row "$row")
}

materialize_guardrail_violation_output_for_row() {
  local row="$1"
  local log_file="$2"
  local violation_output_path

  if ! violation_output_path="$(get_violation_output_path_for_row "$row")"; then
    return 1
  fi

  python3 - "$log_file" "$violation_output_path" "$row" <<'PY'
import pathlib
import sys

log_file, output_path, row = sys.argv[1:]
begin_marker = f"GUARDRAIL_RESPONSE_BEGIN row={row}"
end_marker = f"GUARDRAIL_RESPONSE_END row={row}"

current_lines = None
captured_blocks = []

try:
    with open(log_file, encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if line.startswith("[echo] "):
                payload = line[7:]
            elif line.startswith("[echo]"):
                payload = line[6:].lstrip()
            else:
                payload = line

            if payload == begin_marker:
                current_lines = []
                continue

            if payload == end_marker:
                if current_lines is not None:
                    captured_blocks.append("\n".join(current_lines).strip())
                current_lines = None
                continue

            if current_lines is None:
                continue

            if line.startswith("[info] Executing:"):
                continue

            current_lines.append(payload)
except FileNotFoundError:
    raise SystemExit(1)

content = ""
for block in reversed(captured_blocks):
    if block:
        content = block
        break

if not content:
    raise SystemExit(1)

output = pathlib.Path(output_path)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(content + "\n", encoding="utf-8")
PY
}

ensure_output_created_for_row() {
  local row="$1"
  local output_path

  if output_path="$(find_existing_output_for_row "$row")"; then
    echo "Verified output for row $row: $output_path"
    return 0
  fi

  echo "Expected output for row $row was not created after macro completion; marking for retry." >&2
  while IFS= read -r output_path; do
    [[ -z "$output_path" ]] && continue
    echo "Missing expected output path: $output_path" >&2
  done < <(get_output_paths_for_row "$row")

  return 1
}

wait_before_next_row() {
  echo "Waiting 5 seconds before starting the next row"
  sleep 5
}

format_retry_clock_time() {
  local wait_seconds="$1"

  python3 - "$wait_seconds" <<'PY'
from datetime import datetime, timedelta
import sys

wait_seconds = int(sys.argv[1])
retry_time = datetime.now() + timedelta(seconds=wait_seconds)
print(retry_time.strftime("%H:%M:%S"))
PY
}

wait_before_upload_backoff_retry() {
  local row="$1"
  local retry_clock_time

  retry_clock_time="$(format_retry_clock_time "$UPLOAD_BACKOFF_SECONDS")"

  echo "Row $row hit upload capacity throttling; waiting ${UPLOAD_BACKOFF_SECONDS}s before retrying the same row at ${retry_clock_time}"
  sleep "$UPLOAD_BACKOFF_SECONDS"
}

wait_before_send_disabled_backoff_retry() {
  local row="$1"
  local retry_clock_time

  retry_clock_time="$(format_retry_clock_time "$SEND_DISABLED_BACKOFF_SECONDS")"

  echo "Row $row ended with a disabled send button and no quota reset message; waiting ${SEND_DISABLED_BACKOFF_SECONDS}s before retrying the same row at ${retry_clock_time}"
  sleep "$SEND_DISABLED_BACKOFF_SECONDS"
}

wait_before_too_many_requests_backoff_retry() {
  local row="$1"
  local wait_minutes
  local wait_seconds
  local retry_clock_time

  wait_minutes=$((3 + RANDOM % 4))
  wait_seconds=$((wait_minutes * 60))
  retry_clock_time="$(format_retry_clock_time "$wait_seconds")"

  echo "Row $row hit ChatGPT too-many-requests throttling; waiting ${wait_minutes} minutes (${wait_seconds}s) before retrying the same row at ${retry_clock_time}"
  sleep "$wait_seconds"
}

extract_rate_limit_backoff_seconds() {
  local log_file="$1"
  local row="$2"
  python3 - "$log_file" "$row" <<'PY'
import re
import sys
from datetime import datetime, timedelta

log_file, row = sys.argv[1], sys.argv[2]
target_marker = f"IMAGE_RATE_LIMIT_RETRY_LATER row={row}"
text_prefix = "IMAGE_RATE_LIMIT_TEXT="

last_text = None
seen_marker = False

with open(log_file, encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if text_prefix in line:
            idx = line.find(text_prefix)
            last_text = line[idx + len(text_prefix):]
        if target_marker in line:
            seen_marker = True

if not seen_marker or not last_text:
    raise SystemExit(1)

text = last_text.lower()
total = 0

hour_match = re.search(r'(\d+)\s*hour', text)
if hour_match:
    total += int(hour_match.group(1)) * 3600

minute_match = re.search(r'(\d+)\s*minute', text)
if minute_match:
    total += int(minute_match.group(1)) * 60

second_match = re.search(r'(\d+)\s*second', text)
if second_match:
    total += int(second_match.group(1))

until_match = re.search(r'(?:until|reset(?:s)?\s+at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)', text)
if total <= 0 and until_match:
    hour = int(until_match.group(1))
    minute = int(until_match.group(2) or 0)
    ampm = until_match.group(3)
    if ampm == "pm" and hour < 12:
        hour += 12
    if ampm == "am" and hour == 12:
        hour = 0

    now = datetime.now()
    retry_at = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if retry_at <= now:
        retry_at += timedelta(days=1)
    total = max(60, int((retry_at - now).total_seconds()))

if total <= 0:
    total = 3600

print(total)
PY
}

wait_before_rate_limit_backoff_retry() {
  local row="$1"
  local retry_seconds="${LAST_RATE_LIMIT_BACKOFF_SECONDS:-0}"
  local total_wait
  local retry_clock_time

  if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
    retry_seconds=0
  fi

  total_wait=$((retry_seconds + RATE_LIMIT_BACKOFF_PADDING_SECONDS))
  retry_clock_time="$(format_retry_clock_time "$total_wait")"
  echo "Row $row hit ChatGPT image generation rate limiting; waiting ${retry_seconds}s plus ${RATE_LIMIT_BACKOFF_PADDING_SECONDS}s buffer before retrying the same row at ${retry_clock_time}"
  sleep "$total_wait"
}

finish_row_browser_cycle() {
  stop_uivision_instances

  if (( RELAUNCH_CHROME_AFTER_ROW == 1 )); then
    echo "Relaunching Chrome after row completion because RELAUNCH_CHROME_AFTER_ROW=1"
    restart_chrome
  fi
}

run_one_row() {
  local row="$1"
  local pass="$2"
  local existing_output_path
  local expected_output_path=""
  local output_path_candidate
  local launch_attempt=1
  local wait_status
  local autostart_recovery_count=0

  LAST_RATE_LIMIT_BACKOFF_SECONDS=0
  current_row="$row"

  if ! source_row_exists "$row"; then
    echo "Row $current_row is beyond the end of $source_csv; stopping before launching the macro"
    return 2
  fi

  if (( OVERWRITE_OUTPUT == 0 )); then
    if existing_output_path="$(find_existing_output_for_row "$row" 0)"; then
      echo "Skipping row $current_row because output already exists and overwrite is disabled: $existing_output_path"
      return 3
    fi
  else
    prepare_output_paths_for_overwrite "$row"
  fi

  if (( RELAUNCH_CHROME_AFTER_ROW == 1 )) && (( INITIAL_CHROME_RELAUNCH_DONE == 0 )); then
    echo "Relaunching Chrome before processing the first row because RELAUNCH_CHROME_AFTER_ROW=1"
    restart_chrome
    INITIAL_CHROME_RELAUNCH_DONE=1
  fi

  stop_uivision_instances

  CURRENT_LOG_FILE="$(build_log_file_path "$row" "$pass")"
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
  printf '"%s","%s","%s"\n' "$CURRENT_LOG_FILE" "$current_row" "$MACRO_NAME" > "$HEALTH_CONTEXT_CSV"
  target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$CURRENT_LOG_FILE"

  while IFS= read -r output_path_candidate; do
    [[ -z "$output_path_candidate" ]] && continue
    if [[ "$(basename "$output_path_candidate")" == "violation.txt" ]]; then
      continue
    fi
    expected_output_path="$output_path_candidate"
    break
  done < <(get_output_paths_for_row "$row")

  while true; do
    : > "$CURRENT_LOG_FILE"

    echo "Provider=$PROVIDER Mode=$MODE Overwrite=$OVERWRITE_OUTPUT RelaunchChromeAfterRow=$RELAUNCH_CHROME_AFTER_ROW Macro=$MACRO_NAME"
    echo "Launching $MACRO_NAME for row $current_row (launch attempt ${launch_attempt}/${MAX_LAUNCH_ATTEMPTS})"
    if [[ -n "$expected_output_path" ]]; then
      echo "Expected output path for row $current_row: $expected_output_path"
    else
      echo "Expected output path for row $current_row: <unknown>"
    fi
    echo "Log file: $CURRENT_LOG_FILE"
    echo "Row time limit: ${ROW_TIME_LIMIT}s"
    osascript "$APPLE_SCRIPT"
    sleep 1
    osascript -e \
      "tell application \"Google Chrome\" to open location \
\"$target_url\""
    wait_for_row_result
    wait_status=$?

    if (( wait_status == 4 )); then
      autostart_recovery_count=$((autostart_recovery_count + 1))
      echo "UI.Vision autorun page got stuck for row $current_row; restarting Chrome before retry ${autostart_recovery_count} for the same row." >&2
      stop_uivision_instances
      restart_chrome
      sleep 2
      continue
    fi

    if (( wait_status == 5 )); then
      if (( launch_attempt >= MAX_LAUNCH_ATTEMPTS )); then
        break
      fi
      echo "UI.Vision hit a DOM-ready failure for row $current_row; retrying launch." >&2
      stop_uivision_instances
      launch_attempt=$((launch_attempt + 1))
      sleep 2
      continue
    fi

    break
  done

  if (( wait_status == 5 )) && (( launch_attempt >= MAX_LAUNCH_ATTEMPTS )); then
    echo "Row $current_row exceeded ${MAX_LAUNCH_ATTEMPTS} UI.Vision launch attempts; marking for retry." >&2
    finish_row_browser_cycle
    return 1
  fi

  if (( wait_status == 1 )); then
    echo "Row $current_row did not finish within the allowed watchdog limits; marking for retry." >&2
    finish_row_browser_cycle
    return 1
  fi
  if (( wait_status == 2 )); then
    echo "Row $current_row hit a UI.Vision command error; marking for retry." >&2
    finish_row_browser_cycle
    return 1
  fi

  if grep -q "ROW_CONTROL_READ_FAILED" "$CURRENT_LOG_FILE"; then
    echo "Macro could not read row control CSV: $ROW_CONTROL_CSV" >&2
    exit 1
  fi

  if grep -q "REQUESTED_ROW_NOT_FOUND row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Reached the end of $source_csv at row $current_row"
    stop_uivision_instances
    return 2
  fi

  if grep -q "${UPLOAD_BACKOFF_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro requested upload-capacity backoff on row $current_row; will sleep and retry the same row." >&2
    finish_row_browser_cycle
    return 4
  fi

  if grep -q "${TOO_MANY_REQUESTS_BACKOFF_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro requested too-many-requests backoff on row $current_row; will sleep and retry the same row." >&2
    finish_row_browser_cycle
    return 7
  fi

  if grep -q "${SEND_DISABLED_BACKOFF_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro requested send-disabled backoff on row $current_row; will sleep and retry the same row." >&2
    finish_row_browser_cycle
    return 8
  fi

  if grep -q "${RATE_LIMIT_BACKOFF_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    LAST_RATE_LIMIT_BACKOFF_SECONDS="$(extract_rate_limit_backoff_seconds "$CURRENT_LOG_FILE" "$current_row" || printf '3600')"
    echo "Macro requested image-generation rate-limit backoff on row $current_row for ${LAST_RATE_LIMIT_BACKOFF_SECONDS}s; will sleep and retry the same row." >&2
    finish_row_browser_cycle
    return 6
  fi

  if grep -q "${FAILURE_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro reported a failed run on row $current_row; marking for retry." >&2
    finish_row_browser_cycle
    return 1
  fi

  if ! grep -q 'Macro completed' "$CURRENT_LOG_FILE"; then
    echo "Macro did not complete successfully for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    finish_row_browser_cycle
    return 1
  fi

  if ! grep -q "${SUCCESS_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro finished without the expected success marker for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    finish_row_browser_cycle
    return 1
  fi

  if materialize_guardrail_violation_output_for_row "$current_row" "$CURRENT_LOG_FILE"; then
    echo "Captured guardrail violation response for row $current_row"
  fi

  if ! ensure_output_created_for_row "$current_row"; then
    finish_row_browser_cycle
    return 1
  fi

  echo "Finished row $current_row"
  finish_row_browser_cycle
  return 0
}

declare -a skipped_rows=()
declare -a next_skipped_rows=()
pass_number=1
initial_start_row="$current_row"

while (( pass_number <= MAX_PASSES )); do
  if (( pass_number == 1 )); then
    skipped_rows=()

    if (( has_explicit_row_targets == 1 )); then
      if (( ${#target_rows[@]} == 1 )); then
        echo "Starting targeted pass $pass_number/$MAX_PASSES for row ${target_rows[0]}"
      else
        echo "Starting targeted pass $pass_number/$MAX_PASSES for rows: ${target_rows[*]}"
      fi

      for ((target_index=0; target_index<${#target_rows[@]}; target_index++)); do
        row="${target_rows[target_index]}"
        if (( ${#skipped_rows[@]} > 0 )); then
          if blocking_row="$(find_blocking_failed_dependency_row "$row" "${skipped_rows[@]}")"; then
            echo "Skipping row $row for now because its input references output from unresolved previous failed row $blocking_row"
            skipped_rows+=("$row")
            continue
          fi
        fi
        if run_one_row "$row" "$pass_number"; then
          status=0
        else
          status=$?
        fi

        if (( status == 0 )); then
          if (( target_index + 1 < ${#target_rows[@]} )); then
            wait_before_next_row
          fi
          continue
        fi

        if (( status == 3 )); then
          continue
        fi

        if (( status == 2 )); then
          echo "Row $row is beyond the end of $source_csv; treating it as finished"
          continue
        fi

        if (( status == 4 )); then
          wait_before_upload_backoff_retry "$row"
          target_index=$((target_index - 1))
          continue
        fi

        if (( status == 6 )); then
          wait_before_rate_limit_backoff_retry "$row"
          target_index=$((target_index - 1))
          continue
        fi

        if (( status == 7 )); then
          wait_before_too_many_requests_backoff_retry "$row"
          target_index=$((target_index - 1))
          continue
        fi

        if (( status == 8 )); then
          wait_before_send_disabled_backoff_retry "$row"
          target_index=$((target_index - 1))
          continue
        fi

        skipped_rows+=("$row")
      done
    else
      if (( RUN_ONE_ROW_ONLY == 1 )); then
        echo "Starting single-row pass $pass_number/$MAX_PASSES for row $initial_start_row"
        row="$initial_start_row"
      else
        echo "Starting pass $pass_number/$MAX_PASSES from row $initial_start_row"
        row="$initial_start_row"
      fi

      while true; do
        if (( ${#skipped_rows[@]} > 0 )); then
          if blocking_row="$(find_blocking_failed_dependency_row "$row" "${skipped_rows[@]}")"; then
            echo "Skipping row $row for now because its input references output from unresolved previous failed row $blocking_row"
            skipped_rows+=("$row")
            if (( RUN_ONE_ROW_ONLY == 1 )); then
              break
            fi
            row=$((row + 1))
            continue
          fi
        fi
        if run_one_row "$row" "$pass_number"; then
          status=0
        else
          status=$?
        fi

        if (( status == 0 )); then
          if (( RUN_ONE_ROW_ONLY == 1 )); then
            break
          fi
          wait_before_next_row
          row=$((row + 1))
          continue
        fi

        if (( status == 3 )); then
          if (( RUN_ONE_ROW_ONLY == 1 )); then
            break
          fi
          row=$((row + 1))
          continue
        fi

        if (( status == 2 )); then
          break
        fi

        if (( status == 4 )); then
          wait_before_upload_backoff_retry "$row"
          continue
        fi

        if (( status == 6 )); then
          wait_before_rate_limit_backoff_retry "$row"
          continue
        fi

        if (( status == 7 )); then
          wait_before_too_many_requests_backoff_retry "$row"
          continue
        fi

        if (( status == 8 )); then
          wait_before_send_disabled_backoff_retry "$row"
          continue
        fi

        skipped_rows+=("$row")
        if (( RUN_ONE_ROW_ONLY == 1 )); then
          break
        fi
        row=$((row + 1))
      done
    fi

    if (( ${#skipped_rows[@]} == 0 )); then
      break
    fi
  else
    if (( ${#skipped_rows[@]} == 0 )); then
      break
    fi

    echo "Starting retry pass $pass_number/$MAX_PASSES for skipped rows: ${skipped_rows[*]}"
    next_skipped_rows=()

    for ((skipped_index=0; skipped_index<${#skipped_rows[@]}; skipped_index++)); do
      row="${skipped_rows[skipped_index]}"
      if (( ${#next_skipped_rows[@]} > 0 )); then
        if blocking_row="$(find_blocking_failed_dependency_row "$row" "${next_skipped_rows[@]}")"; then
          echo "Skipping row $row again because its input still references output from unresolved previous failed row $blocking_row"
          next_skipped_rows+=("$row")
          continue
        fi
      fi
      if run_one_row "$row" "$pass_number"; then
        status=0
      else
        status=$?
      fi

      if (( status == 0 )); then
        if (( skipped_index + 1 < ${#skipped_rows[@]} )); then
          wait_before_next_row
        fi
        continue
      fi
      if (( status == 3 )); then
        continue
      fi
      if (( status == 2 )); then
        echo "Row $row is now beyond the end of $source_csv; treating it as finished"
        continue
      fi

      if (( status == 4 )); then
        wait_before_upload_backoff_retry "$row"
        skipped_index=$((skipped_index - 1))
        continue
      fi

      if (( status == 6 )); then
        wait_before_rate_limit_backoff_retry "$row"
        skipped_index=$((skipped_index - 1))
        continue
      fi

      if (( status == 7 )); then
        wait_before_too_many_requests_backoff_retry "$row"
        skipped_index=$((skipped_index - 1))
        continue
      fi

      if (( status == 8 )); then
        wait_before_send_disabled_backoff_retry "$row"
        skipped_index=$((skipped_index - 1))
        continue
      fi

      next_skipped_rows+=("$row")
    done

    if (( ${#next_skipped_rows[@]} == 0 )); then
      skipped_rows=()
    else
      skipped_rows=("${next_skipped_rows[@]}")
    fi

    if (( ${#skipped_rows[@]} == 0 )); then
      break
    fi
  fi

  pass_number=$((pass_number + 1))
done

current_row="1"
printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"

if (( ${#skipped_rows[@]} > 0 )); then
  echo "Loop finished after $MAX_PASSES passes with unresolved skipped rows: ${skipped_rows[*]}" >&2
else
  echo "Loop finished. All targeted rows completed. Next row remains recorded in $ROW_CONTROL_CSV as $current_row"
fi
