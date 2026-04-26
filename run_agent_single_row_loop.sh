#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-image}"
ROW_ARG="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"
ARG5="${5:-}"

BASE_CSV="${BASE_CSV:-/Users/broliang/Pictures/short_drama/ui_vision.csv}"
ROW_CONTROL_CSV="${ROW_CONTROL_CSV:-/Users/broliang/Pictures/short_drama/ui_vision_row_control.csv}"

# Generate the File: Open the UI.Vision RPA extension, go to Settings > API tab, and click "Create autorun HTML"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_FILE="${LOG_FILE:-/Users/broliang/uivision/uivision.log}"
APPLE_SCRIPT="${APPLE_SCRIPT:-$SCRIPT_DIR/launch_uivision_macro.scpt}"
LOG_TIMEOUT="${LOG_TIMEOUT:-1200}"
ROW_TIME_LIMIT="${ROW_TIME_LIMIT:-1200}"
FAIL_SETTLE_TIME="${FAIL_SETTLE_TIME:-8}"
MAX_PASSES="${MAX_PASSES:-5}"
RUN_ONE_ROW_ONLY="${RUN_ONE_ROW_ONLY:-0}"
OVERWRITE_OUTPUT="${OVERWRITE_OUTPUT:-0}"

usage() {
  echo "Usage: $0 [image|storyboard|sora|chat|camera] [start_row] [all|single] [overwrite]" >&2
  echo "       $0 [image|storyboard|sora|chat|camera] [start_row] [end_row] [all|single] [overwrite]" >&2
  echo "       $0 [image|storyboard|sora|chat|camera] [row1,row2,row3] [all|single] [overwrite]" >&2
  echo "       $0 [image|storyboard|sora|chat|camera] [start-end] [all|single] [overwrite]" >&2
  exit 2
}

is_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

case "$MODE" in
  image)
    MACRO_NAME="GeminiImageSingleRow"
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
    SUCCESS_MARKER="SORA_PROCESS_COMPLETED"
    FAILURE_MARKER="SORA_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="segments_prompts/video_prompts.csv"
    ;;
  chat)
    MACRO_NAME="GeminiChatSingleRow"
    SUCCESS_MARKER="CHAT_PROCESS_COMPLETED"
    FAILURE_MARKER="CHAT_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="chat_prompts.csv"
    ;;
  camera)
    MACRO_NAME="GeminiCameraSingleRow"
    SUCCESS_MARKER="CAMERA_PROCESS_COMPLETED"
    FAILURE_MARKER="CAMERA_PROCESS_FAILED"
    SOURCE_RELATIVE_CSV="camera_prompts.csv"
    ;;
  *)
    usage
    ;;
esac

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
  echo "Invalid ROW_TIME_LIMIT '$ROW_TIME_LIMIT'; defaulting to 1200" >&2
  ROW_TIME_LIMIT="1200"
fi

if [[ ! "$FAIL_SETTLE_TIME" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid FAIL_SETTLE_TIME '$FAIL_SETTLE_TIME'; defaulting to 8" >&2
  FAIL_SETTLE_TIME="8"
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

if (( has_explicit_row_targets == 1 )) && (( RUN_ONE_ROW_ONLY == 1 )); then
  target_rows=("${target_rows[0]}")
fi

build_log_file_path() {
  local row="$1"
  local pass="$2"
  printf '%s/%s_%s_row_%s_pass_%s%s' \
    "$LOG_DIR" "$LOG_STEM" "$MODE" "$row" "$pass" "$LOG_EXT"
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

wait_for_row_result() {
  local started_at
  local now
  local elapsed=0
  local last_reported_minute=-1
  local last_log_size=-1
  local current_log_size=0
  local last_log_activity_at
  local log_idle_seconds=0

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
                if len(cols) >= 3 and cols[2]:
                    outputs.append(cols[2])
            elif mode == "storyboard":
                if len(cols) >= 2 and cols[1]:
                    outputs.append(os.path.join(base_dir, "segments_prompts", cols[1], "output", "storyboard.png"))
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

find_existing_output_for_row() {
  local row="$1"
  local output_path

  while IFS= read -r output_path; do
    [[ -z "$output_path" ]] && continue
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

wait_before_next_row() {
  echo "Waiting 5 seconds before starting the next row"
  sleep 5
}

run_one_row() {
  local row="$1"
  local pass="$2"
  local existing_output_path

  current_row="$row"

  if (( OVERWRITE_OUTPUT == 0 )); then
    if existing_output_path="$(find_existing_output_for_row "$row")"; then
      echo "Skipping row $current_row because output already exists and overwrite is disabled: $existing_output_path"
      return 3
    fi
  fi

  stop_uivision_instances

  CURRENT_LOG_FILE="$(build_log_file_path "$row" "$pass")"
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
  : > "$CURRENT_LOG_FILE"

  target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$CURRENT_LOG_FILE"

  echo "Launching $MACRO_NAME for row $current_row"
  echo "Log file: $CURRENT_LOG_FILE"
  echo "Row time limit: ${ROW_TIME_LIMIT}s"
  osascript "$APPLE_SCRIPT"
  sleep 1
  osascript -e \
    "tell application \"Google Chrome\" to open location \
\"$target_url\""
  wait_for_row_result
  wait_status=$?
  if (( wait_status == 1 )); then
    echo "Row $current_row did not finish within the allowed watchdog limits; marking for retry." >&2
    stop_uivision_instances
    return 1
  fi
  if (( wait_status == 2 )); then
    echo "Row $current_row hit a UI.Vision command error; marking for retry." >&2
    stop_uivision_instances
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

  if grep -q "${FAILURE_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro reported a failed run on row $current_row; marking for retry." >&2
    stop_uivision_instances
    return 1
  fi

  if ! grep -q 'Macro completed' "$CURRENT_LOG_FILE"; then
    echo "Macro did not complete successfully for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    stop_uivision_instances
    return 1
  fi

  if ! grep -q "${SUCCESS_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro finished without the expected success marker for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    stop_uivision_instances
    return 1
  fi

  echo "Finished row $current_row"
  stop_uivision_instances
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

      next_skipped_rows+=("$row")
    done

    skipped_rows=("${next_skipped_rows[@]}")

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
