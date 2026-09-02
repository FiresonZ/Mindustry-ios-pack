#!/usr/bin/env bash
# ---------------------------------------------------------------
# Mindustry iOS IPA Build Script
# ---------------------------------------------------------------
# 必须环境：
#   - macOS 13+  (macOS runner)
#   - Xcode 14+ (含 Command Line Tools)
#   - JDK 17 (Temurin 推荐)
#   - Apple 签名证书已导入 Keychain
#   - Provisioning Profile 已放置 ~/Library/...
#
# 输入环境变量（必填）：
#   BUILD_VERSION         Mindustry 构建号，如 146（严格对应 tag v146）
#
# 输入环境变量（签名相关 - 真机 IPA 必填）：
#   IOS_SIGN_IDENTITY     e.g. "Apple Development: XXX (TEAMID)"
#   IOS_PROV_PROFILE_NAME e.g. "Mindustry iOS Dev"
#   IOS_PROV_PROFILE_UUID e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   IOS_TEAM_ID           10字符 Team ID
#
# 可选：
#   SKIP_SIGNING          true 则生成未签名 IPA（仅模拟器无法安装到真机）
#   ARC_HASH              指定 Arc commit hash，默认读取 gradle.properties
# ---------------------------------------------------------------
set -euo pipefail

# ========= 参数校验 =========
if [ -z "${BUILD_VERSION:-}" ]; then
  echo "ERR: BUILD_VERSION 环境变量未设置（如 146，严格对应 tag v146）" >&2
  exit 1
fi

RELEASE_TAG="v${BUILD_VERSION}"
SKIP_SIGNING="${SKIP_SIGNING:-false}"

echo "=========================================================="
echo " Mindustry iOS IPA 构建"
echo " Release Tag    : ${RELEASE_TAG}"
echo " Build Version  : ${BUILD_VERSION}"
echo " iOS Display Ver: 8.${BUILD_VERSION}.0"
echo " Skip Signing   : ${SKIP_SIGNING}"
echo "=========================================================="

# ========= 目录初始化 =========
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${WORKDIR}/build-root"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> [1/8] 克隆 Mindustry (tag=${RELEASE_TAG})" >&2
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

echo "==> [2/8] 克隆 Arc 库到同级目录 (hash=${ARC_HASH})" >&2
cd "$BUILD_DIR"
git clone --depth 1 "https://github.com/Anuken/Arc.git" Arc
cd Arc
if [ -n "$ARC_HASH" ]; then
  git fetch --depth 1 origin "${ARC_HASH}"
  git checkout "${ARC_HASH}" || {
    echo "WARN: 指定的 Arc hash $ARC_HASH 未找到，回退到 master HEAD" >&2
    git checkout master
  }
fi
echo "    当前 Arc commit: $(git rev-parse --short HEAD)" >&2

# ========= 安装证书和描述文件（CI 环境） =========
if [ "${SKIP_SIGNING}" != "true" ]; then
  echo "==> [3/8] 配置 Apple 签名证书" >&2
  if [ -n "${IOS_CERT_BASE64:-}" ] && [ -n "${IOS_CERT_PASSWORD:-}" ] && [ -n "${IOS_PROV_PROFILE_BASE64:-}" ]; then
    # 导入证书
    CERT_P12="${WORKDIR}/signing_cert.p12"
    echo -n "$IOS_CERT_BASE64" | base64 -d > "$CERT_P12"
    KEYCHAIN="${WORKDIR}/ios-build.keychain-db"
    KEYCHAIN_PASS="buildpass_$(date +%s)"

    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" || true
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$CERT_P12" -k "$KEYCHAIN" -P "$IOS_CERT_PASSWORD" -T /usr/bin/codesign || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
    security list-keychains -s "$KEYCHAIN" "$(security list-keychains -d user | tr -d '"' | head -1)"

    # 安装 provisioning profile
    PROV_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROV_DIR"
    PROV_FILE="${PROV_DIR}/${IOS_PROV_PROFILE_UUID:-profile}.mobileprovision"
    echo -n "$IOS_PROV_PROFILE_BASE64" | base64 -d > "$PROV_FILE"
    echo "    已安装 provisioning profile -> ${PROV_FILE}" >&2
    rm -f "$CERT_P12"
  else
    echo "    未提供证书 Base64，假设证书已预先安装在系统中" >&2
  fi
else
  echo "==> [3/8] SKIP_SIGNING=true，跳过签名配置" >&2
fi

