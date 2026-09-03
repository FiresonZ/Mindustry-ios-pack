#!/usr/bin/env bash
# 功能：将成功构建的 tag 写入 LAST_VERSION 状态文件。
# 参数：$1 = release tag (如 v146)
# 注意：本脚本仅更新文件，不提交 Git；由 CI 后续统一提交。
set -euo pipefail

STATE_FILE="$(dirname "$0")/../LAST_VERSION"
NEW_TAG="${1:-}"

if [ -z "$NEW_TAG" ]; then
  echo "ERR: 请传入要记录的 tag，例如 v146" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

# 写入状态文件（首行为注释，check-version.sh 会自动跳过）
cat > "$STATE_FILE" <<EOF
# 上次成功构建的 tag（由 bump-last-version.sh 更新）
${NEW_TAG}
EOF

echo "LAST_VERSION updated to ${NEW_TAG}" >&2
