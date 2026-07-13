#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM=baijiahao MACRO_NAME=BaijiahaoUploadVideoSingleRow SOURCE_CSV="${SOURCE_CSV:-$SCRIPT_DIR/baijiahao_uploads.csv}" exec "$SCRIPT_DIR/../upload_common/run_platform_upload_loop.sh" "$@"
