#!/usr/bin/env bash
# ---------------------------------------------------------------
# Mindustry iOS IPA Build Script（未签名版 · TrollStore 安装）
# ---------------------------------------------------------------
# 必须环境：
#   - macOS 13+  (macOS runner)
#   - Xcode 14+ (含 Command Line Tools)
#   - JDK 17 (Temurin 推荐)
#
# 说明：本脚本固定输出**未签名 IPA**，无需 Apple 开发者证书 / 描述文件 / keychain。
#       产物使用 TrollStore / AltStore / Sideloadly 等方式自签安装到真机。
#
# 输入环境变量（必填）：
#   BUILD_VERSION         Mindustry 构建号，如 146（严格对应 tag v146）
#
# 可选：
#   ARC_HASH              指定 Arc commit hash，默认读取 gradle.properties
# ---------------------------------------------------------------
set -euo pipefail

# ========= 参数校验 =========
if [ -z "${BUILD_VERSION:-}" ]; then
  echo "ERR: BUILD_VERSION 环境变量未设置（如 146，严格对应 tag v146）" >&2
  exit 1
fi

RELEASE_TAG="v${BUILD_VERSION}"
# 固定：本工程默认输出未签名 IPA，由 TrollStore/AltStore 等侧载工具安装
SKIP_SIGNING="true"

# ========= 兼容小数版本号（如 159.7）与整数版本（如 146） =========
# BUILD_INT  ：取小数点前的整数主版本（用于 Gradle .toInteger() 兜底）
# DISPLAY_VERSION：iOS 显示版本号（严格 3 段式，符合 CFBundleShortVersionString 规范）
if [[ "${BUILD_VERSION}" == *.* ]]; then
  BUILD_INT="${BUILD_VERSION%%.*}"
  DISPLAY_VERSION="8.${BUILD_VERSION}"          # 例: 159.7 -> 8.159.7
else
  BUILD_INT="${BUILD_VERSION}"
  DISPLAY_VERSION="8.${BUILD_VERSION}.0"        # 例: 146  -> 8.146.0
fi

echo "=========================================================="
echo " Mindustry iOS IPA 构建（未签名版）"
echo " Release Tag    : ${RELEASE_TAG}"
echo " Build Version  : ${BUILD_VERSION}   (整数主版本=${BUILD_INT})"
echo " iOS Display Ver: ${DISPLAY_VERSION}  (CFBundleShortVersionString)"
echo " CFBundleVersion: ${BUILD_VERSION}"
echo " Signing Mode   : UNSIGNED (TrollStore / AltStore / Sideloadly)"
echo "=========================================================="

# ========= 目录初始化 =========
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${WORKDIR}/build-root"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> [1/7] 克隆 Mindustry (tag=${RELEASE_TAG})" >&2
git clone --depth 1 --branch "${RELEASE_TAG}" \
  "https://github.com/Anuken/Mindustry.git" Mindustry \
  || { echo "ERR: 克隆失败，tag ${RELEASE_TAG} 不存在？" >&2; exit 1; }

# 验证克隆下来的版本是否对应
cd Mindustry
ACTUAL_TAG=$(git describe --tags --exact-match 2>/dev/null || git tag --points-at HEAD | head -1)
if [ "${ACTUAL_TAG}" != "${RELEASE_TAG}" ]; then
  echo "ERR: 检出的 tag (${ACTUAL_TAG:-未知}) 与目标 (${RELEASE_TAG}) 不匹配！严格遵循版本号打包失败。" >&2
  exit 1
fi
echo "    已确认检出 tag=${ACTUAL_TAG}" >&2

# 从 gradle.properties 读取 Arc hash
ARC_HASH="${ARC_HASH:-}"
if [ -z "$ARC_HASH" ]; then
  ARC_HASH=$(grep -E '^archash=' gradle.properties | cut -d= -f2 | tr -d '[:space:]')
fi
echo "    Arc commit hash: ${ARC_HASH}" >&2

echo "==> [2/7] 克隆 Arc 库到同级目录 (hash=${ARC_HASH})" >&2
cd "$BUILD_DIR"
git clone --depth 1 "https://github.com/Anuken/Arc.git" Arc
cd Arc
if [ -n "$ARC_HASH" ]; then
  # 注意：--depth 1 下 fetch 老 commit 可能失败；fetch 或 checkout 任一失败均回退到默认分支
  if git fetch --depth 50 origin "${ARC_HASH}" 2>/dev/null && git checkout "${ARC_HASH}" 2>/dev/null; then
    echo "    已检出指定 Arc hash: ${ARC_HASH}" >&2
  else
    # 再尝试扩大深度拉取（避免浅克隆刚好截断到该 commit）
    if git fetch --unshallow 2>/dev/null && git checkout "${ARC_HASH}" 2>/dev/null; then
      echo "    已通过 unshallow 检出 Arc hash: ${ARC_HASH}" >&2
    else
      DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || echo "master")
      echo "WARN: 指定的 Arc hash $ARC_HASH 未找到，回退到 ${DEFAULT_BRANCH} HEAD" >&2
      git checkout "${DEFAULT_BRANCH}" || git checkout master
    fi
  fi
