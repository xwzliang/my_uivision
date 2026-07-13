#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM=bilibili MACRO_NAME=BilibiliUploadVideoSingleRow SOURCE_CSV="${SOURCE_CSV:-$SCRIPT_DIR/bilibili_uploads.csv}" exec "$SCRIPT_DIR/../upload_common/run_platform_upload_loop.sh" "$@"
