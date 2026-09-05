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
SKIP_SIGNING="true"   # 固定未签名模式

# ========= 兼容小数版本号（如 159.7）与整数版本（如 146） =========
if [[ "${BUILD_VERSION}" == *.* ]]; then
  BUILD_INT="${BUILD_VERSION%%.*}"
  DISPLAY_VERSION="8.${BUILD_VERSION}"
else
  BUILD_INT="${BUILD_VERSION}"
  DISPLAY_VERSION="8.${BUILD_VERSION}.0"
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

cd Mindustry
ACTUAL_TAG=$(git describe --tags --exact-match 2>/dev/null || git tag --points-at HEAD | head -1)
if [ "${ACTUAL_TAG}" != "${RELEASE_TAG}" ]; then
  echo "ERR: 检出的 tag (${ACTUAL_TAG:-未知}) 与目标 (${RELEASE_TAG}) 不匹配！" >&2
  exit 1
fi
echo "    已确认检出 tag=${ACTUAL_TAG}" >&2

ARC_HASH="${ARC_HASH:-}"
if [ -z "$ARC_HASH" ]; then
  ARC_HASH=$(grep -E '^archash=' gradle.properties | cut -d= -f2 | tr -d '[:space:]')
fi
echo "    Arc commit hash: ${ARC_HASH}" >&2

echo "==> [2/7] 克隆 Arc 库到同级目录 (hash=${ARC_HASH})" >&2
cd "$BUILD_DIR"
git clone --depth 1 "https://github.com/Anuken/Arc.git" Arc
cd Arc
# 复合构建要求 Arc 与 Mindustry 的 archash 严格一致（gradle.properties 里的 archash）。
# Arc 版本错位会编译出 native 符号不匹配的产物（运行期 UnsatisfiedLinkError / 崩溃），
# 因此找不到指定 hash 时直接失败，不再静默回退默认分支。
if [ -n "$ARC_HASH" ]; then
  if ! git checkout "${ARC_HASH}" 2>/dev/null; then
    # 默认分支浅克隆里通常没有旧 hash：先扩深，再尝试完整历史
    if ! git fetch --depth 50 origin "${ARC_HASH}" 2>/dev/null; then
      git fetch --unshallow 2>/dev/null || true
    fi
    if ! git checkout "${ARC_HASH}" 2>/dev/null; then
      echo "ERR: 无法检出 Arc commit ${ARC_HASH}（Mindustry gradle.properties 的 archash）" >&2
      echo "     为保证复合构建 native 符号与 Mindustry 版本一致，此处直接失败而非回退默认分支。" >&2
      exit 1
    fi
  fi
  echo "    已检出指定 Arc hash: ${ARC_HASH}" >&2
fi
echo "    当前 Arc commit: $(git rev-parse --short HEAD)" >&2

# ========= 构建准备 =========
echo "==> [3/7] 准备 JDK 检查" >&2
java -version 2>&1 | head -2

cd "$BUILD_DIR/Mindustry"
chmod +x gradlew