fi
echo "    当前 Arc commit: $(git rev-parse --short HEAD)" >&2

# ========= 构建准备（已移除 Apple 证书 / provisioning 导入逻辑）=========
echo "==> [3/7] 准备 JDK 检查" >&2
java -version 2>&1 | head -2

cd "$BUILD_DIR/Mindustry"

# 给 gradlew 执行权限
chmod +x gradlew

# ========= 提前 patch ios/build.gradle（必须在首次执行 gradle 之前完成） =========
echo "==> [3b/7] Patch ios/build.gradle：启用未签名 + 兼容小数版本号" >&2
IOS_GRADLE="${BUILD_DIR}/Mindustry/ios/build.gradle"
if [ -f "$IOS_GRADLE" ]; then
  # (A) 强制 RoboVM 跳过 codesign（无需证书 / 描述文件）
  #     先尝试 macOS (BSD) sed，失败再回退到 GNU sed
  sed -i '' 's/iosSkipSigning = false/iosSkipSigning = true/' "$IOS_GRADLE" 2>/dev/null || \
    sed -i    's/iosSkipSigning = false/iosSkipSigning = true/' "$IOS_GRADLE"
  echo "    (A) 已设置 iosSkipSigning=true" >&2

  # (B) 修复小数版本号（如 159.7）触发的 NumberFormatException
  #     上游 ios/build.gradle 第 28 行附近：buildversion.toInteger() 或 Integer.parseInt(buildversion)
  #     对于输入 "159.7" → 直接报 NumberFormatException
  #     注入 replaceAll("\\..*","") 去掉小数部分后再转 int，兼容整数 & 小数：
  #       buildversion.toInteger()
  #         => buildversion.replaceAll("\\..*","").toInteger()
  #       Integer.parseInt(buildversion)
  #         => Integer.parseInt(buildversion.replaceAll("\\..*",""))
  #     注：Groovy/Java 字符串字面量里 "\\.." 才表示正则的 literal dot \..
  #         因此目标文件需写双反斜杠；下面用 perl 跨平台（macOS / Linux 行为一致）完成替换
  BEFORE_COUNT=$(grep -cE '\.toInteger\(\)|Integer\.parseInt\(' "$IOS_GRADLE" 2>/dev/null || echo 0)
  if [ "$BEFORE_COUNT" -gt 0 ]; then
    # perl -0pi 跨平台一致 in-place edit，shell 单引号内 \\\\ 交给 perl s/// 后变成 2 个反斜杠
    perl -0pi -e '
      s/\b(buildversion)\.toInteger\(\)/$1.replaceAll("\\\\..*","").toInteger()/g;
      s/Integer\.parseInt\((buildversion)\)/Integer.parseInt($1.replaceAll("\\\\..*",""))/g;
    ' "$IOS_GRADLE"
    PATCHED_COUNT=$(grep -c 'replaceAll' "$IOS_GRADLE" 2>/dev/null || echo 0)
    echo "    (B) 小数版本兼容：发现 ${BEFORE_COUNT} 处整数解析 → 成功注入 ${PATCHED_COUNT} 处 replaceAll 保护" >&2
    # 关键行诊断：打印第 20~40 行，便于 CI 日志确认补丁位置
    echo "    --- ios/build.gradle L20~40 (诊断) ---" >&2
    sed -n '20,40p' "$IOS_GRADLE" >&2 || true
    echo "    -------------------------------------" >&2
  else
    echo "    (B) 未发现 .toInteger()/Integer.parseInt，跳过小数兼容补丁" >&2
  fi
else
  echo "WARN: 未找到 ios/build.gradle，签名与版本兼容补丁将跳过！" >&2
fi

GRADLE_ARGS=(
  "-Prelease"
  "-Pbuildversion=${BUILD_VERSION}"
  "--no-daemon"
  "--stacktrace"
)
# 固定未签名模式：不再向 Gradle 传入 signIdentity / provisioningProfile 参数
echo "    RoboVM 构建将设置 iosSkipSigning=true，跳过 codesign 阶段" >&2

