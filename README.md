# Mindustry iOS IPA 自动打包（未签名版）

盯着 Anuken/Mindustry 的 Releases，自动拉 tag 源码出 iOS IPA。固定**未签名**输出，省掉证书 / 描述文件 / 签名链路的复杂度。源码版本严格对齐上游 tag，跟 App Store 显示的 `8.<build>.0` 保持一致。

- 每 6 小时定时检测（UTC 00:17 / 06:17 / 12:17 / 18:17），也可手动触发
- 成功构建的 tag 写回 `LAST_VERSION`，下轮自动跳过，不重复占用 macOS runner
- 产物同时发 Artifacts（保留 90 天）+ GitHub Release（tag `ios-v<构建号>`）

协议：GPLv3（同上游 Mindustry），见 [`LICENSE`](./LICENSE)。

---

## 触发构建 & 获取产物

**触发方式（二选一）：**

| 方式 | 怎么用 |
|---|---|
| 自动 | 什么都不用做；schedule 每 6h 查 Anuken/Mindustry 最新 release，比 `LAST_VERSION` 新就出包 |
| 手动 | Actions → `Mindustry iOS IPA Auto Build` → Run workflow：<br>• `build_version`：如 `146`（会严格校验 `v146` tag 在 Anuken/Mindustry 存在，不存在立即终止）；留空=用最新 release<br>• `force_build`：勾选则无视 `LAST_VERSION`，强制重打 |

**产物位置：**

- Artifacts：Actions → 对应 Run → Artifacts → `Mindustry-iOS-v<tag>`
- Release：仓库 Releases（仅在 schedule 或非 force 手动时创建），tag `ios-v<构建号>`

---

## 版本号规则（严格对齐上游）

核心：**按上游 tag 拉源码，tag 不存在直接失败**，保证包内容和 App Store 版一致。

| 项目 | 例子 | 来源 |
|---|---|---|
| Anuken/Mindustry release tag | `v146` / `v159.7` | GitHub `releases/latest` API |
| clone ref | `refs/tags/v146` | `--depth 1 --branch v146` |
| BUILD_VERSION（内部构建号） | `146` / `159.7` | tag 去掉 `v` |
| CFBundleShortVersionString | `8.146.0` / `8.159.7` | `8.<BUILD_VERSION>` 整数补 `.0`，小数直连 |
| CFBundleVersion | `146` / `159.7` | 等于 BUILD_VERSION（小数版本保持原样） |
| IPA 文件名 | `Mindustry-iOS-v146_8.146.0.ipa` | 输出到 `dist/` |

小数版本号兼容（如 v159.7）通过在 `ios/build.gradle` 顶部注入 `_stripDec_bv` 裁剪整数 + `replaceAll` 保护 `.toInteger()` 调用实现，避免 Gradle 抛 `NumberFormatException`。

---

## 仓库结构

```
/
├── .github/workflows/ios-ipa-build.yml    CI：check-version → build-ipa → bump & release → LAST_VERSION 回写
├── scripts/
│   ├── check-version.sh                   查最新 tag / 对比 LAST_VERSION / 输出 NEEDS_BUILD、RELEASE_TAG 等
│   ├── build-ipa.sh                       clone Mindustry+Arc、补丁 build.gradle 与 robovm.xml、解 MetalANGLEKit、执行 ios:incrementConfig + ios:deploy
│   └── bump-last-version.sh               构建成功后写 LAST_VERSION（含注释头）；不做 git commit，交给 workflow 统一 push
├── LAST_VERSION                           上次成功构建的 tag，如 `v159.7`（# 行为注释，脚本自动跳过）
├── LICENSE                                GPLv3
└── README.md
```

---

## CI 流程

```
                ┌──────────────────┐
                │ check-version    │ ubuntu-22.04
                │  - 查最新 release │
                │  - 读 LAST_VERSION│
                │  - NEEDS_BUILD?   │
                └────────┬─────────┘
                         │ true
                         ▼
                ┌──────────────────┐
                │ build-ipa        │ macos-14 (Xcode 15 / JDK 17)
                │  - git clone 源码 │
                │  - 小数版本兼容补丁│
                │  - iosSkipSigning │
                │  - robovm.xml 修正│
                │  - ios:deploy ✅  │
                │  - upload IPA     │
                │  - create Release │
                └────────┬─────────┘
                         │ success
                         ▼
                ┌──────────────────┐
                │ bump-last-version│
                │  - 写 LAST_VERSION│
                │  - git push 回仓库│ (依赖 contents:write 权限)
                └──────────────────┘
```

关键补丁点都在 `scripts/build-ipa.sh`：

