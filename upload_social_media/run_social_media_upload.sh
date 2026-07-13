#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIVISION_ROOT="${UIVISION_ROOT:-$HOME/Desktop/uivision}"
UIVISION_MACROS_DIR="${UIVISION_MACROS_DIR:-$UIVISION_ROOT/macros}"

install_macro() {
  local source_file="$1"
  local macro_name="$2"
  local destination="$UIVISION_MACROS_DIR/$macro_name.json"

  [[ -f "$source_file" ]] || {
    echo "Macro source file is missing: $source_file" >&2
    exit 1
  }

  mkdir -p "$UIVISION_MACROS_DIR"
  if [[ ! -f "$destination" ]] || ! cmp -s "$source_file" "$destination"; then
    cp "$source_file" "$destination"
    echo "Installed UI.Vision macro: $destination"
  fi
}

usage() {
  cat >&2 <<'EOF'
Usage: run_social_media_upload.sh <platform> [start_row] [end_row]

Platforms:
  douyin
  bilibili
  xiaohongshu (alias: xhs)
  kuaishou     (alias: ks)
  shipinhao    (aliases: wechat, weixin, channels)
  baijiahao    (alias: bjh)
  tiktok
  youtube

Examples:
  ./upload_social_media/run_social_media_upload.sh douyin
  ./upload_social_media/run_social_media_upload.sh xhs 3 8
  SOURCE_CSV=/path/to/queue.csv ./upload_social_media/run_social_media_upload.sh kuaishou 1 5

The first seven platforms use CSV row ranges. The existing YouTube runner keeps
its directory-watching behavior and does not accept row arguments.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

platform="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
shift

case "$platform" in
  douyin|dy)
    runner="$SCRIPT_DIR/upload_douyin/run_douyin_upload_loop.sh"
    macro_name="DouyinUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_douyin/upload_douyin_single_row.json"
    ;;
  bilibili|bili|b站)
    runner="$SCRIPT_DIR/upload_bilibili/run_bilibili_upload_loop.sh"
    macro_name="BilibiliUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_bilibili/upload_bilibili_single_row.json"
    ;;
  xiaohongshu|xhs|小红书)
    runner="$SCRIPT_DIR/upload_xiaohongshu/run_xiaohongshu_upload_loop.sh"
    macro_name="XiaohongshuUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_xiaohongshu/upload_xiaohongshu_single_row.json"
    ;;
  kuaishou|ks|快手)
    runner="$SCRIPT_DIR/upload_kuaishou/run_kuaishou_upload_loop.sh"
    macro_name="KuaishouUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_kuaishou/upload_kuaishou_single_row.json"
    ;;
  shipinhao|wechat|weixin|channels|视频号)
    runner="$SCRIPT_DIR/upload_shipinhao/run_shipinhao_upload_loop.sh"
    macro_name="ShipinhaoUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_shipinhao/upload_shipinhao_single_row.json"
    ;;
  baijiahao|bjh|百家号)
    runner="$SCRIPT_DIR/upload_baijiahao/run_baijiahao_upload_loop.sh"
    macro_name="BaijiahaoUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_baijiahao/upload_baijiahao_single_row.json"
    ;;
  tiktok|tik-tok)
    runner="$SCRIPT_DIR/upload_tiktok/run_tiktok_upload_loop.sh"
    macro_name="TiktokUploadVideoSingleRow"
    macro_file="$SCRIPT_DIR/upload_tiktok/upload_tiktok_single_row.json"
    ;;
  youtube|yt)
    (( $# == 0 )) || {
      echo "The existing YouTube runner does not accept row arguments." >&2
      usage
    }
    runner="$SCRIPT_DIR/upload_youtube/upload_youtube.sh"
    macro_name="upload_youtube_in_local_drive"
    macro_file="$SCRIPT_DIR/upload_youtube/upload_youtube_in_local_drive.json"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    usage
    ;;
esac

[[ -x "$runner" ]] || {
  echo "Platform runner is missing or not executable: $runner" >&2
  exit 1
}

install_macro "$macro_file" "$macro_name"

exec "$runner" "$@"
