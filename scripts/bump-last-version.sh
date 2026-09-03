#!/usr/bin/env bash
# 在构建成功后调用，将最新构建成功的 tag 写入 LAST_VERSION
# 参数：$1 = release tag (如 v146)
# 注意：本脚本**仅写入文件，不做 git commit/push**。
#       git commit & push 由 CI workflow 中 "Commit LAST_VERSION back to repo" 步骤统一执行，
#       避免「此处先 commit → workflow 检测 porcelain 为空 → 跳过 push」的重复 commit bug。
set -euo pipefail
STATE_FILE="$(dirname "$0")/../LAST_VERSION"
NEW_TAG="${1:-}"
if [ -z "$NEW_TAG" ]; then
  echo "ERR: 请传入要记录的 tag，例如 v146" >&2
  exit 1
fi
mkdir -p "$(dirname "$STATE_FILE")"

# 写 LAST_VERSION：保留/写入一行说明注释（check-version.sh 会自动跳过 # 行），
# 第二行起是实际 tag 值。这样人工读文件也清晰。
cat > "$STATE_FILE" <<EOF
# 上次成功构建的 Mindustry upstream tag。由 scripts/bump-last-version.sh 在 CI 构建成功后更新。
# 格式：单独一行 v<BUILD_VERSION>。check-version.sh 读取时跳过 # 注释行。
${NEW_TAG}
EOF
echo "已记录 LAST_VERSION = ${NEW_TAG}" >&2
