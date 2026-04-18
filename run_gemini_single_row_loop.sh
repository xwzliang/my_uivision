#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-image}"
ROW_ARG="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"

BASE_CSV="${BASE_CSV:-/Users/broliang/Pictures/short_drama/ui_vision.csv}"
ROW_CONTROL_CSV="${ROW_CONTROL_CSV:-/Users/broliang/Pictures/short_drama/ui_vision_row_control.csv}"

# Generate the File: Open the UI.Vision RPA extension, go to Settings > API tab, and click "Create autorun HTML"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_FILE="${LOG_FILE:-/Users/broliang/uivision/uivision.log}"
APPLE_SCRIPT="${APPLE_SCRIPT:-$SCRIPT_DIR/launch_uivision_macro.scpt}"
LOG_TIMEOUT="${LOG_TIMEOUT:-1200}"
MAX_PASSES="${MAX_PASSES:-5}"
RUN_ONE_ROW_ONLY="${RUN_ONE_ROW_ONLY:-0}"

usage() {
  echo "Usage: $0 [image|storyboard|sora] [start_row] [all|single]" >&2
  echo "       $0 [image|storyboard|sora] [start_row] [end_row] [all|single]" >&2
  echo "       $0 [image|storyboard|sora] [row1,row2,row3] [all|single]" >&2
  echo "       $0 [image|storyboard|sora] [start-end] [all|single]" >&2
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
has_explicit_row_targets=0
RUN_MODE=""

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
    RUN_MODE="$ARG3"
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
    RUN_MODE="$ARG3"
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
      RUN_MODE="$ARG4"
    else
      current_row="$ROW_ARG"
      RUN_MODE="$ARG3"
    fi
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

if [[ -n "$RUN_MODE" ]]; then
  case "$RUN_MODE" in
    single|once|one|true|1)
      RUN_ONE_ROW_ONLY=1
      ;;
    all|false|0)
      RUN_ONE_ROW_ONLY=0
      ;;
    *)
      usage
      ;;
  esac
fi

if [[ ! "$RUN_ONE_ROW_ONLY" =~ ^[01]$ ]]; then
  echo "Invalid RUN_ONE_ROW_ONLY '$RUN_ONE_ROW_ONLY'; defaulting to 0" >&2
  RUN_ONE_ROW_ONLY=0
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

wait_for_log() {
  local elapsed=0

  while [[ ! -s "$CURRENT_LOG_FILE" ]]; do
    elapsed=$((elapsed + 1))
    if (( elapsed > LOG_TIMEOUT )); then
      echo "UI.Vision log stayed empty for more than ${LOG_TIMEOUT}s" >&2
      return 1
    fi
    sleep 1
  done

  return 0
}

run_one_row() {
  local row="$1"
  local pass="$2"

  current_row="$row"
  CURRENT_LOG_FILE="$(build_log_file_path "$row" "$pass")"
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
  : > "$CURRENT_LOG_FILE"

  target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$CURRENT_LOG_FILE"

  echo "Launching $MACRO_NAME for row $current_row"
  echo "Log file: $CURRENT_LOG_FILE"
  osascript "$APPLE_SCRIPT"
  sleep 1
  osascript -e \
    "tell application \"Google Chrome\" to open location \
\"$target_url\""
  if ! wait_for_log; then
    echo "Row $current_row produced no UI.Vision log output; marking for retry." >&2
    return 1
  fi

  if grep -q "ROW_CONTROL_READ_FAILED" "$CURRENT_LOG_FILE"; then
    echo "Macro could not read row control CSV: $ROW_CONTROL_CSV" >&2
    exit 1
  fi

  if grep -q "REQUESTED_ROW_NOT_FOUND row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Reached the end of $source_csv at row $current_row"
    return 2
  fi

  if grep -q "${FAILURE_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro reported a failed run on row $current_row; marking for retry." >&2
    return 1
  fi

  if ! grep -q 'Macro completed' "$CURRENT_LOG_FILE"; then
    echo "Macro did not complete successfully for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    return 1
  fi

  if ! grep -q "${SUCCESS_MARKER} row=${current_row}" "$CURRENT_LOG_FILE"; then
    echo "Macro finished without the expected success marker for row $current_row; marking for retry. See $CURRENT_LOG_FILE" >&2
    return 1
  fi

  echo "Finished row $current_row"
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

      for row in "${target_rows[@]}"; do
        if run_one_row "$row" "$pass_number"; then
          status=0
        else
          status=$?
        fi

        if (( status == 0 )); then
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

    for row in "${skipped_rows[@]}"; do
      if run_one_row "$row" "$pass_number"; then
        status=0
      else
        status=$?
      fi

      if (( status == 0 )); then
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
