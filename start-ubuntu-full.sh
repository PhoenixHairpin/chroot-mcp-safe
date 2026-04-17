#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/chroot-mcp-safe.sh"

if [ ! -x "$TARGET_SCRIPT" ]; then
  echo "错误: 未找到可执行脚本 $TARGET_SCRIPT" >&2
  echo "请先执行: chmod +x \"$TARGET_SCRIPT\"" >&2
  exit 1
fi

exec "$TARGET_SCRIPT" "$@"