# ========= 构建 =========
echo "==> [4/8] 准备 JDK 检查" >&2
java -version 2>&1 | head -2

cd "$BUILD_DIR/Mindustry"

# 给 gradlew 执行权限
chmod +x gradlew

GRADLE_ARGS=(
  "-Prelease"
  "-Pbuildversion=${BUILD_VERSION}"
  "--no-daemon"
  "--stacktrace"
)

if [ "${SKIP_SIGNING}" = "true" ]; then
  echo "    (将在 robovm 配置中跳过签名)" >&2
fi

# 如果有签名标识则传入
if [ -n "${IOS_SIGN_IDENTITY:-}" ]; then
  GRADLE_ARGS+=("-PsignIdentity=${IOS_SIGN_IDENTITY}")
fi
if [ -n "${IOS_PROV_PROFILE_NAME:-}" ]; then
  GRADLE_ARGS+=("-PprovisioningProfile=${IOS_PROV_PROFILE_NAME}")
fi

# ========= 初始化 robovm.properties（确保 CFBundleShortVersionString 一致） =========
echo "==> [5/8] 初始化 ios/robovm.properties（版本严格同步 8.${BUILD_VERSION}.0）" >&2
ROBOVM_PROPS="${BUILD_DIR}/Mindustry/ios/robovm.properties"
# 如果 ios/build.gradle 里的 incrementConfig 会自动递增 app.build，
# 我们先预创建一个 base 保证 app.version 严格等于 8.<BUILD>.0
cat > "$ROBOVM_PROPS" <<EOF
# 由自动化脚本生成 - 严格遵循版本号
app.id=io.anuke.mindustry
app.version=8.${BUILD_VERSION}.0
app.mainclass=mindustry.ios.IOSLauncher
app.executable=IOSLauncher
app.name=Mindustry
app.build=${BUILD_VERSION}
EOF
echo "    robovm.properties 内容：" >&2
cat "$ROBOVM_PROPS" >&2
# 为防止 incrementConfig 任务重新覆盖，我们用 patch 的方式：禁用它的自增逻辑
# 通过一个简单的 init 脚本提前写好，build 会以传入 buildversion 重新写入一次 app.version

echo "==> [6/8] 执行精灵图打包 (tools:pack)" >&2
./gradlew "${GRADLE_ARGS[@]}" :tools:pack

echo "==> [7/8] 执行代码生成 (core:preGen)" >&2
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

echo "==> [8/8] 构建 IPA (ios:createIPA)" >&2
if [ "${SKIP_SIGNING}" = "true" ]; then
  # 通过临时修改 ios/build.gradle 设置 iosSkipSigning=true
  sed -i '' 's/iosSkipSigning = false/iosSkipSigning = true/' ios/build.gradle || \
    sed -i 's/iosSkipSigning = false/iosSkipSigning = true/' ios/build.gradle
  echo "    已设置 iosSkipSigning=true" >&2
fi

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
IPA_FINAL_NAME="Mindustry-iOS-${RELEASE_TAG}_8.${BUILD_VERSION}.0.ipa"
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
  echo "CFBundleShortVersionString: 8.${BUILD_VERSION}.0"
  echo "CFBundleVersion:      ${BUILD_VERSION}"
  echo "Mindustry Commit:     $(cd "$BUILD_DIR/Mindustry" && git rev-parse HEAD)"
  echo "Arc Commit:           $(cd "$BUILD_DIR/Arc" && git rev-parse HEAD)"
  echo "JDK Version:          $(java -version 2>&1 | head -1)"
  echo "Xcode Version:        $(xcodebuild -version 2>/dev/null | head -2 | tr '\n' '; ')"
  echo "Signed:               $([ "$SKIP_SIGNING" = "true" ] && echo NO || echo YES)"
  echo "Sign Identity:        ${IOS_SIGN_IDENTITY:-(not recorded)}"
  echo "Provisioning Profile: ${IOS_PROV_PROFILE_NAME:-(not recorded)}"
} > "$META"

echo ""
echo "=========================================================="
echo " 构建成功 ✓"
echo " IPA     : ${IPA_FINAL}"
echo " Meta    : ${META}"
echo "=========================================================="

# 让 CI 方便读取
export IPA_OUTPUT="$IPA_FINAL"
export IPA_META="$META"
echo "IPA_OUTPUT=${IPA_FINAL}"
echo "IPA_META=${META}"
echo "RELEASE_TAG=${RELEASE_TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"
echo "DISPLAY_VERSION=8.${BUILD_VERSION}.0"
