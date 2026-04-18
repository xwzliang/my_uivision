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

usage() {
  echo "Usage: $0 [image|storyboard] [start_row]" >&2
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

wait_for_log() {
  local elapsed=0

  while [[ ! -s "$LOG_FILE" ]]; do
    elapsed=$((elapsed + 1))
    if (( elapsed > LOG_TIMEOUT )); then
      echo "UI.Vision log stayed empty for more than ${LOG_TIMEOUT}s" >&2
      exit 1
    fi
    sleep 1
  done
}

advance_to_next_row() {
  current_row=$((current_row + 1))
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
}

while true; do
  printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
  : > "$LOG_FILE"

  target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$LOG_FILE"

  echo "Launching $MACRO_NAME for row $current_row"
  osascript "$APPLE_SCRIPT"
  sleep 1
  osascript -e \
    "tell application \"Google Chrome\" to open location \
\"$target_url\""
  wait_for_log

  if grep -q "ROW_CONTROL_READ_FAILED" "$LOG_FILE"; then
    echo "Macro could not read row control CSV: $ROW_CONTROL_CSV" >&2
    exit 1
  fi

  if grep -q "REQUESTED_ROW_NOT_FOUND row=${current_row}" "$LOG_FILE"; then
    echo "Reached the end of $source_csv at row $current_row"
    current_row="1"
    printf '%s\n' "$current_row" > "$ROW_CONTROL_CSV"
    break
  fi

  if grep -q "${FAILURE_MARKER} row=${current_row}" "$LOG_FILE"; then
    echo "Macro reported a failed run on row $current_row; skipping to next row." >&2
    advance_to_next_row
    continue
  fi

  if ! grep -q 'Macro completed' "$LOG_FILE"; then
    echo "Macro did not complete successfully for row $current_row; skipping to next row. See $LOG_FILE" >&2
    advance_to_next_row
    continue
  fi

  if ! grep -q "${SUCCESS_MARKER} row=${current_row}" "$LOG_FILE"; then
    echo "Macro finished without the expected success marker for row $current_row; skipping to next row. See $LOG_FILE" >&2
    advance_to_next_row
    continue
  fi

  echo "Finished row $current_row"
  advance_to_next_row
done

echo "Loop finished. Next row remains recorded in $ROW_CONTROL_CSV as $current_row"
