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
  #     上游 ios/build.gradle 在配置阶段把 buildversion（传入 "159.7"）当整数解析时抛异常。
  #     策略：
  #       1. 先在文件顶部注入安全辅助方法 _stripDec(ver)，供任何表达式调用。
  #       2. 枚举 Groovy/Gradle 中所有常见的字符串→整数转换写法，统一在 buildversion 表达式
  #          与转换操作之间插入 .replaceAll("\\..*","") 去小数保护。
  #
  #     覆盖的模式（EXPR = buildversion / project.buildversion / "$buildversion" / 等）：
  #       A. 方法调用：  EXPR.toInteger() | EXPR.toLong() | EXPR.toBigInteger()
  #       B. Groovy 强转：EXPR as int | EXPR as Integer | EXPR as long | EXPR as Long | EXPR as BigInteger
  #       C. (Type) 强转：(int)EXPR | (Integer) EXPR | (long) EXPR | (Long) EXPR
  #       D. 静态方法：  Integer.parseInt(EXPR) | Integer.valueOf(EXPR)
  #                      Long.parseLong(EXPR)  | Long.valueOf(EXPR)
  #                      且支持 Groovy 字符串插值：Integer.parseInt("$buildversion")
  #
  #     注：Groovy/Java 字符串字面量里 "\\.." 才表示正则 literal dot \.，
  #         所以目标文件中需写双反斜杠。使用 perl 以保证 macOS/Linux 行为一致。

  # ---- (B.0) 辅助：把所有出现的候选整数转换位置先打印诊断 ----
  echo "    (B.0) 扫描整数转换候选点（构建失败时请核对是否有遗漏模式）：" >&2
  grep -nE '\.(toInteger|toLong|toBigInteger)\(|as\s+(int|Integer|long|Long|BigInteger)(\s|$)|\(int\)|\(Integer\)|\(long\)|\(Long\)|Integer\.(parseInt|valueOf)\(|Long\.(parseLong|valueOf)\(' "$IOS_GRADLE" 2>/dev/null | head -40 >&2 || echo "      （未命中任何已知整数转换模式）" >&2

  # ---- (B.1) 在文件非常靠前的位置注入 _stripDec 工具函数 ----
  # 在第 1 个非空非注释非插件声明行之前注入；若找不到合适位置就硬塞到第 1 行后。
  INJECT_MARKER="// === 小数版本号兼容补丁 (由 build-ipa.sh 注入) ==="
  if ! grep -qF "$INJECT_MARKER" "$IOS_GRADLE" 2>/dev/null; then
    # 用 perl 插入：跳过文件开头的 buildscript{} / plugins{} / import / apply plugin 行，
    # 在这些之后找到第一处"普通代码行"前插入补丁。找不到插入点时直接塞到第 2 行。
    perl -0pi -e '
      my $patch = qq{
'"$INJECT_MARKER"'
// 把 "159.7" 之类带小数的构建号裁剪成整数部分 "159"，避免 toInteger/parseInt 抛 NumberFormatException。
// 所有需要把构建号当整数使用的地方，都用 _stripDec(xxx) 包一层，或直接在变量后接 .replaceAll("\\\\..*","")
def _stripDec_bv(Object v) {
    if (v == null) return "0";
    String s = v.toString();
    int dot = s.indexOf((char)46);
    return (dot >= 0) ? s.substring(0, dot) : s;
}
// === 兼容补丁结束 ===
};
      # 策略：如果存在 plugins { ... } 或 buildscript { ... } 块，把补丁插到该块之后的第一个空行之后。
      if (s/((?:^|\n)(?:plugins|buildscript)\s*\{(?:[^{}]++|\{(?:[^{}]++|\{[^{}]*\})*\})*\})/$1\n$patch/s) {
        # 已成功插到 plugins/buildscript 之后
      } else {
        # 退化：直接插到第 1 行结尾（即第 2 行位置）
        s/\n/\n$patch/;
      }
    ' "$IOS_GRADLE"
    echo "    (B.1) 已在 ios/build.gradle 顶部注入 _stripDec_bv 辅助函数" >&2
  fi

  # ---- (B.2) 用 perl 对多种模式统一打补丁（仅针对 buildversion 相关表达式）----
  # 使用 perl -0777 (slurp) + 多轮 s///ge；每轮在替换代码块中判断捕获的表达式
  # 是否确实引用了 buildversion（含 property("buildversion") 这种字符串索引形式），
  # 只有命中的才加 .replaceAll("\\..*","") 去小数保护，避免误伤其他整数转换。
  perl -0777 -pi -e '
    # 判断表达式是否引用了 buildversion（裸词 / 属性链 / 字符串键 / GString 内）
    sub is_bv_expr {
      my ($s) = @_;
      return ($s =~ /\bbuildversion\b/i                  # 裸词或链中出现
           || $s =~ /["'"'"']buildversion["'"'"']/i);    # 字符串键：["buildversion"] / getProperty("buildversion")
    }

    sub wrap_bv {
      my ($expr) = @_;
      return $expr if $expr =~ /replaceAll/;               # 已经有补丁，跳过
      if ($expr =~ /"\s*$/) {
        # 字面字符串 / GString 结尾: 需要 .toString() 再 replaceAll
        return $expr . '"'"'.toString().replaceAll("\\\\..*","")'"'"';
      }
      return $expr . '"'"'.replaceAll("\\\\..*","")'"'"';
    }

    # ---------- Group A: EXPR.toInteger() / .toLong() / .toBigInteger() ----------
    # 仅当 EXPR 是 buildversion（或带前缀 project.buildversion / project["buildversion"] 等）时改
    while (s{
        (?<!replaceAll\(")
        (
          (?:\b[A-Za-z_][\w]*\.)*                        # 可选 project. / properties. / ext. / rootProject.
          buildversion                                    # 必须出现 buildversion 关键字
          (?:\[[^\]]*\])?                                 # 可选下标（但 buildversion 本身是属性，这里只保留下标写法兜底）
          (?:\.toString\(\))?                             # 可选显式 toString()
        )\.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($e, $m) = ($1, $2);
      is_bv_expr($e) ? (wrap_bv($e) . ".$m()") : "$e.$m()";
    }gixe) {}

    # ---------- Group B: "$buildversion".toInteger() 或 "${buildversion}".toInteger() ----------
    # GString 结尾加 .toInteger 等；变量名必须是 buildversion（或属性链带 buildversion）
    while (s{
        ("\$(?:\{((?:[A-Za-z_][\w]*\.)*buildversion(?:\[[^\]]*\])?)\}|((?:[A-Za-z_][\w]*\.)*buildversion))")
        \.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($before, $m) = ($1, $+);
      my $whole = $1;  # 整个 GString 字面量 "$buildversion" / "${buildversion}"
      # $+ 是最后一个捕获（toInteger/...），我们要捕获变量部分则看 $2 $3
      my $var_in_gstring = $2 || $3 || "";
      if (is_bv_expr($var_in_gstring)) {
        wrap_bv($whole) . ".$m()"
      } else {
        "$whole.$m()"
      }
    }gixe) {}
    # 注：上面 Group B 捕获里 $4 会是方法名；重写更清晰版本（把方法名放入 $4）：
    # 由于上一轮的 while 匹配里捕获分组写得有点乱，这里补一个更清晰的替代正则跑第二遍：
    while (s{
        ("\$(?:\{((?:[A-Za-z_][\w]*\.)*buildversion)\}|((?:[A-Za-z_][\w]*\.)*buildversion))")  # $1=whole, $2=$3=inner var
        \.(toInteger|toLong|toBigInteger)\(\)                                                    # $4=method
    }{
      my ($whole, $inner, $inner2, $meth) = ($1, $2, $3, $4);
      my $var = $inner || $inner2;
      ($var && is_bv_expr($var)) ? (wrap_bv($whole) . ".$meth()") : "$whole.$meth()";
    }gixe) {}

    # ---------- Group C: Integer.parseInt(EXPR) / Integer.valueOf / Long.parseLong / Long.valueOf ----------
    # 只改 EXPR 中含 buildversion 的那些调用（支持 GString、project.getProperty()、下标）
    while (s{
        (Integer|Long)\.(parseInt|parseLong|valueOf)\(
            \s*
            (
                # Case 1: 裸词或属性链 + 可选 .toString()
                (?:[A-Za-z_][\w]*\.)*buildversion(?:\.toString\(\))?
                |
                # Case 2: GString 字面量 "$buildversion" 或 "${xxx.buildversion}"
                "\$(?:\{(?:[A-Za-z_][\w]*\.)*buildversion\}|(?:[A-Za-z_][\w]*\.)*buildversion)"
                (?:\.toString\(\))?
                |
                # Case 3: project.getProperty("buildversion") / property("buildversion")
                [A-Za-z_][\w]*\.(?:getProperty|property)\(\s*["'"'"']buildversion["'"'"']\s*\)
                (?:\.toString\(\))?
                |
                # Case 4: project["buildversion"] / project['"'"'buildversion'"'"']
                [A-Za-z_][\w]*\[\s*["'"'"']buildversion["'"'"']\s*\]
                (?:\.toString\(\))?
            )
            \s*
        \)
    }{
      my ($cls, $mth, $arg) = ($1, $2, $3);
      is_bv_expr($arg) ? ("$cls.$mth(" . wrap_bv($arg) . ")") : "$cls.$mth($arg)";
    }gixe) {}

    # ---------- Group D: `EXPR as int` / `as Integer` / `as long` / `as Long` / `as BigInteger` ----------
    while (s{
        (?<!replaceAll\(")
        (
          (?:[A-Za-z_][\w]*\.)*                        # 可选前缀
          buildversion
          (?:\[[^\]]*\])?                               # 可选下标
          (?:\.toString\(\))?                           # 可选 .toString()
        )
        (\s+as\s+(?:int|Integer|long|Long|BigInteger)\b)
    }{
      my ($e, $cast) = ($1, $2);
      is_bv_expr($e) ? (wrap_bv($e) . $cast) : "$e$cast";
    }gixe) {}

    # ---------- Group E: `(int) EXPR` / `(Integer) EXPR` / `(long) EXPR` / `(Long) EXPR` ----------
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
  ' "$IOS_GRADLE"

  PATCHED_COUNT=$(grep -c 'replaceAll' "$IOS_GRADLE" 2>/dev/null || echo 0)
  echo "    (B.2) 小数版本兼容：成功注入 ${PATCHED_COUNT} 处 replaceAll 保护" >&2
  if [ "$PATCHED_COUNT" -eq 0 ]; then
    echo "    !! WARN: 未能命中任何已知整数转换模式！请人工核对上游 ios/build.gradle 的新版本写法。" >&2
    echo "    完整 ios/build.gradle 诊断（前 80 行）：" >&2
    sed -n '1,80p' "$IOS_GRADLE" >&2 || true
  fi
  # 关键行诊断：打印第 1~60 行，便于 CI 日志确认补丁位置（包含顶部注入 + 原 L20~40）
  echo "    --- ios/build.gradle L1~60 (诊断) ---" >&2
  sed -n '1,60p' "$IOS_GRADLE" >&2 || true
  echo "    ------------------------------------" >&2
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