# ========= 初始化 robovm.properties（确保 CFBundleShortVersionString 一致） =========
echo "==> [4/7] 初始化 ios/robovm.properties（版本严格同步 ${DISPLAY_VERSION}）" >&2
ROBOVM_PROPS="${BUILD_DIR}/Mindustry/ios/robovm.properties"
cat > "$ROBOVM_PROPS" <<EOF
# 由自动化脚本生成 - 严格遵循版本号
app.id=io.anuke.mindustry
app.version=${DISPLAY_VERSION}
app.mainclass=mindustry.ios.IOSLauncher
app.executable=IOSLauncher
app.name=Mindustry
app.build=${BUILD_VERSION}
EOF
echo "    robovm.properties 内容：" >&2
cat "$ROBOVM_PROPS" >&2

echo "==> [5/7] 执行精灵图打包 (tools:pack)" >&2
./gradlew "${GRADLE_ARGS[@]}" :tools:pack

echo "==> [6/7] 执行代码生成 (core:preGen)" >&2
./gradlew "${GRADLE_ARGS[@]}" :core:preGen

# 验证生成的 version.properties
VER_FILE="${BUILD_DIR}/Mindustry/core/assets/version.properties"
if [ -f "$VER_FILE" ]; then
  echo "    version.properties 校验：" >&2
  cat "$VER_FILE" >&2
  VNUM=$(grep "^number=" "$VER_FILE" | cut -d= -f2)
  VBUILD=$(grep "^build=" "$VER_FILE" | cut -d= -f2)
  if [ "$VNUM" != "8" ]; then
    echo "ERR: version.properties 主版本号不匹配！期望 8，实际 ${VNUM}" >&2
    exit 1
  fi
  if [ "$VBUILD" != "${BUILD_VERSION}" ]; then
    echo "ERR: version.properties build 版本不匹配！期望 ${BUILD_VERSION}，实际 ${VBUILD}" >&2
    exit 1
  fi
  echo "    版本校验通过 ✓" >&2
fi

echo "==> [7/7] 构建未签名 IPA (ios:createIPA, iosSkipSigning=true)" >&2
echo "    iosSkipSigning 已在 [3b/7] 阶段提前设置 ✓" >&2

./gradlew "${GRADLE_ARGS[@]}" :ios:createIPA

# ========= 查找产物 =========
IPA_FILE=$(find "$BUILD_DIR/Mindustry/ios/build" -name "*.ipa" -type f | head -1 || true)
if [ -z "$IPA_FILE" ]; then
  echo "ERR: 未找到生成的 IPA 文件！" >&2
  echo "    搜索 ios/build/ 下的内容：" >&2
  find "$BUILD_DIR/Mindustry/ios/build" -maxdepth 4 -type f >&2 || true
  exit 1
fi

# 重命名产物为规范文件名：Mindustry-iOS-v{build}_{shortver}.ipa
IPA_FINAL_NAME="Mindustry-iOS-${RELEASE_TAG}_${DISPLAY_VERSION}.ipa"
IPA_FINAL="${WORKDIR}/dist/${IPA_FINAL_NAME}"
mkdir -p "$(dirname "$IPA_FINAL")"
cp "$IPA_FILE" "$IPA_FINAL"

# 写一个构建元数据文件
META="${WORKDIR}/dist/${IPA_FINAL_NAME}.meta.txt"
{
  echo "Mindustry iOS IPA Build Metadata"
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Release Tag:          ${RELEASE_TAG}"
  echo "Build Version (build): ${BUILD_VERSION}"
  echo "CFBundleShortVersionString: ${DISPLAY_VERSION}"
  echo "CFBundleVersion:      ${BUILD_VERSION}"
  echo "Mindustry Commit:     $(cd "$BUILD_DIR/Mindustry" && git rev-parse HEAD)"
  echo "Arc Commit:           $(cd "$BUILD_DIR/Arc" && git rev-parse HEAD)"
  echo "JDK Version:          $(java -version 2>&1 | head -1)"
  echo "Xcode Version:        $(xcodebuild -version 2>/dev/null | head -2 | tr '\n' '; ')"
  echo "Signed:               NO (unsigned IPA)"
  echo "Install Methods:      TrollStore (推荐) / AltStore / Sideloadly 侧载"
} > "$META"

echo ""
echo "=========================================================="
echo " 构建成功 ✓（未签名 IPA）"
echo " IPA     : ${IPA_FINAL}"
echo " Meta    : ${META}"
echo " 安装方式：TrollStore 直接导入 ｜ AltStore / Sideloadly 自签侧载"
echo "=========================================================="

# 让 CI 方便读取
export IPA_OUTPUT="$IPA_FINAL"
export IPA_META="$META"
echo "IPA_OUTPUT=${IPA_FINAL}"
echo "IPA_META=${META}"
echo "RELEASE_TAG=${RELEASE_TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"
echo "DISPLAY_VERSION=${DISPLAY_VERSION}"
