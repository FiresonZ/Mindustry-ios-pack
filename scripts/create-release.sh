#!/usr/bin/env bash
# -------------------------------------------------------------------
# create-release.sh - 计算 IPA SHA256/大小 并生成 Release notes
#
# 输入（环境变量）：
#   RELEASE_ASSET_DIR  产物目录（默认 ./dist）
#   RELEASE_TAG        release tag，如 ios-v146（必填）
#   DISPLAY_VERSION    显示版本，如 8.146.0（必填）
#   BUILD_VERSION      构建号，如 146（必填）
#   GITHUB_REPOSITORY  owner/repo（GitHub 自动注入）
#
# 输出：
#   $GITHUB_OUTPUT: ipa_path / release_name
#   文件：RELEASE_NOTES.md
#
# 说明：Release notes 排版与上游参考仓库保持一致：表头信息 + 下载（大小/SHA256）+ 安装方式 + 说明。
# -------------------------------------------------------------------
set -euo pipefail

ASSET_DIR="${RELEASE_ASSET_DIR:-./dist}"
RELEASE_TAG="${RELEASE_TAG:?}"; DISPLAY_VERSION="${DISPLAY_VERSION:?}"; BUILD_VERSION="${BUILD_VERSION:?}"
GH_REPO="${GITHUB_REPOSITORY:-}"
# GitHub Actions 自动注入；本地测试时未定义则回退 /dev/null
GH_OUT="${GITHUB_OUTPUT:-/dev/null}"
UPSTREAM_REPO="Anuken/Mindustry"
UPSTREAM_TAG="v${BUILD_VERSION}"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}/tree/${UPSTREAM_TAG}"
ACTIONS_URL="https://github.com/${GH_REPO}/actions/workflows/ios-ipa-build.yml"
RELEASE_NAME="Mindustry iOS IPA ${DISPLAY_VERSION} (${RELEASE_TAG})"

[ -d "$ASSET_DIR" ] || { echo "::error:: 产物目录不存在: $ASSET_DIR"; exit 1; }

IPA_FILE=$(find "$ASSET_DIR" -maxdepth 2 -name "*.ipa" -type f | head -1 || true)
[ -n "$IPA_FILE" ] && [ -f "$IPA_FILE" ] || { echo "::error:: 在 $ASSET_DIR 未找到 IPA"; exit 1; }

SHA256=$(shasum -a 256 "$IPA_FILE" | awk '{print $1}')
SIZE=$(du -h "$IPA_FILE" | cut -f1)
BASENAME=$(basename "$IPA_FILE")

echo "ipa_path=$IPA_FILE"          >> "$GH_OUT"
echo "release_name=$RELEASE_NAME"  >> "$GH_OUT"

cat > RELEASE_NOTES.md <<EOF
## 📦 ${RELEASE_NAME}
| 项目 | 值 |
|---|---|
| 🏷️ Tag | \`${RELEASE_TAG}\` |
| 🌱 上游仓库 | [${UPSTREAM_REPO}](https://github.com/${UPSTREAM_REPO}) |
| 📌 上游 Tag | [${UPSTREAM_TAG}](${UPSTREAM_URL}) |
| 🔢 Build Version | \`${BUILD_VERSION}\` |
| 📱 CFBundleShortVersionString | \`${DISPLAY_VERSION}\` |
| ⏱️ 构建时间 | $(date -u '+%Y-%m-%d %H:%M UTC') |
---
### 📦 下载
- 文件：\`${BASENAME}\`
- 大小：${SIZE}
- SHA256：\`${SHA256}\`
- 元数据：\`${BASENAME}.meta.txt\`（含上游 tag 与 commit hash，便于按 GPLv3 追溯源码）
---
### 📥 iPhone 安装方式
本 IPA 为**未签名**版本，需自签或利用巨魔商店安装：
1. **TrollStore（推荐）**：直接在 TrollStore 中打开 / 导入 IPA 安装即可，无需再签名，永久有效。
2. **AltStore / Sideloadly**：侧载自签安装（免费 Apple ID 7 天证书限制，付费开发者可一年）。
---
### 💡 说明
- 产物为未签名 IPA，内容与 App Store 版严格对齐上游 \`${UPSTREAM_TAG}\`。
- 此 Release 由 [ios-ipa-build 工作流](${ACTIONS_URL}) 自动生成。
EOF

echo "✅ Release notes generated: ${BASENAME} (${SIZE}, SHA256 ${SHA256})"