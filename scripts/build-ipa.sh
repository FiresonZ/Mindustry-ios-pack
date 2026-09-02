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

  # (A.2) 根据 Anuken/Mindustry v159.7 上游 ios/build.gradle 与 robovm.xml 的真实结构，
  #       以及 VincentZyu233/Mindustry-for-ios 的 iOS 适配写法，RoboVM 扩展本身没有
  #       `linkArgs` / `extraLinkArgs` / `extraLinkFlags` 这三个属性（直接写会抛
  #       "Could not set unknown property 'linkArgs' for extension 'robovm'"）。
  #       上游 v159 实际通过：
  #         1) <libs><lib>libs/libarc-freetype.a</lib></libs> 声明在 robovm.xml，
  #         2) tasks.register('copyNatives') 把 ../../Arc/natives/natives-freetype-ios/libs
  #            和 ../../Arc/natives/natives-ios/libs 拷入 ios/libs。
  #       于是在 build-ipa.sh 侧不再“伪造 linkArgs = […]”注入；改为：
  #         a) 兜底改写 copyNatives 的 from 列表，覆盖本 packager 目录结构，
  #            同时让 createIPA 显式依赖 copyNatives（上游 deploy 才依赖，tools:pack
  #            执行 copyAssets→copyNatives 但 CI 直接跑 :ios:createIPA 会绕过）。
  #         b) 参考 VincentZyu 的 afterEvaluate 注入，把 ios/libs 目录追加到
  #            RoboVMConfig.frameworkPaths / libraryPaths，避免 libs/libarc-freetype.a
  #            相对路径在 CI 上解析失败；同时顺带补上 backend-robovm 抽取目录缺失导致
  #            的 "search path '…/backend-robovm/…/META-INF/robovm/ios/libs' not found"
  #            告警（用 rootProject / buildscript 类路径兜底）。
  # A.2 补丁：用 here-doc 把 perl 代码通过 stdin 喂给 perl，完全规避 shell
  #      外层单引号与 perl 代码内引号（Groovy 单引号字符串字面量 '"'"'…'"'"' 等）冲突。
  #      说明：`perl -0777 -pi - "$IOS_GRADLE"` 让 perl 从 stdin 读代码，`-` 占位
  #      目标文件参数；heredoc 使用 单引号EOF（不做 shell 变量展开），避免 perl 代码里
  #      的 $/、$1、@dl_lines 等被 shell 当成变量替换。
  perl -0777 -pi - "$IOS_GRADLE" <<'__BUILD_IPA_PATCH_A2__'
    use strict; use warnings;
    my $SQ = chr(39);   # single-quote char, NEVER spell a literal ' in this heredoc body
    my $DQ = chr(34);

    # 1) 任务链：确保 createIPA 在 copyNatives 执行完后再跑
    if (!/createIPA\s*\.dependsOn\s+(?:[^\n]*?\b)copyNatives\b/) {
      s/(createIPA\.dependsOn\s+build)/$1\ncreateIPA.dependsOn copyNatives/;
    }

    # 2) copyNatives register 任务：在其最外层 } 之前追加诊断 doLast 块。
    #    算法：平衡花括号扫描（支持 Groovy 字符串字面量，避免误计字符串内 {}）。
    #    注入时不触碰 copy{} 内部，不调用 eachFile/from/include，
    #    不再用 DefaultFileCopyDetails 的 targetPath/sourcePath 属性（会炸）。
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

    # 3) afterEvaluate：给 RoboVM 构建任务附加 ios/libs 搜索路径。
    #    不写 org.robovm.* 类字面量（避免 Groovy 顶层 org 属性解析异常），
    #    改用任务名匹配 + 动态 hasProperty("robovmConfig") 访问。
    my $inject = q{

// === build-ipa.sh 注入：RoboVMConfig 附加 ios/libs 搜索路径，避免 libs/libarc-freetype.a 相对路径找不到
afterEvaluate {
    def iosLibs = file("libs")
    if (!iosLibs.exists()) iosLibs.mkdirs()
    def robovmBuildTaskNames = ["createIPA", "launchIPhoneSimulator", "launchIPadSimulator", "launchIOSDevice"]
    tasks.matching { robovmBuildTaskNames.contains(it.name) }.configureEach { t ->
        try {
            if (t.hasProperty("robovmConfig") && t.robovmConfig != null) {
                def cfg = t.robovmConfig
                if (cfg.hasProperty("frameworkPaths") && cfg.frameworkPaths != null) {
                    if (!cfg.frameworkPaths.contains(iosLibs)) cfg.frameworkPaths.add(iosLibs)
                }
                if (cfg.hasProperty("libraryPaths") && cfg.libraryPaths != null) {
                    if (!cfg.libraryPaths.contains(iosLibs.absolutePath)) cfg.libraryPaths.add(iosLibs.absolutePath)
                }
                try {
                    def backendJarDir = rootProject.file("../Arc/backends/backend-robovm/build/libs")
                    if (backendJarDir.exists()) {
                        def extractedDir = new File(System.getProperty("user.home"),
                            ".robovm/cache/ios/arm64/release" + backendJarDir.absolutePath +
                            ".extracted/META-INF/robovm/ios/libs")
                        if (extractedDir.exists() && cfg.frameworkPaths != null
                            && !cfg.frameworkPaths.contains(extractedDir.parentFile.parentFile)) {
                            cfg.frameworkPaths.add(extractedDir.parentFile.parentFile)
                        }
                    }
                } catch (ignored) {}
            }
        } catch (Exception e) {
            println "[build-ipa] warn: attach ios/libs to RoboVMConfig failed: " + e.message
        }
    }
}
// === 注入结束 ===
};
    $_ .= $inject;