1. **小数构建号兼容**（A/B 阶段）：在 `ios/build.gradle` 注入 `_stripDec_bv` 辅助函数 + 替换 `.toInteger()` 为 `.replaceAll("\\..*","").toInteger()`，锁定 `app.build=BUILD_VERSION`。
2. **签名跳过**（A 阶段）：`iosSkipSigning=true`，不走 p12 / mobileprovision / codesign。
3. **robovm.xml 修正**（A.3）：
   - 剥离 `<framework>arc</framework>`（arc.framework 不存在，RoboVM/Arc/MetalANGLEKit 任何位置都找不到，Xcode 15 ld 视为硬错误）
   - frameworkPaths 只保留 `<path>libs</path>`，删除未解析的 `${user.home}/.m2/.../arm64` 无效路径
   - 确保 `MetalANGLEKit`、`libGLESv2`、`libEGL`、`libfeature_support` 等 11 个 framework 声明齐全
4. **MetalANGLEKit + freetype 静态库**（C 阶段）：镜像解压到 `ios/libs`，XCFramework 由 RoboVM ResolvedLocations 自动展开；`libarc-freetype.a` 优先从 Arc 物理目录 cp，兜底从依赖 jar 的 `META-INF/robovm/ios/libs` 解。
5. **`-PnoLocalArc`**：禁用 Gradle 复合构建的 `includeBuild("../Arc")`，避免 `:Arc:*` 任务在 `DefaultIncludedBuildTaskGraph` 上报「未知子项目」。

---

## LAST_VERSION 机制

`LAST_VERSION` 保存**上次成功出包的上游 tag**，跨 run 同时依赖两处同步：

| 位置 | 作用 | 更新时机 |
|---|---|---|
| 文件 `LAST_VERSION`（git 仓库） | 跨 workflows 的永久状态 | 构建成功后 workflow 步骤 `Commit & Push LAST_VERSION` 推送 |
| Actions Cache `mindustry-ios-last-version-*` | 同一 repo 内快速恢复 | `cache/save` 步骤在构建成功后写入 |

CI 读取顺序：先 restore cache → 读文件（grep 跳过 `#` 注释行）→ 对比上游 tag。想强制重打：删仓库里的 `LAST_VERSION` 并清 `mindustry-ios-last-version-*` 缓存，再手动触发 + force_build。

---

## 本地运行

需要 macOS 13+、Xcode 14+ CLI Tools、JDK 17。不需要证书。

```bash
# 构建 IPA
BUILD_VERSION=159.7 ./scripts/build-ipa.sh
# 产物：dist/Mindustry-iOS-v159.7_8.159.7.ipa  +  *.meta.txt

# 只查版本，不构建
./scripts/check-version.sh
```

---

## 常见问题

**Q1：为什么非得按 tag 拉源码，不用 master？**
Anuken 自己的 Deployment CI 是 tag push 才出正式包。按 tag 拉能保证 build 号、资源包内容跟 App Store 上的发行版严格一致。tag 不存在直接红 X，不会混着不稳定中间态出包。

**Q2：robovm.xml 里为啥要删 `<framework>arc</framework>`？**
`arc.framework` 不存在于任何依赖位置（robovm-dist / Arc 仓库 / MetalANGLEKit zip / backend-robovm jar）。Arc 引擎以 Java 字节码经 classpath 链接，不是 iOS framework，上游声明为遗留。Xcode 15.4 ld 将「framework not found」视为硬错误，必须主动剥离。

**Q3：`${user.home}` 在 frameworkPaths 里为啥不行？**
RoboVM 2.3.24 `PlatformFilter(SystemFilter)` 理论上能解析 `${user.home}`，但实测传给 clang `-F` 的是字面 `${user.home}`（未展开）。且该目录只含 `.a` 静态库、无 `.framework`，即使解析成功也无用。

**Q4：`-PnoLocalArc` 为什么必须开？**
参考仓库 VincentZyu233/Mindustry-for-ios 同样使用该参数：禁用复合构建 `includeBuild("../Arc")` 后，就不能再调用 `:Arc:natives:*` 任务（否则 `DefaultIncludedBuildTaskGraph` 报未知子项目）。本工程改为纯文件系统 cp + jar 解压方式获取 `libarc-freetype.a`。

---

## 协议 & 衍生

```
Mindustry iOS IPA Packager  Copyright (C) 2026
GPLv3 — 本程序按"原样"发布，不提供任何担保。详见 LICENSE。
```

上游引用：
- Mindustry：[`Anuken/Mindustry`](https://github.com/Anuken/Mindustry) · **GPLv3** · Author: Anuken
- iOS 后端：[`MobiVM/robovm`](https://github.com/MobiVM/robovm) 2.3.x
- JDK：Temurin 17

本项目不修改游戏源码，只在构建时按上游 tag clone；构建元数据 `*.meta.txt` 记录了上游 tag 与 commit hash，可据此复现源码版本，满足 GPLv3 分发衍生作品时源码追溯要求。
