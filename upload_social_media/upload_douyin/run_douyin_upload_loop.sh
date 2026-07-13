#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CSV="${SOURCE_CSV:-$SCRIPT_DIR/douyin_uploads.csv}"
CURRENT_CSV="/Users/broliang/uivision/datasources/douyin_upload_current.csv"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_DIR="${LOG_DIR:-/Users/broliang/uivision/logs/douyin}"
MACRO_NAME="${MACRO_NAME:-DouyinUploadVideoSingleRow}"
LOG_TIMEOUT="${LOG_TIMEOUT:-1200}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
START_ROW="${1:-1}"
END_ROW="${2:-}"

usage() {
  echo "Usage: SOURCE_CSV=/path/to/uploads.csv $0 [start_row] [end_row]" >&2
  echo "CSV columns: video_path,title,description,tags,publish_at,cover_path" >&2
  echo "tags may be separated by commas, spaces, or #; publish_at is empty or YYYY-MM-DD HH:MM" >&2
  exit 2
}

[[ "$START_ROW" =~ ^[1-9][0-9]*$ ]] || usage
[[ -z "$END_ROW" || "$END_ROW" =~ ^[1-9][0-9]*$ ]] || usage
[[ -f "$SOURCE_CSV" ]] || { echo "Missing source CSV: $SOURCE_CSV" >&2; exit 1; }
[[ -f "$UIV_HTML" ]] || { echo "Missing UI.Vision autorun HTML: $UIV_HTML" >&2; exit 1; }
(( MAX_ATTEMPTS > 0 )) || { echo "MAX_ATTEMPTS must be positive" >&2; exit 2; }

total_rows="$(python3 - "$SOURCE_CSV" <<'PY'
import csv, sys
with open(sys.argv[1], newline="", encoding="utf-8-sig") as f:
    print(sum(1 for row in csv.reader(f) if row and any(cell.strip() for cell in row)))
PY
)"
[[ -n "$END_ROW" ]] || END_ROW="$total_rows"
(( START_ROW <= END_ROW && END_ROW <= total_rows )) || usage

mkdir -p "$(dirname "$CURRENT_CSV")" "$LOG_DIR"

prepare_row() {
  local row="$1"
  python3 - "$SOURCE_CSV" "$CURRENT_CSV" "$row" <<'PY'
import csv, os, re, sys, tempfile

source, target, requested = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(source, newline="", encoding="utf-8-sig") as f:
    rows = [r for r in csv.reader(f) if r and any(c.strip() for c in r)]
row = (rows[requested - 1] + [""] * 6)[:6]
video, title, description, tags, publish_at, cover = (cell.strip() for cell in row)
if not video or not title:
    raise SystemExit(f"row {requested}: video_path and title are required")
if not os.path.isfile(video):
    raise SystemExit(f"row {requested}: video does not exist: {video}")
if cover and not os.path.isfile(cover):
    raise SystemExit(f"row {requested}: cover does not exist: {cover}")
title = title[:30]
tag_items = [x.strip().lstrip("#") for x in re.split(r"[,#\s]+", tags) if x.strip().lstrip("#")]
caption = description.strip()
if tag_items:
    caption = (caption + " " if caption else "") + " ".join("#" + x for x in tag_items) + " "
directory = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(prefix="douyin_upload_", suffix=".csv", dir=directory)
try:
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        publish_mode = "scheduled" if publish_at else "immediate"
        csv.writer(f).writerow([video, title, caption, publish_at, cover, publish_mode])
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

wait_for_result() {
  local log_file="$1" elapsed=0
  while (( elapsed < LOG_TIMEOUT )); do
    if [[ -s "$log_file" ]]; then
      grep -Eq 'DOUYIN_UPLOAD_(DRY_RUN_)?COMPLETED' "$log_file" && return 0
      grep -q 'Macro failed' "$log_file" && return 1
      grep -q '^\[error\]' "$log_file" && return 1
    fi
    sleep 1
    ((elapsed += 1))
  done
  echo "Timed out after ${LOG_TIMEOUT}s waiting for UI.Vision" >&2
  return 1
}

for ((row=START_ROW; row<=END_ROW; row++)); do
  prepare_row "$row"
  success=0
  for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    log_file="$LOG_DIR/row_${row}_attempt_${attempt}.log"
    : > "$log_file"
    echo "Uploading row $row/$END_ROW (attempt $attempt/$MAX_ATTEMPTS)"
    encoded_macro="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MACRO_NAME")"
    encoded_log="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$log_file")"
    autorun_url="file://$UIV_HTML?direct=1&macro=$encoded_macro&closeRPA=1&savelog=$encoded_log"
    osascript -e "tell application \"Google Chrome\" to open location \"$autorun_url\""
    if wait_for_result "$log_file"; then
      success=1
      if grep -q 'DOUYIN_UPLOAD_DRY_RUN_COMPLETED' "$log_file"; then
        echo "Row $row dry run completed; publish click was skipped"
      else
        echo "Row $row published successfully"
      fi
      break
    fi
    echo "Row $row attempt $attempt failed; log: $log_file" >&2
    sleep 5
  done
  (( success == 1 )) || { echo "Giving up on row $row after $MAX_ATTEMPTS attempts" >&2; exit 1; }
done

echo "All requested Douyin uploads completed."
