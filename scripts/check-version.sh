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
# 注意：本脚本无调试输出，所有 stderr 信息均为正常流程日志。
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

# 提取构建版本号（去掉前缀 v），兼容整数（v146）与小数（v159.7）
BUILD_VERSION="${RELEASE_TAG#v}"
BUILD_INT="${BUILD_VERSION%%.*}"

# 根据是否含小数推导 display 版本（3 段式，符合苹果 CFBundleShortVersionString 规范）
if [[ "$BUILD_VERSION" == *.* ]]; then
  DISPLAY_VERSION="8.${BUILD_VERSION}"        # 如 159.7 -> 8.159.7
else
  DISPLAY_VERSION="8.${BUILD_VERSION}.0"      # 如 146 -> 8.146.0
fi

echo "==> 最新 GitHub Release: ${RELEASE_TAG} (build=${BUILD_VERSION}, build_int=${BUILD_INT}, display=${DISPLAY_VERSION})" >&2

# 读取上次记录的版本（跳过注释行）
LAST_TAG=""
if [ -f "$STATE_FILE" ]; then
  LAST_TAG=$(grep -v '^\s*#' "$STATE_FILE" | tr -d '[:space:]' 2>/dev/null || true)
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
      EXPECTED_APPVER="${DISPLAY_VERSION}"
      if [ "$APP_STORE_VERSION" != "$EXPECTED_APPVER" ]; then
        echo "WARN: App Store版本($APP_STORE_VERSION) 与预期版本($EXPECTED_APPVER)不一致" >&2
      fi
    fi
  fi
fi

# 输出结果变量（供 CI 读取）
echo "RELEASE_TAG=${RELEASE_TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"
echo "BUILD_INT=${BUILD_INT}"
echo "DISPLAY_VERSION=${DISPLAY_VERSION}"
echo "APP_STORE_VERSION=${APP_STORE_VERSION}"
echo "NEEDS_BUILD=${NEEDS_BUILD}"

# 注意：实际更新状态文件由构建成功后的步骤完成，此处仅作判断。
