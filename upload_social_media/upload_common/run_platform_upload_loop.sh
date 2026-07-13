#!/usr/bin/env bash

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

PLATFORM="${PLATFORM:?Set PLATFORM before running this helper}"
MACRO_NAME="${MACRO_NAME:?Set MACRO_NAME before running this helper}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CSV="${SOURCE_CSV:?Set SOURCE_CSV to the upload queue CSV}"
CURRENT_CSV="/Users/broliang/uivision/datasources/${PLATFORM}_upload_current.csv"
UIV_HTML="${UIV_HTML:-/Users/broliang/uivision/ui.vision.html}"
LOG_DIR="${LOG_DIR:-/Users/broliang/uivision/logs/$PLATFORM}"
LOG_TIMEOUT="${LOG_TIMEOUT:-1200}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
START_ROW="${1:-1}"
END_ROW="${2:-}"

[[ "$START_ROW" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid start row" >&2; exit 2; }
[[ -z "$END_ROW" || "$END_ROW" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid end row" >&2; exit 2; }
[[ -f "$SOURCE_CSV" ]] || { echo "Missing source CSV: $SOURCE_CSV" >&2; exit 1; }
[[ -f "$UIV_HTML" ]] || { echo "Missing UI.Vision autorun HTML: $UIV_HTML" >&2; exit 1; }

total_rows="$(python3 - "$SOURCE_CSV" <<'PY'
import csv, sys
with open(sys.argv[1], newline="", encoding="utf-8-sig") as f:
    print(sum(1 for row in csv.reader(f) if row and any(cell.strip() for cell in row)))
PY
)"
[[ -n "$END_ROW" ]] || END_ROW="$total_rows"
(( START_ROW <= END_ROW && END_ROW <= total_rows )) || { echo "Requested row range is outside 1..$total_rows" >&2; exit 2; }
mkdir -p "$(dirname "$CURRENT_CSV")" "$LOG_DIR"

prepare_row() {
  python3 - "$SOURCE_CSV" "$CURRENT_CSV" "$1" "$PLATFORM" <<'PY'
import csv, os, re, sys, tempfile
source, target, requested, platform = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(source, newline="", encoding="utf-8-sig") as f:
    rows = [r for r in csv.reader(f) if r and any(c.strip() for c in r)]
row = (rows[requested - 1] + [""] * 7)[:7]
video, title, description, tags, publish_at, category, cover = (c.strip() for c in row)
if not video or not title: raise SystemExit(f"row {requested}: video_path and title are required")
if not os.path.isfile(video): raise SystemExit(f"row {requested}: video does not exist: {video}")
# Shared social_media_uploads.csv files use six columns, with cover_path in
# column 6. The extended seven-column schema reserves column 6 for category and
# puts cover_path in column 7. Platforms other than Bilibili do not consume the
# category field in these macros, so normalize either source layout here.
if platform != "bilibili" and category and not cover:
    cover, category = category, ""
if cover and not os.path.isfile(cover): raise SystemExit(f"row {requested}: cover does not exist: {cover}")
limits = {"xiaohongshu": 20, "bilibili": 80, "kuaishou": 50, "shipinhao": 30, "baijiahao": 30, "tiktok": 150}
title = title[:limits.get(platform, 30)]
tag_items = [x.strip().lstrip("#") for x in re.split(r"[,#\s]+", tags) if x.strip().lstrip("#")]
if platform == "xiaohongshu":
    tag_items = tag_items[:10]
elif platform != "shipinhao":
    tag_items = tag_items[:20]
caption_parts = [title, description] if platform in ("kuaishou", "shipinhao") else [description]
caption_base = " ".join(part for part in caption_parts if part)
caption = caption_base + ((" " if caption_base else "") + " ".join("#" + x for x in tag_items) if tag_items else "")
if platform == "kuaishou":
    # Kuaishou accepts at most four hashtags in the description. Count tags
    # already embedded in the title/description before considering appended
    # CSV tags, and remove every hashtag after the first four.
    hashtag_count = 0
    def keep_first_four_hashtags(match):
        global hashtag_count
        hashtag_count += 1
        return match.group(0) if hashtag_count <= 4 else ""
    caption = re.sub(r"#[^\s#，,。！？!?:：;；]+", keep_first_four_hashtags, caption)
    caption = re.sub(r"[ \t]{2,}", " ", caption).strip()
directory = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(prefix=platform + "_upload_", suffix=".csv", dir=directory)
try:
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        publish_mode = "scheduled" if publish_at else "immediate"
        csv.writer(f).writerow([video, title, caption, publish_at, category, cover, publish_mode])
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

wait_for_result() {
  local log_file="$1" elapsed=0 marker
  marker="$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]')_UPLOAD_"
  while (( elapsed < LOG_TIMEOUT )); do
    if [[ -s "$log_file" ]]; then
      grep -Eq "${marker}(DRY_RUN_)?COMPLETED" "$log_file" && return 0
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
    echo "Preparing $PLATFORM row $row/$END_ROW (attempt $attempt/$MAX_ATTEMPTS)"
    target_url="file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$log_file"
    osascript -e "tell application \"Google Chrome\" to open location \"$target_url\""
    if wait_for_result "$log_file"; then
      success=1
      marker="$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]')_UPLOAD_DRY_RUN_COMPLETED"
      if grep -q "$marker" "$log_file"; then
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

echo "All requested $PLATFORM rows completed."
