#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-image}"
START_ROW="${2:-}"

BASE_CSV="${BASE_CSV:-/Users/broliang/Pictures/short_drama/ui_vision.csv}"
ROW_CONTROL_CSV="${ROW_CONTROL_CSV:-/Users/broliang/Pictures/short_drama/ui_vision_row_control.csv}"

# Generate the File: Open the UI.Vision RPA extension, go to Settings > API tab, and click "Create autorun HTML"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_FILE="${LOG_FILE:-/Users/broliang/uivision/uivision.log}"
APPLE_SCRIPT="${APPLE_SCRIPT:-$SCRIPT_DIR/launch_uivision_macro.scpt}"
LOG_TIMEOUT="${LOG_TIMEOUT:-1200}"
MAX_PASSES="${MAX_PASSES:-5}"

usage() {
  echo "Usage: $0 [image|storyboard|sora] [start_row]" >&2
  exit 2
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

if [[ -n "$START_ROW" ]]; then
  current_row="$START_ROW"
elif [[ -f "$ROW_CONTROL_CSV" ]]; then
  current_row="$(tr -d '\r\n' < "$ROW_CONTROL_CSV")"
else
  current_row="1"
fi

if [[ ! "$current_row" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid start row '$current_row'; defaulting to 1" >&2
  current_row="1"
fi

if [[ ! "$MAX_PASSES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid MAX_PASSES '$MAX_PASSES'; defaulting to 5" >&2
  MAX_PASSES="5"
fi

wait_for_log() {
  local elapsed=0

  while [[ ! -s "$LOG_FILE" ]]; do
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

  current_row="$row"
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
  : > "$LOG_FILE"

  target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$LOG_FILE"

  echo "Launching $MACRO_NAME for row $current_row"
  osascript "$APPLE_SCRIPT"
  sleep 1
  osascript -e \
    "tell application \"Google Chrome\" to open location \
\"$target_url\""
  if ! wait_for_log; then
    echo "Row $current_row produced no UI.Vision log output; marking for retry." >&2
    return 1
  fi

  if grep -q "ROW_CONTROL_READ_FAILED" "$LOG_FILE"; then
    echo "Macro could not read row control CSV: $ROW_CONTROL_CSV" >&2
    exit 1
  fi

  if grep -q "REQUESTED_ROW_NOT_FOUND row=${current_row}" "$LOG_FILE"; then
    echo "Reached the end of $source_csv at row $current_row"
    return 2
  fi

  if grep -q "${FAILURE_MARKER} row=${current_row}" "$LOG_FILE"; then
    echo "Macro reported a failed run on row $current_row; marking for retry." >&2
    return 1
  fi

  if ! grep -q 'Macro completed' "$LOG_FILE"; then
    echo "Macro did not complete successfully for row $current_row; marking for retry. See $LOG_FILE" >&2
    return 1
  fi

  if ! grep -q "${SUCCESS_MARKER} row=${current_row}" "$LOG_FILE"; then
    echo "Macro finished without the expected success marker for row $current_row; marking for retry. See $LOG_FILE" >&2
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
    echo "Starting pass $pass_number/$MAX_PASSES from row $initial_start_row"
    row="$initial_start_row"
    skipped_rows=()

    while true; do
      if run_one_row "$row"; then
        status=0
      else
        status=$?
      fi

      if (( status == 0 )); then
        row=$((row + 1))
        continue
      fi

      if (( status == 2 )); then
        break
      fi

      skipped_rows+=("$row")
      row=$((row + 1))
    done

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
      if run_one_row "$row"; then
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
