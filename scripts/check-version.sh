#!/usr/bin/env bash
# ---------------------------------------------------------------
# Mindustry iOS Packager - Version Check Script
# ---------------------------------------------------------------
# 功能：
#   1. 从 Anuken/Mindustry GitHub Releases 获取最新版 tag
#   2. 提取纯数字构建版本号（如 v146 -> 146）
#   3. 与上次记录的版本比较，判断是否存在更新
#   4. 可选：通过 iTunes Lookup API 对比 App Store 版本
#
# 输出（stdout）：
#   NEEDS_BUILD=true|false
#   RELEASE_TAG=v146
#   BUILD_VERSION=146
#   APP_STORE_VERSION=8.146.0  (如果检测到)
#
# 状态文件： LAST_VERSION (记录上次构建的 tag)
# ---------------------------------------------------------------
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-Anuken}"
REPO_NAME="${REPO_NAME:-Mindustry}"
STATE_FILE="${STATE_FILE:-$(dirname "$0")/../LAST_VERSION}"
APPSTORE_BUNDLE_ID="${APPSTORE_BUNDLE_ID:-io.anuke.mindustry}"
CHECK_APPSTORE="${CHECK_APPSTORE:-false}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

mkdir -p "$(dirname "$STATE_FILE")"

# 构造 curl 的认证头（如果提供了 token 则带上，避免匿名 rate limit）
GH_AUTH=()
if [ -n "$GITHUB_TOKEN" ]; then
  GH_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

echo "==> 查询 GitHub 最新 Release${GITHUB_TOKEN:+ (已带 token)}" >&2
LATEST_JSON=$(curl -fsSL --retry 3 \
  -H "Accept: application/vnd.github+json" \
  "${GH_AUTH[@]}" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
  || { echo "ERR: 无法获取 GitHub release" >&2; exit 1; })

RELEASE_TAG=$(echo "$LATEST_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))")
if [ -z "$RELEASE_TAG" ]; then
  echo "ERR: 无法解析 tag_name" >&2
  exit 1
fi

# 提取纯数字构建版本号（去掉前缀 v）
BUILD_VERSION="${RELEASE_TAG#v}"

echo "==> 最新 GitHub Release: ${RELEASE_TAG} (build=${BUILD_VERSION})" >&2

# 读取上次记录的版本
LAST_TAG=""
if [ -f "$STATE_FILE" ]; then
  LAST_TAG=$(tr -d '[:space:]' < "$STATE_FILE")
  echo "==> 上次构建版本: ${LAST_TAG}" >&2
fi

NEEDS_BUILD="false"
if [ "$LAST_TAG" != "$RELEASE_TAG" ]; then
  echo "==> 检测到新版本，需要构建！" >&2
  NEEDS_BUILD="true"
else
  echo "==> 已是最新版本，无需构建。" >&2
fi

# 可选：查询 App Store 版本进行比对
APP_STORE_VERSION=""
if [ "$CHECK_APPSTORE" = "true" ]; then
  echo "==> 查询 App Store 版本（bundle id: ${APPSTORE_BUNDLE_ID}）" >&2
  LOOKUP_JSON=$(curl -fsSL --retry 3 \
    "https://itunes.apple.com/lookup?bundleId=${APPSTORE_BUNDLE_ID}" || true)
  if [ -n "$LOOKUP_JSON" ]; then
    APP_STORE_VERSION=$(echo "$LOOKUP_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d.get('resultCount',0)>0:
    print(d['results'][0].get('version',''))
" 2>/dev/null || true)
    if [ -n "$APP_STORE_VERSION" ]; then
      echo "==> App Store 当前显示版本: ${APP_STORE_VERSION}" >&2
      # 验证版本号匹配规则: AppStore版本格式应为 8.<build>.0
      EXPECTED_APPVER="8.${BUILD_VERSION}.0"
      if [ "$APP_STORE_VERSION" != "$EXPECTED_APPVER" ]; then
        echo "WARN: App Store版本($APP_STORE_VERSION) 与预期版本($EXPECTED_APPVER)不一致" >&2
      fi
    fi
  fi
fi

# 写入结果到 stdout（供 Actions 读取）
echo "RELEASE_TAG=${RELEASE_TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"
echo "APP_STORE_VERSION=${APP_STORE_VERSION}"
echo "NEEDS_BUILD=${NEEDS_BUILD}"

# 如果需要构建则更新状态文件（注意：构建成功后才写，此处只输出 NEEDS_BUILD 判断）
# 实际写入由 CI 在 build success 步骤完成
