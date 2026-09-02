#!/usr/bin/env bash
# 在构建成功后调用，将最新构建成功的 tag 写入 LAST_VERSION
# 参数：$1 = release tag (如 v146)
set -euo pipefail
STATE_FILE="$(dirname "$0")/../LAST_VERSION"
NEW_TAG="${1:-}"
if [ -z "$NEW_TAG" ]; then
  echo "ERR: 请传入要记录的 tag，例如 v146" >&2
  exit 1
fi
mkdir -p "$(dirname "$STATE_FILE")"
echo "$NEW_TAG" > "$STATE_FILE"
echo "已记录 LAST_VERSION = $NEW_TAG" >&2
# 如果在 git 仓库中则自动提交
cd "$(dirname "$0")/.."
if [ -d .git ] && [ -n "$(git status --porcelain LAST_VERSION 2>/dev/null || true)" ]; then
  git add LAST_VERSION
  git -c user.name="ci-bot" -c user.email="ci@local" commit \
    -m "chore(version): bump LAST_VERSION to ${NEW_TAG}" \
    --allow-empty >/dev/null 2>&1 || true
  echo "已自动 commit LAST_VERSION 更新" >&2
fi
