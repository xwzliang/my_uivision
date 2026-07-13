#!/usr/bin/env bash

# The image used by uivision should be putted to the images folder like: ~/Desktop/uivision/images/*.png

set -euo pipefail

export LC_CTYPE="en_US.UTF-8"
export LANG="en_US.UTF-8"

LOG_TIMEOUT=300   # seconds to wait before giving up

### ─── CONFIG ────────────────────────────────────────────────────────────────
# Directory whose subfolders you want to process
WATCH_DIR="/Users/broliang/sync/cat/n8n"

# CSV file to write each folder path into
CSV_FILE="/Users/broliang/uivision/datasources/youtube_video_sources.csv"

# Where you saved the ui.vision.html autorun file
UIV_HTML="/Users/broliang/uivision/ui.vision.html"

# The exact macro name (as shown in your UI.Vision sidebar)
MACRO_NAME="upload_youtube_in_local_drive"

# Temp log file where UI.Vision will write its run status
LOG_FILE="/Users/broliang/uivision/uivision.log"

# Path to your Chrome (adjust if you use Chromium or a custom path)
# CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Parent of WATCH_DIR — this is where folders get moved on success
DEST_DIR="$(dirname "$WATCH_DIR")"
### ───────────────────────────────────────────────────────────────────────────

# 1) Start with a fresh CSV
> "$CSV_FILE"
> "$LOG_FILE"

# 2) Loop over each subfolder of WATCH_DIR
for folder in "$WATCH_DIR"/*; do
  # skip if not a directory
  [[ -d "$folder" ]] || continue

  echo "Processing: $folder"

  # 2 Inserts $folder as a new first line in $CSV_FILE
    # Create a temp file
    tmp="$(mktemp)"

    # Write the new line first, then the existing contents
    printf '%s\n' "$folder"  > "$tmp"
    cat           "$CSV_FILE" >> "$tmp"

    # Overwrite the original
    mv "$tmp" "$CSV_FILE"

  # 3) Invoke UI.Vision via Chrome
  #    – direct=1: run immediately
  #    – macro=MACRO_NAME: which macro to run
  #    – closeBrowser=1 & closeRPA=1: auto-quit when done
  #    – savelog=LOG_FILE: write a JSON log of the run
#   "$CHROME_BIN" \
#     "file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeBrowser=1&closeRPA=1&savelog=$LOG_FILE"
  cat "$folder"/title.txt | pbcopy
  osascript -e \
    "tell application \"Google Chrome\" to open location \
\"file://$UIV_HTML?direct=1&macro=$MACRO_NAME&closeRPA=1&savelog=$LOG_FILE\""

##############################################
# 4. WAIT until the log is no longer empty
##############################################
elapsed=0
while [[ ! -s "$LOG_FILE" ]]; do      # -s  ⇒  file size > 0 ?
  (( elapsed++ ))
  if (( elapsed > LOG_TIMEOUT )); then
    echo "Error: UI.Vision log stayed empty for ${LOG_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 1
done
echo "Log detected after $elapsed s → continuing…"

  # 5) Inspect the log for success
  #    UI.Vision log will contain something like "status":"OK"
  if grep -q 'Macro completed' "$LOG_FILE"; then
    echo "  → Macro succeeded; moving folder up one level."
    mv "$folder" "$DEST_DIR"
  else
    echo "  → Macro failed! See $LOG_FILE"
    exit 1
  fi

  echo
done

echo "All done."
# cat /Users/broliang/sync/cat/2025-07-08_cat_120/title.txt | pbcopy
# osascript -e 'tell application "Google Chrome" to open location "file:///Users/broliang/uivision/ui.vision.html?direct=1&macro=upload_youtube_in_local_drive&closeRPA=1&savelog=/Users/broliang/uivision/uivision.log"'