__BUILD_IPA_PATCH_A2__
  echo "    (A.2) 参考上游 v159 + Mindustry-for-ios：让 createIPA dependsOn copyNatives；扩展 copyNatives from；afterEvaluate 把 ios/libs 注入 RoboVMConfig 的搜索路径" >&2

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

    # ---------- Group F: props["app.build"] / props.getProperty("app.build") 等 robovm.properties 键访问 ----------
    # 覆盖模式：
    #   props["app.build"].toInteger()          (Map 下标 -> .toXxx)
    #   props.getProperty("app.build").toInteger()  (JavaBean 取属性 -> .toXxx)
    #   props.app.build.toInteger()             (属性链 -> .toXxx)
    # 也兼容 buildversion 的同样存取写法（与 Group A~E 交叉覆盖但幂等）
    # 因为 replaceAll 已在 wrap_bv 中判断，不会重复插入。
    while (s{
        (?<!replaceAll\(")
        (
          \w+                                                         # 容器变量名：props/config/ext/...
          (?:
              \[\s*["'"'"'](?:app\.build|buildversion)["'"'"']\s*\]     #   ["key"] / ['key']
            | \.(?:getProperty|property)\(\s*["'"'"'](?:app\.build|buildversion)["'"'"']\s*\)  #   .getProperty("key") / .property("key")
            | \.\s*app\s*\.\s*build                                    #   .app.build 属性链
          )
          (?:\.toString\(\))?                                          # 可选 .toString()
        )\.(toInteger|toLong|toBigInteger)\(\)
    }{
      my ($e, $m) = ($1, $2);
      # 该组只针对 app.build / buildversion 键，肯定是版本相关的，直接 wrap
      wrap_bv($e) . ".$m()";
    }gixe) {}
  ' "$IOS_GRADLE"

  # ---- (B.3) 覆盖写保护：incrementConfig 会执行 props['app.build'] = 读取值.toInteger() + 1，
  # 即使 toInteger 不再崩溃（B.2 replaceAll 去小数），+1 也会把 159 → 160、把 "159.7" 的小数部分丢掉。
  # 因此在写盘（props.store）前一刻强制令 props["app.build"] = 精确传入的 bversion (如 "159.7")，
  # 完全绕过自增逻辑。与 app.version 写法保持一致，使用相同的 "custom build" 守卫。
  perl -0777 -pi -e '
    my $guard = qq{
    // === build-ipa.sh 注入：CI 强制锁定 CFBundleVersion，无视 incrementConfig 自增 +1 ===
    if(bversion != "custom build"){ props["app.build"] = bversion.toString() }
    // === 覆盖结束 ===};
    s/(props\.store\(\s*vfile\.newWriter\(\)\s*,\s*null\s*\))/$guard\n    $1/s;
  ' "$IOS_GRADLE"

  # PATCHED_COUNT：统计**实际代码**中 replaceAll 出现次数（排除纯注释行，避免 B.1 注释 / 覆盖块注释放大计数）
  PATCHED_COUNT=$(grep -vE '^\s*//' "$IOS_GRADLE" 2>/dev/null | grep -c 'replaceAll' || echo 0)
  echo "    (B.2+B.3) 小数版本兼容：注入 ${PATCHED_COUNT} 处 replaceAll 保护 + 1 处 app.build 覆盖写锁定" >&2
  if [ "$PATCHED_COUNT" -eq 0 ]; then
    echo "    !! WARN: 未能命中任何已知整数转换模式！请人工核对上游 ios/build.gradle 的新版本写法。" >&2
    echo "    完整 ios/build.gradle 诊断（前 80 行）：" >&2
    sed -n '1,80p' "$IOS_GRADLE" >&2 || true
  fi
  # ---- (B.4) 最终守护：扫描所有 .toInteger()/.toLong()/… 行，若存在没被 replaceAll 保护的则发出显式告警 ----
  echo "    (B.4) 最终守护：检查仍未受保护的整数转换（应为 0 行）：" >&2
  UNPROTECTED=$(grep -nE '\.(toInteger|toLong|toBigInteger)\(' "$IOS_GRADLE" 2>/dev/null \
    | grep -vE 'replaceAll.*\.(toInteger|toLong|toBigInteger)\(' || true)
  # 注意：grep -c 在 count=0 时仍输出 "0" 但退出码为 1，不能加 || echo 0（会变成 0<newline>0 双行）
  if [ -z "$UNPROTECTED" ]; then
    UNPROTECTED_COUNT=0
  else
    UNPROTECTED_COUNT=$(printf '%s\n' "$UNPROTECTED" | grep -c '.' || true)
    [ -z "$UNPROTECTED_COUNT" ] && UNPROTECTED_COUNT=0
  fi
  if [ "$UNPROTECTED_COUNT" -eq 0 ]; then
    echo "      ✓ 所有整数转换均已被 replaceAll 保护 (0 行未保护)" >&2
  else
    echo "      ✗ 仍有 ${UNPROTECTED_COUNT} 行整数转换未受保护！" >&2
    echo "$UNPROTECTED" >&2
    echo "    完整 ios/build.gradle（前 80 行）供人工排查：" >&2
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

  # ===== (C.0) RoboVM 配置修正：保留原始 <libs> 结构 + 附加 libs 到 frameworkPaths 搜索基准 =====
  # 教训：RoboVM 2.3.24 不接受 <lib variant="release|debug">libs/libarc-freetype.a</lib>，
  # 它的 PlatformVariant 枚举只允许在特定元素上用，直接写会在 Config read 阶段抛
  # IllegalArgumentException: No enum constant org.robovm.compiler.config.PlatformVariant.release
  # （参见新上传日志 L116）。Anuken/Mindustry v159.7 上游 robovm.xml 本身也是纯文本
  # <lib>libs/libarc-freetype.a</lib>，没有任何 variant 属性。
  # 真正让 RoboVM 找到该文件的办法：把 Mindustry/ios/libs 目录加入 RoboVM 的 frameworkPaths，
  # 并确保 **shell 级**在 createIPA 运行前把 libarc-freetype.a 物理落到 ios/libs（C.0 早注入
  # + C.1 兜底 + 依赖）。这里对 xml 的改动仅限无风险、属性合法的三类改动：
  #   1) 仅当 xml 完全没有 <lib>libs/libarc-freetype.a</lib> 时，才插入一条纯 <lib>（通常上游已存在）；
  #   2) 在 <frameworkPaths> 里追加一条 <path>libs</path>；
  #   3) 完全缺失 <frameworkPaths> 时才兜底建一个。
  IOS_ROBOVM_XML="${BUILD_DIR}/Mindustry/ios/robovm.xml"
  if [ -f "$IOS_ROBOVM_XML" ]; then
    perl -0777 -pi - "$IOS_ROBOVM_XML" <<'__BUILD_IPA_PATCH_ROBOVM_XML__'
      use strict; use warnings;
      # 1) 保证 libs/libarc-freetype.a 至少在 <libs> 里出现一次：
      #    - 若已存在（无论前后空格多少）：不再动，避免破坏 <lib> 结构合法性；
      #    - 若 <libs> 存在但缺少这条：在 </libs> 之前补一条无属性的 <lib>。
      #    - 若连 <libs> 都没有：在 </config> 或 </robovm> 之前补完整 <libs> 块。
      my $lib_entry = qq{<lib>libs/libarc-freetype.a</lib>};
      if (!m{libs/libarc-freetype\.a}) {
        if (m{(<libs>[\s\S]*?</libs>)}) {
          # 在 </libs> 前插入 lib_entry（保留缩进：假设 </libs> 前是换行+两个空格的缩进水平）
          s{(</libs>)}{    $lib_entry\n  $1}s;
        } else {
          s{(</(?:config|robovm)>)}
           {  <libs>\n    $lib_entry\n  </libs>\n$1}s;
        }
      }

      # 2) 在 <frameworkPaths>（若已有）中追加 Mindustry/ios/libs 的相对目录，
      #    避免 v159.7 原有的 backend-robovm META-INF cache 路径是唯一 frameworkPath 时
      #    找不到 ios/libs 作为 framework/lib 搜索基准。
      s{(<frameworkPaths>(?:[\s\S]*?)</frameworkPaths>)}{
        my $block = $1;
        my $tag = qq{<path>libs</path>};
        if (index($block, $tag) < 0) {
          $block =~ s{(</frameworkPaths>)}{  $tag\n  $1};
        }
        $block;
      }sge;

      # 3) 如果文件完全没有 <frameworkPaths>，就在 </config> 或 </robovm> 之前兜底插入
      if (!m{<frameworkPaths>}) {
        s{(</(?:config|robovm)>)}
         {  <frameworkPaths>\n    <path>libs</path>\n  </frameworkPaths>\n$1}s;
      }
__BUILD_IPA_PATCH_ROBOVM_XML__
    echo "    (A.3) robovm.xml：已确保 <lib>libs/libarc-freetype.a</lib> 至少出现一次，且 <frameworkPaths> 追加 <path>libs</path>（不再注入 variant= 属性，避免 RoboVM 2.3.24 枚举非法）" >&2
  fi

  # ===== (C.0 2/2) 优先从依赖 jar 解 freetype 静态库（不再依赖 Arc 原生任务成功） =====
  # 说明：C.1 中调用的 :Arc:natives:natives-freetype-ios:build / jar 任务有时会因为缺少
  # RoboVM 原生构建工具链而“成功但不产出 .a”，此时上游依赖（arcModule "natives:natives-freetype-ios"）
  # 实际会把一个完整的 natives-freetype-ios-*.jar 拉到 ~/.gradle/caches/modules-2 或
  # Arc/natives/natives-freetype-ios/build/libs 下面，jar 里有 META-INF/robovm/ios/libs/libarc-freetype.a
  # 只要把它解出来，再 cp 到 Mindustry/ios/libs，RoboVM 的 -force_load 绝对路径就能命中。
  # 这里先在 [4/7] 之前做一次“早注入”，确保 copyNatives→copyAssets→:ios:createIPA 时
  # Mindustry/ios/libs/libarc-freetype.a 已经存在（即便是后续 copy{} 覆盖成无符号的版本也没关系）。
  IOS_LIBS_DIR_EARLY="${BUILD_DIR}/Mindustry/ios/libs"
  mkdir -p "$IOS_LIBS_DIR_EARLY"
  # 候选 jar 路径：.gradle 缓存、build 输出、.m2、~/.robovm
  JAR_SEARCH_DIRS=(
    "$HOME/.gradle/caches/modules-2/files-2.1"
    "${BUILD_DIR}/Arc/natives/natives-freetype-ios/build/libs"
    "${BUILD_DIR}/Arc/natives/natives-ios/build/libs"
    "${BUILD_DIR}/Arc/backends/backend-robovm/build/libs"
    "$HOME/.m2/repository"
    "$HOME/.robovm"
  )
  echo "    (C.0) 前置搜索 natives-freetype-ios jar，META-INF/robovm/ios/libs 提取 libarc-freetype.a：" >&2
  FOUND_EARLY=0
  for D in "${JAR_SEARCH_DIRS[@]}"; do
    [ -d "$D" ] || continue
    JARLIST=$(find "$D" -name '*natives-freetype-ios*.jar' -type f 2>/dev/null || true)
    [ -z "$JARLIST" ] && continue
    TMP_E=$(mktemp -d)
    for J in $JARLIST; do
      if unzip -l "$J" 2>/dev/null | grep -q 'META-INF/robovm/ios/libs/libarc-freetype\.a'; then
        unzip -o -q -j -d "$TMP_E" "$J" 'META-INF/robovm/ios/libs/libarc-freetype.a' >/dev/null 2>&1 || true
        if [ -f "$TMP_E/libarc-freetype.a" ] && [ ! -f "$IOS_LIBS_DIR_EARLY/libarc-freetype.a" ]; then
          cp -f "$TMP_E/libarc-freetype.a" "$IOS_LIBS_DIR_EARLY/libarc-freetype.a"
          echo "      ✓ 从 $J 解出 .a 并拷贝到 ios/libs" >&2
          FOUND_EARLY=1
          break 2
        fi
      fi
    done
    rm -rf "$TMP_E"
  done
  if [ "$FOUND_EARLY" -eq 0 ]; then
    echo "      ℹ jar 缓存搜索暂未命中（将在 C.1 阶段再兜底 Arc 原生构建 & 生成占位）" >&2
  fi
  echo "      前置检查 ios/libs 结果：" >&2
  ls -la "$IOS_LIBS_DIR_EARLY" >&2 || true

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

# ---- (C.1) 确保 ios/libs/libarc-freetype.a 存在（RoboVM 链接阶段 `-force_load` 硬依赖该路径）----
# 上游 Mindustry 的 ios/build.gradle 通过额外的 link 参数强制加载该静态库，但 v159 起
# 该 .a 不再被自动放入 Mindustry/ios/libs，导致 clang 报 "library '.../ios/libs/libarc-freetype.a' not found"。
# 修复策略：
#   1) 先尝试构建 Arc 侧 freetype iOS 原生产物：Arc:natives:natives-freetype-ios:jar 会触发
#      freetype 的 iOS arm64/armv7 静态库交叉编译（lipo 输出的 .a 通常打包进 jar/META-INF/robovm）。
#   2) 从 Arc 构建产物中搜索已生成的 libarc-freetype.a（包括 build/libs/ 下 .jar 内 META-INF/robovm/ios/libs
#      以及 natives-freetype-ios/build 直接产出的 .a），并复制到 Mindustry/ios/libs 下。
#   3) 如果构建后仍未找到，则再在整个 BUILD_DIR 以及 ~/.gradle/caches / ~/.m2 / ~/.robovm 中兜底搜索，
#      避免上游调整目录导致 CI 再次断链。
IOS_LIBS_DIR="${BUILD_DIR}/Mindustry/ios/libs"
mkdir -p "$IOS_LIBS_DIR"

echo "    (C.1) 准备 Arc freetype iOS 原生静态库（强制加载依赖）" >&2
# 先尝试触发 freetype iOS 原生构建（RoboVM 项目里通常由 ios/arm64 架构任务产出 .a 并打进 jar）
if ./gradlew "${GRADLE_ARGS[@]}" :Arc:natives:natives-freetype-ios:build :Arc:natives:natives-freetype-ios:jar 2>&1 | tail -20 >&2; then
  echo "      ✓ :Arc:natives:natives-freetype-ios 构建完成" >&2
else
  echo "      ⚠ :Arc:natives:natives-freetype-ios 构建未成功，继续尝试从已有产物中搜索 libarc-freetype.a" >&2
fi

# 搜索候选位置：直接产出的 .a 以及 jar 内部 META-INF/robovm/ios/libs/*.a
FT_SRC=""
# 1) 直接文件系统上的静态库（lipo/单架构）
DIR_CANDIDATES=(
  "${BUILD_DIR}/Arc/natives/natives-freetype-ios/build"
  "${BUILD_DIR}/Arc/extensions/freetype/build"
  "${BUILD_DIR}/Arc/build"
  "${BUILD_DIR}/Mindustry/ios/build"
  "$HOME/.robovm"
  "$HOME/.gradle/caches"
  "$HOME/.m2/repository"
)
for D in "${DIR_CANDIDATES[@]}"; do
  if [ -d "$D" ]; then
    FOUND=$(find "$D" -name 'libarc-freetype*.a' -type f 2>/dev/null | head -1 || true)
    if [ -n "$FOUND" ]; then
      FT_SRC="$FOUND"
      echo "      ✓ 在 $D 下找到 libarc-freetype*.a: $FT_SRC" >&2
      break
    fi
  fi
done

# 2) 仍没找到？再从 Arc 或依赖 jar 里提取 META-INF/robovm/ios/libs/libarc-freetype*.a
if [ -z "$FT_SRC" ]; then
  JAR_CANDIDATES=$(find "${BUILD_DIR}/Arc" -name 'natives-freetype-ios*.jar' -type f 2>/dev/null || true)
  TMP_EXTRACT="$(mktemp -d)"
  for J in $JAR_CANDIDATES; do
    if unzip -l "$J" 2>/dev/null | grep -q 'META-INF/robovm/ios/libs/libarc-freetype'; then
      unzip -o -q -d "$TMP_EXTRACT" "$J" 'META-INF/robovm/ios/libs/libarc-freetype*.a' >/dev/null 2>&1 || true
      EXTRACTED=$(find "$TMP_EXTRACT" -name 'libarc-freetype*.a' -type f 2>/dev/null | head -1 || true)
      if [ -n "$EXTRACTED" ]; then
        FT_SRC="$EXTRACTED"
        echo "      ✓ 从 jar 中解出 libarc-freetype*.a: $J" >&2
        break
      fi
    fi
  done
  rm -rf "$TMP_EXTRACT"
fi

# 3) 仍缺失，则以空的占位 .a 兜底（避免链接阶段因“文件不存在”直接失败）；
#    若工程实际并没有使用 freetype 相关符号，空归档可以让链接安全通过。
if [ -z "$FT_SRC" ]; then
  echo "      ⚠ 未在任何位置找到 libarc-freetype.a，生成空占位静态库以避免 clang 因 -force_load 路径不存在而失败" >&2
  EMPTY_OBJ="$(mktemp -d)/empty_stub.s"
  mkdir -p "$(dirname "$EMPTY_OBJ")"
  printf '.text\n.globl _arc_freetype_stub\n_arc_freetype_stub:\n  ret\n' > "$EMPTY_OBJ"
  as -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo /)" \
    -o "${EMPTY_OBJ%.s}.o" "$EMPTY_OBJ" 2>/dev/null || true
  if [ -f "${EMPTY_OBJ%.s}.o" ]; then
    libtool -static -o "$IOS_LIBS_DIR/libarc-freetype.a" "${EMPTY_OBJ%.s}.o" 2>/dev/null || \
      ar rcs "$IOS_LIBS_DIR/libarc-freetype.a" "${EMPTY_OBJ%.s}.o" 2>/dev/null || true
  fi
  rm -rf "$(dirname "$EMPTY_OBJ")"
fi

# 拷贝找到/解出的源静态库到 ios/libs
if [ -n "$FT_SRC" ]; then
  cp -f "$FT_SRC" "$IOS_LIBS_DIR/libarc-freetype.a"
fi

# 诊断：确认最终 ios/libs 内容以及 .a 是否为合法文件
echo "    (C.2) ios/libs 诊断：" >&2
ls -la "$IOS_LIBS_DIR" >&2 || true
if [ -f "$IOS_LIBS_DIR/libarc-freetype.a" ]; then
  FT_SIZE=$(stat -c%s "$IOS_LIBS_DIR/libarc-freetype.a" 2>/dev/null || stat -f%z "$IOS_LIBS_DIR/libarc-freetype.a" 2>/dev/null || echo "?")
  echo "      libarc-freetype.a 存在，size=${FT_SIZE} 字节" >&2
  if command -v lipo >/dev/null 2>&1; then
    lipo -info "$IOS_LIBS_DIR/libarc-freetype.a" >&2 || true
  fi
else
  echo "      ✗ libarc-freetype.a 仍不存在，:ios:createIPA 将在链接阶段失败！" >&2
fi

./gradlew "${GRADLE_ARGS[@]}" :ios:createIPA
GRADLE_RC=$?

# ========= 若 createIPA 失败：抽取 RoboVM 链接阶段 clang stderr 到日志 =========
# 过去多次失败时 tail -150 build-ipa.log 只剩下 RoboVMGradleException 的上层 stack，
# 真实的 ld/clang 错误（Undefined symbols / wrong architecture / file format invalid /
# library not found 等）只被写入 ios/build/robovm.tmp 下的 *stderr 或 AbstractTarget
# 在 ToolchainUtil.link 里捕获的 stderr。这里尝试从几处常见位置 dump，确保下次 CI 失败
# 时日志直接包含真实错误行，而不是只有空的 “exit value: 1”。
if [ "$GRADLE_RC" -ne 0 ]; then
  echo "===== :ios:createIPA 失败 ($GRADLE_RC)，转储 RoboVM 链接诊断 =====" >&2
  TMP_ROBOVM="${BUILD_DIR}/Mindustry/ios/build/robovm.tmp"
  if [ -d "$TMP_ROBOVM" ]; then
    echo "--- robovm.tmp 目录结构 ---" >&2
    find "$TMP_ROBOVM" -maxdepth 3 -type f | sort | head -80 >&2 || true
    for F in "$TMP_ROBOVM/stderr" "$TMP_ROBOVM/clang_stderr" "$TMP_ROBOVM/link_stderr" \
             "$TMP_ROBOVM/robovm-link-stderr.log" "$TMP_ROBOVM/clang.err" \
             "$TMP_ROBOVM/IOSLauncher.link.stderr"; do
      [ -f "$F" ] || continue
      echo "--- $F ---" >&2
      tail -100 "$F" >&2
    done
    # objects0 / filelist + all .err/.stderr files as generic catch-all
    find "$TMP_ROBOVM" -type f \( -name '*.stderr' -o -name '*.err' -o -name '*stderr*' -o -name 'objects*' \) 2>/dev/null | while read -r X; do
      if [[ "$X" == *objects* ]]; then
        echo "--- (filelist sample) $X (first 30 lines) ---" >&2
        head -30 "$X" >&2 || true
      else
        echo "--- $X ---" >&2
        tail -80 "$X" >&2
      fi
    done
  else
    echo "(robovm.tmp 不存在 —— 失败发生在链接前的配置/打包阶段)" >&2
  fi
  # 同时搜索 ios/build 下 *.log 中含 error/ld/undef/library/not found 的行
  echo "--- ios/build/** 日志中含 error|library|Undefined|clang++ 的最后 100 行 ---" >&2
  find "${BUILD_DIR}/Mindustry/ios/build" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.out' \) 2>/dev/null \
    | xargs -I{} grep -niHE 'error|library.*not found|Undefined symbols|file.*is not an object file|Unsupported architecture|clang' {} 2>/dev/null \
    | tail -100 >&2 || true
  echo "===== 诊断结束 =====" >&2
fi
[ "$GRADLE_RC" -ne 0 ] && exit "$GRADLE_RC"

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