# ========= 提前 patch ios/build.gradle =========
echo "==> [3b/7] Patch ios/build.gradle：启用未签名 + 兼容小数版本号" >&2
IOS_GRADLE="${BUILD_DIR}/Mindustry/ios/build.gradle"
if [ -f "$IOS_GRADLE" ]; then
  # (A) 强制 RoboVM 跳过 codesign
  sed -i '' 's/iosSkipSigning = false/iosSkipSigning = true/' "$IOS_GRADLE" 2>/dev/null || \
    sed -i    's/iosSkipSigning = false/iosSkipSigning = true/' "$IOS_GRADLE"
  echo "    (A) 已设置 iosSkipSigning=true" >&2

  # (A.2) 最小安全补丁：确保 createIPA 依赖 copyNatives，并在 copyNatives 后打印简短诊断（可保留）
  perl -0777 -pi - "$IOS_GRADLE" <<'__BUILD_IPA_PATCH_A2__'
    use strict; use warnings;
    my $SQ = chr(39);
    my $DQ = chr(34);

    if (!/createIPA\s*\.dependsOn\s+(?:[^\n]*?\b)copyNatives\b/) {
      s/(createIPA\.dependsOn\s+build)/$1\ncreateIPA.dependsOn copyNatives/;
    }

    my $cn_header = qq{tasks\\.register\\(${SQ}copyNatives${SQ}\\)};
    if (/\G.*?($cn_header\s*\{)/gcs) {
      my $pos = pos($_) - length($1);
      my $len = length($_);
      my $depth = 0;
      my $i = $pos;
      my ($in_sq, $in_dq) = (0, 0);
      my @dl_lines = (
        "",
        "    doLast {",
        '        println "[copyNatives] ios/libs after copy:"',
        '        def libsDir = file("libs")',
        '        if (libsDir.exists()) {',
        '            libsDir.listFiles()?.sort()?.each { f ->',
        '                println("  " + f.name + "  (" + f.length() + " bytes)")',
        '            } ?: println("  (empty)")',
        '        } else {',
        '            println("  (libs/ dir missing)")',
        '        }',
        "    }",
      );
      my $dl_footer = join("\n", @dl_lines) . "\n";
      while ($i < $len) {
        my $c = substr($_, $i, 1);
        if (!$in_sq && !$in_dq && $c eq "\\") { $i += 2; next; }
        if (!$in_dq && $c eq $SQ)   { $in_sq = !$in_sq; $i++; next; }
        if (!$in_sq && $c eq $DQ)   { $in_dq = !$in_dq; $i++; next; }
        if (!$in_sq && !$in_dq) {
          if    ($c eq '{') { $depth++; }
          elsif ($c eq '}') {
            $depth--;
            if ($depth == 0) {
              substr($_, $i, 0) = $dl_footer;
              pos($_) = $i + length($dl_footer);
              last;
            }
          }
        }
        $i++;
      }
      pos($_) = undef;
    }
__BUILD_IPA_PATCH_A2__
  echo "    (A.2) 已注入 createIPA dependsOn copyNatives 及 copyNatives 诊断 doLast" >&2

  # (B) 修复小数版本号引发的 NumberFormatException
  # 注入 _stripDec_bv 辅助函数
  INJECT_MARKER="// === 小数版本号兼容补丁 (由 build-ipa.sh 注入) ==="
  if ! grep -qF "$INJECT_MARKER" "$IOS_GRADLE" 2>/dev/null; then
    perl -0pi -e '
      my $patch = qq{
'"$INJECT_MARKER"'
// 把 "159.7" 之类带小数的构建号裁剪成整数部分 "159"，避免 toInteger/parseInt 抛 NumberFormatException。
def _stripDec_bv(Object v) {
    if (v == null) return "0";
    String s = v.toString();
    int dot = s.indexOf((char)46);
    return (dot >= 0) ? s.substring(0, dot) : s;
}
// === 兼容补丁结束 ===
};
      if (s/((?:^|\n)(?:plugins|buildscript)\s*\{(?:[^{}]++|\{(?:[^{}]++|\{[^{}]*\})*\})*\})/$1\n$patch/s) {
      } else {
        s/\n/\n$patch/;
      }
    ' "$IOS_GRADLE"
    echo "    (B.1) 已在 ios/build.gradle 顶部注入 _stripDec_bv 辅助函数" >&2
  fi

  # 用 perl 对多种整数转换模式加 replaceAll 保护
  perl -0777 -pi -e '
    sub is_bv_expr {
      my ($s) = @_;
      return ($s =~ /\bbuildversion\b/i || $s =~ /["'"'"']buildversion["'"'"']/i);
    }
    sub wrap_bv {
      my ($expr) = @_;
      return $expr if $expr =~ /replaceAll/;
      if ($expr =~ /"\s*$/) {
        return $expr . '"'"'.toString().replaceAll("\\\\..*","")'"'"';
      }
      return $expr . '"'"'.replaceAll("\\\\..*","")'"'"';
    }

    # Group A: EXPR.toInteger() 等
    while (s{
        (?<!replaceAll\(")
        (
          (?:\b[A-Za-z_][\w]*\.)*
          buildversion
          (?:\[[^\]]*\])?
          (?:\.toString\(\))?
        )\.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($e, $m) = ($1, $2);
      is_bv_expr($e) ? (wrap_bv($e) . ".$m()") : "$e.$m()";
    }gixe) {}

    # Group B: GString.toInteger()
    while (s{
        ("\$(?:\{((?:[A-Za-z_][\w]*\.)*buildversion)\}|((?:[A-Za-z_][\w]*\.)*buildversion))")
        \.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($whole, $inner, $inner2, $meth) = ($1, $2, $3, $4);
      my $var = $inner || $inner2;
      ($var && is_bv_expr($var)) ? (wrap_bv($whole) . ".$meth()") : "$whole.$meth()";
    }gixe) {}

    # Group C: Integer.parseInt 等
    while (s{
        (Integer|Long)\.(parseInt|parseLong|valueOf)\(
            \s*
            (
                (?:[A-Za-z_][\w]*\.)*buildversion(?:\.toString\(\))?
                |
                "\$(?:\{(?:[A-Za-z_][\w]*\.)*buildversion\}|(?:[A-Za-z_][\w]*\.)*buildversion)"
                (?:\.toString\(\))?
                |
                [A-Za-z_][\w]*\.(?:getProperty|property)\(\s*["'"'"']buildversion["'"'"']\s*\)
                (?:\.toString\(\))?
                |
                [A-Za-z_][\w]*\[\s*["'"'"']buildversion["'"'"']\s*\]
                (?:\.toString\(\))?
            )
            \s*
        \)
    }{
      my ($cls, $mth, $arg) = ($1, $2, $3);
      is_bv_expr($arg) ? ("$cls.$mth(" . wrap_bv($arg) . ")") : "$cls.$mth($arg)";
    }gixe) {}

    # Group D: as int 等
    while (s{
        (?<!replaceAll\(")
        (
          (?:[A-Za-z_][\w]*\.)*
          buildversion
          (?:\[[^\]]*\])?
          (?:\.toString\(\))?
        )
        (\s+as\s+(?:int|Integer|long|Long|BigInteger)\b)
    }{
      my ($e, $cast) = ($1, $2);
      is_bv_expr($e) ? (wrap_bv($e) . $cast) : "$e$cast";
    }gixe) {}

    # Group E: (int) EXPR
    while (s{
        (\(\s*(?:int|Integer|long|Long)\s*\))
        \s+
        (
          (?:[A-Za-z_][\w]*\.)*buildversion
          (?:\[[^\]]*\])?
          (?:\.toString\(\))?
        )
    }{
      my ($cast, $e) = ($1, $2);
      is_bv_expr($e) ? ("$cast " . wrap_bv($e)) : "$cast $e";
    }gixe) {}

    # Group F: props["app.build"] 等
    while (s{
        (?<!replaceAll\(")
        (
          \w+
          (?:
              \[\s*["'"'"'](?:app\.build|buildversion)["'"'"']\s*\]
            | \.(?:getProperty|property)\(\s*["'"'"'](?:app\.build|buildversion)["'"'"']\s*\)
            | \.\s*app\s*\.\s*build
          )
          (?:\.toString\(\))?
        )\.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($e, $m) = ($1, $2);
      wrap_bv($e) . ".$m()";
    }gixe) {}
  ' "$IOS_GRADLE"

  # 覆盖写保护：强制锁定 CFBundleVersion
  perl -0777 -pi -e '
    my $guard = qq{
    // === build-ipa.sh 注入：CI 强制锁定 CFBundleVersion，无视 incrementConfig 自增 +1 ===
    if(bversion != "custom build"){ props["app.build"] = bversion.toString() }
    // === 覆盖结束 ===};
    s/(props\.store\(\s*vfile\.newWriter\(\)\s*,\s*null\s*\))/$guard\n    $1/s;
  ' "$IOS_GRADLE"
  echo "    (B.2+B.3) 小数版本兼容补丁已应用（replaceAll 保护 + app.build 覆盖写锁定）" >&2

else
  echo "WARN: 未找到 ios/build.gradle，签名与版本兼容补丁将跳过！" >&2
fi

# 关键修复（IOSGLES20 闪退）：移除 -PnoLocalArc，启用本地 Arc 复合构建。
# 原因：-PnoLocalArc 会从 JitPack 拉取 arc-core / backend-robovm 的发布 jar，
#       而这些 jar 只含 Java 字节码、不含 jnigen 编译出的 iOS native 静态库（libarc.a）。
#       Arc 的 GLES 后端（arc-core/csrc/iosgl/iosgl20.cpp，JNI 符号
#       Java_arc_backend_robovm_IOSGLES20_*）只有在从源码构建（jnigen addIOS）时才会编进 libarc.a。
#       缺失时：RoboVM 对 native 方法在运行时按符号绑定（非链接期），IPA 能编译能安装，
#       但一启动创建 GLES20 上下文就抛
#       UnsatisfiedLinkError: arc.backend.robovm.IOSGLES20.init()V -> 秒闪退。
#       去掉该参数后，Mindustry settings.gradle 检测到 ../Arc 存在且未传 noLocalArc，
#       会 includeBuild("../Arc")，从源码编译 Arc，jnigen 产出 libarc.a 并随 classpath 链接进 IPA。
GRADLE_ARGS=(
  "-Prelease"
  "-Pbuildversion=${BUILD_VERSION}"
  "--no-daemon"
  "--stacktrace"
)
echo "    RoboVM 构建参数：iosSkipSigning=true + 本地 Arc 复合构建（libarc.a 提供 IOSGLES20 native）" >&2

# 修正 robovm.xml：剥离无效 framework arc，保留有效框架路径
IOS_ROBOVM_XML="${BUILD_DIR}/Mindustry/ios/robovm.xml"
if [ -f "$IOS_ROBOVM_XML" ]; then
  perl -0777 -pi - "$IOS_ROBOVM_XML" <<'__BUILD_IPA_PATCH_ROBOVM_XML__'
    use strict; use warnings;
    my $lib_entry = qq{<lib>libs/libarc-freetype.a</lib>};

    if (m{<libs>[\s\S]*?</libs>}) {
      s{(<libs>)([\s\S]*?)(</libs>)}{
        my ($open, $body, $close) = ($1, $2, $3);
        if (index($body, '<lib>z</lib>') < 0 && index($body, 'z</lib>') < 0) {
          $body = "    <lib>z</lib>\n" . $body;
        }
        if ($body !~ m{libs/libarc-freetype\.a}) {
          $body .= "    $lib_entry\n  ";
        }
        $open . $body . $close;
      }sge;
    } else {
      s{(</(?:config|robovm)>)}
       {  <libs>\n    <lib>z</lib>\n    $lib_entry\n  </libs>\n$1}s;
    }

    my $p1 = qq{<path>libs</path>};
    if (m{<frameworkPaths>[\s\S]*?</frameworkPaths>}) {
      s{(<frameworkPaths>)([\s\S]*?)(</frameworkPaths>)}{
        my ($open, $body, $close) = ($1, $2, $3);
        $body =~ s{[ \t]*<path>[^\n]*user\.home[^\n]*</path>\n?}{}gi;
        if (index($body, $p1) < 0) {
          $body .= "    $p1\n  ";
        }
        $open . $body . $close;
      }sge;
    } else {
      s{(</(?:config|robovm)>)}
       {  <frameworkPaths>\n    $p1\n  </frameworkPaths>\n$1}s;
    }

    my @must_frameworks = (
      'UIKit', 'MetalANGLEKit', 'libGLESv2', 'libEGL', 'libfeature_support',
      'Metal', 'QuartzCore', 'CoreGraphics', 'CoreAudio', 'AudioToolbox', 'AVFoundation',
    );
    if (m{<frameworks>[\s\S]*?</frameworks>}) {
      s{(<frameworks>)([\s\S]*?)(</frameworks>)}{
        my ($open, $body, $close) = ($1, $2, $3);
        $body =~ s{[ \t]*<framework>\s*arc\s*</framework>\n?}{}gi;
        for my $fw_name (@must_frameworks) {
          my $need_entry = qq{<framework>$fw_name</framework>};
          if ($body !~ m{<framework>\s*\Q$fw_name\E\s*</framework>}) {
            $body .= "    $need_entry\n  ";
          }
        }
        $open . $body . $close;
      }sge;
    } else {
      my $inner = join("", map { "    <framework>$_</framework>\n" } @must_frameworks);
      s{(</(?:config|robovm)>)}
       {  <frameworks>\n${inner}  </frameworks>\n$1}s;
    }
__BUILD_IPA_PATCH_ROBOVM_XML__
  echo "    (A.3) robovm.xml 已修正：删除 arc.framework，保留有效框架列表" >&2
fi

# 提前准备 libarc-freetype.a 及 MetalANGLEKit
IOS_LIBS_DIR_EARLY="${BUILD_DIR}/Mindustry/ios/libs"
mkdir -p "$IOS_LIBS_DIR_EARLY"
ARC_DIR="${BUILD_DIR}/Arc"
REFERENCE_CP_SRC="${ARC_DIR}/natives/natives-freetype-ios/libs/libarc-freetype.a"
mkdir -p "${ARC_DIR}/natives/natives-ios/libs" 2>/dev/null || true
if [ -f "$REFERENCE_CP_SRC" ] && [ ! -s "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" ]; then
  cp -f "$REFERENCE_CP_SRC" "$IOS_LIBS_DIR_EARLY/libarc-freetype.a"
  echo "      ✓ 直接从 Arc 物理目录拷贝 libarc-freetype.a" >&2
fi

# 下载 MetalANGLEKit
echo "    (C.0) 下载 MetalANGLEKit v1.2.1" >&2
METAL_ZIP="/tmp/MetalANGLEKit.zip"
METAL_URL="https://github.com/libgdx/MetalANGLEKit/releases/download/v1.2.1/metalanglekit.zip"
METAL_SHA256="c7785cbe15eb9e5962677513725c8f0e33039f344235cc7691ee5ac35ff5ea91"
curl -fSL --connect-timeout 20 --retry 3 --retry-delay 2 -o "$METAL_ZIP" "$METAL_URL"
echo "${METAL_SHA256}  ${METAL_ZIP}" | shasum -a 256 -c -
unzip -q -o "$METAL_ZIP" -d "$IOS_LIBS_DIR_EARLY"
echo "    MetalANGLEKit 解压完成" >&2

# 若仍缺 libarc-freetype.a，从 jar 缓存兜底
if [ ! -s "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" ]; then
  JAR_SEARCH_DIRS=(
    "$HOME/.gradle/caches/modules-2/files-2.1"
    "${BUILD_DIR}/Arc/natives/natives-freetype-ios/build/libs"
    "${BUILD_DIR}/Arc/natives/natives-ios/build/libs"
    "${BUILD_DIR}/Arc/backends/backend-robovm/build/libs"
    "$HOME/.m2/repository"
    "$HOME/.robovm"
  )
  for D in "${JAR_SEARCH_DIRS[@]}"; do
    [ -d "$D" ] || continue
    JARLIST=$(find "$D" -name '*natives-freetype-ios*.jar' -type f 2>/dev/null || true)
    [ -z "$JARLIST" ] && continue
    TMP_E=$(mktemp -d)
    for J in $JARLIST; do
      if unzip -l "$J" 2>/dev/null | grep -q 'META-INF/robovm/ios/libs/libarc-freetype\.a'; then
        unzip -o -q -j -d "$TMP_E" "$J" 'META-INF/robovm/ios/libs/libarc-freetype.a' >/dev/null 2>&1 || true
        if [ -f "$TMP_E/libarc-freetype.a" ] && [ ! -s "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" ]; then
          cp -f "$TMP_E/libarc-freetype.a" "$IOS_LIBS_DIR_EARLY/libarc-freetype.a"
          echo "      ✓ 从 jar 缓存解出 libarc-freetype.a" >&2
          rm -rf "$TMP_E"
          break 2
        fi
      fi
    done
    rm -rf "$TMP_E"
  done
fi

# 若依然缺失，创建空占位 .a 以避免链接失败
if [ ! -s "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" ]; then
  echo "      ⚠ 未找到 libarc-freetype.a，生成空占位静态库" >&2
  EMPTY_OBJ="$(mktemp -d)/empty_stub.s"
  mkdir -p "$(dirname "$EMPTY_OBJ")"
  printf '.text\n.globl _arc_freetype_stub\n_arc_freetype_stub:\n  ret\n' > "$EMPTY_OBJ"
  as -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo /)" \
    -o "${EMPTY_OBJ%.s}.o" "$EMPTY_OBJ" 2>/dev/null || true
  if [ -f "${EMPTY_OBJ%.s}.o" ]; then
    libtool -static -o "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" "${EMPTY_OBJ%.s}.o" 2>/dev/null || \
      ar rcs "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" "${EMPTY_OBJ%.s}.o" 2>/dev/null || true
  fi
  rm -rf "$(dirname "$EMPTY_OBJ")"
fi

# ========= 初始化 robovm.properties =========
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

echo "==> [5/7] 执行精灵图打包 (tools:pack)" >&2
./gradlew "${GRADLE_ARGS[@]}" :tools:pack

echo "==> [6/7] 执行代码生成 (core:preGen)" >&2
./gradlew "${GRADLE_ARGS[@]}" :core:preGen

# 校验 version.properties
VER_FILE="${BUILD_DIR}/Mindustry/core/assets/version.properties"
if [ -f "$VER_FILE" ]; then
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

echo "==> [7/7] 构建未签名 IPA（ios:incrementConfig ios:deploy）" >&2

# 最终构建
set +e
./gradlew "${GRADLE_ARGS[@]}" ios:incrementConfig ios:deploy
GRADLE_RC=$?
set -e

if [ "$GRADLE_RC" -ne 0 ]; then
  echo "ERR: 构建失败 (Gradle 退出码 $GRADLE_RC)，请查看上方 Gradle 输出日志" >&2
  exit "$GRADLE_RC"
fi

# ========= 查找产物 =========
IPA_FILE=$(find "$BUILD_DIR/Mindustry/ios/build" -name "*.ipa" -type f | head -1 || true)
if [ -z "$IPA_FILE" ]; then
  echo "ERR: 未找到生成的 IPA 文件！" >&2
  exit 1
fi

IPA_FINAL_NAME="Mindustry-iOS-${RELEASE_TAG}_${DISPLAY_VERSION}.ipa"
IPA_FINAL="${WORKDIR}/dist/${IPA_FINAL_NAME}"
mkdir -p "$(dirname "$IPA_FINAL")"
cp "$IPA_FILE" "$IPA_FINAL"

# ========= 关键校验：IPA 可执行文件必须包含 IOSGLES20 native 符号 =========
# 背景：若构建走了 -PnoLocalArc / Arc native（libarc.a）缺失，RoboVM 在运行期才报
#   UnsatisfiedLinkError: arc.backend.robovm.IOSGLES20.init()
# 导致 IPA 能编译能安装、但一打开就闪退（链接期无感，纯运行期错误）。
# 这里用 nm 检查最终二进制是否真的含 Java_arc_backend_robovm_IOSGLES20_init，
# 没有就直接失败，宁可构建红 X 也不产出"能装但秒退"的坏包。
IPA_TMP_DIR="$(mktemp -d)"
unzip -q -o "$IPA_FINAL" -d "$IPA_TMP_DIR"
IPA_APP_BIN="$(find "$IPA_TMP_DIR" -path "*.app/*" -type f -perm -u+x 2>/dev/null | head -1 || true)"
if [ -z "$IPA_APP_BIN" ]; then
  echo "WARN: 未在 IPA 内找到可执行文件，跳过 IOSGLES20 符号校验" >&2
else
  if nm -g -arch arm64 "$IPA_APP_BIN" 2>/dev/null | grep -q "IOSGLES20_init" \
     || nm -g "$IPA_APP_BIN" 2>/dev/null | grep -q "IOSGLES20_init"; then
    echo "    ✓ 符号校验通过：二进制含 IOSGLES20_init（Arc GLES native 已链接）" >&2
  else
    echo "ERR: 二进制缺少 IOSGLES20_init 符号！Arc 的 GLES native（libarc.a）未链接，" >&2
    echo "     安装后启动会 UnsatisfiedLinkError 闪退。请确认构建未使用 -PnoLocalArc" >&2
    echo "     （本地 Arc 复合构建必须启用，见 build-ipa.sh GRADLE_ARGS 注释）。" >&2
    rm -rf "$IPA_TMP_DIR"
    exit 1
  fi
fi
rm -rf "$IPA_TMP_DIR"

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

export IPA_OUTPUT="$IPA_FINAL"
export IPA_META="$META"
echo "IPA_OUTPUT=${IPA_FINAL}"
echo "IPA_META=${META}"
echo "RELEASE_TAG=${RELEASE_TAG}"
echo "BUILD_VERSION=${BUILD_VERSION}"
echo "DISPLAY_VERSION=${DISPLAY_VERSION}"
