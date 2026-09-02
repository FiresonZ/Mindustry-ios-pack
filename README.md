# Mindustry iOS IPA 自动打包（未签名版 · TrollStore 直装）

<p align="center">
  <!-- 访问统计：count.getloli.com -->
  <img src="https://count.getloli.com/get/@:mindustry-ios-pack?theme=rule34" alt="访问量" />
</p>

盯着 Anuken/Mindustry 的 Releases，自动拉 tag 源码出 iOS IPA，**不用苹果开发者账号、不用证书、不用描述文件**，装好 TrollStore 往设备里扔就能玩。源码版本号跟 App Store 那套对齐（`8.<build>.0`），不会打包出奇奇怪怪的版本。

- 定时（每 6 小时）检测上游新 release，发现新版本就在 macos-14 上跑 RoboVM 打包
- 固定未签名，省掉证书那一大坨流程和 secret 配置
- 成功打包的版本写回 `LAST_VERSION`，下次就跳过，不会重复构建
- 产物同时出现在 Actions Artifacts 和 GitHub Release，你哪里方便从哪里下

> 协议：GPLv3，和上游 Mindustry 一致，详情见 [`LICENSE`](./LICENSE)。

---

## 开始用（2 步搞定）

**1. 触发构建**

两种，二选一：

- **自动**：什么都不用点，每 6 小时 UTC 的 00:17 / 06:17 / 12:17 / 18:17 自动查 Anuken/Mindustry 最新 release，比 `LAST_VERSION` 新就出包。
- **手动**：Actions → 选中 `Mindustry iOS IPA Auto Build (Unsigned / TrollStore)` → Run workflow：
  - `build_version`：填数字，比如 `146`（会严格校验 tag `v146` 在 Anuken/Mindustry 是否存在，不存在直接停）。留空 = 自动用最新 release。
  - `force_build`：勾上就无视 `LAST_VERSION`，强制再打一遍。

**2. 拿 IPA 装到手机**

构建结束后：

- Artifacts（每个 Run 单独一份，保留 90 天）：Actions → 点进去那个 Run → Artifacts 里下 `Mindustry-iOS-v<tag>`。
- Release Assets（只在定时触发 / 非 force 的手动触发时生成）：仓库首页 → Releases，tag 名是 `ios-v<构建号>`，里面有 `.ipa` 和对应的 `.meta.txt`。

安装方式推荐和步骤看下面「怎么把 IPA 装进手机」。

---

## 版本号对应关系（关键）

就一条铁则：**严格跟着上游 tag**，这样你打出来的 IPA 跟 App Store 显示的版本号对得上，不会出现「我明明下的是最新版，设置里显示 build=0」这种破事。

| 项目 | 例子 | 怎么来的 |
| --- | --- | --- |
| Anuken/Mindustry 的 release tag | `v146` | GitHub releases/latest |
| 实际 clone 的 ref | `refs/tags/v146` | 用 `--depth 1 --branch v146` 拉，tag 不存在直接报错 |
| Gradle 构建号 `-Pbuildversion` | `146` | tag 去掉前面 `v` |
| `version.properties#number` | `8` | 上游 `build.gradle` 里写死的 `versionNumber = '8'` |
| `CFBundleShortVersionString`（App Store 显示版本） | `8.146.0` | `ios/robovm.properties` 写入，格式 `8.<build>.0` |
| `CFBundleVersion`（内部构建号） | `146` | 同上 |
| IPA 文件名 | `Mindustry-iOS-v146_8.146.0.ipa` | 脚本重命名输出到 `dist/` |

> 手动指定了 `build_version` 但上游没那个 tag？工作流第一阶段直接红 X 停掉，**不会随便打包非官方版本**。

### 可选：顺手对一下 App Store 显示的版本

在 [`.github/workflows/ios-ipa-build.yml`](.github/workflows/ios-ipa-build.yml) 里把 `check-version` 那步的 `CHECK_APPSTORE=true` 加上，就会调 iTunes Lookup API 对比 `io.anuke.mindustry` 的版本，不一致打个 WARN 日志，不会中断构建。

---

## 仓库里都有啥

```
/
├── .github/workflows/ios-ipa-build.yml    Actions：定时/手动 → 检查版本 → 出 IPA → 发 Release → 回写 LAST_VERSION
├── scripts/
│   ├── check-version.sh                   查 Anuken/Mindustry 最新 tag，对比 LAST_VERSION，输出 NEEDS_BUILD
│   ├── build-ipa.sh                       拉源码 / 拉 Arc / 写 robovm.properties / tools:pack / core:preGen / createIPA
│   └── bump-last-version.sh               构建成功后把 tag 写回 LAST_VERSION
├── Mindustry/                             Git 子模块，上游源码的锚点（构建时实际按 release tag 重新 clone）
├── LAST_VERSION                           上一次成功构建过的 tag，如 `v146`
├── LICENSE                                GPLv3
├── .gitignore                             build-root/、dist/、*.log、临时 keychain、证书文件
└── README.md                              项目说明文档
```

---

## 怎么把 IPA 装进手机

出来的 IPA 是**未签名**的，不能双击用 iTunes / Finder 装。三种路：

### TrollStore（最省心，推荐）

- 适用系统：iOS 14 ~ 16.6.1（具体机型和能装的最高版本以 [TrollStore 官方 repo](https://github.com/opa334/TrollStore) 为准）
- 步骤：
  1. 按官方文档把 TrollStore 装到你的设备上；
  2. 在 Artifacts / Release 里下好 `Mindustry-iOS-*.ipa`；
  3. 用 TrollStore 打开这个 IPA → Install → 桌面图标出现就完事了。
- 优点：永久签，不用每 7 天续签；不用任何 Apple ID。

### AltStore / Sideloadly

- **AltStore**：装 AltServer → 电脑上把 IPA 塞进去 AltStore → 每 7 天要和电脑同一 Wi-Fi 自动续签（免费 Apple ID）。
- **Sideloadly**：图形界面，免费 Apple ID 同样 7 天一签；买了 Apple 开发者账号就是 1 年一签。

### 问：为啥不直接传 TestFlight / App Store

TestFlight / App Store Connect 必须走苹果证书上架流程，本仓库就想做到「零开发者账号也能拿到能玩的 IPA」，所以直接省略那条路。真要传的话，苹果那边买账号先，本仓库代码也能改，见 FAQ 最后一条。

---

## 自己在本地跑一遍（macOS）

前提：macOS 13 以上、Xcode 14 + Command Line Tools、JDK 17（Temurin 就行）。不需要任何证书 / 描述文件。

```bash
# 直接在仓库根目录跑
BUILD_VERSION=146 ./scripts/build-ipa.sh
```

产出在 `dist/`：

```
dist/Mindustry-iOS-v146_8.146.0.ipa          未签名 IPA，TrollStore 直接装
dist/Mindustry-iOS-v146_8.146.0.ipa.meta.txt 构建元数据（上游 commit hash、Xcode/JDK 版本、签名状态等）
```

只想看看有没有新版本，不真的打包：

```bash
./scripts/check-version.sh
# 输出类似：
# RELEASE_TAG=v146
# BUILD_VERSION=146
# APP_STORE_VERSION=8.146.0
# NEEDS_BUILD=true

# 或者顺手对比下 App Store：
CHECK_APPSTORE=true APPSTORE_BUNDLE_ID=io.anuke.mindustry ./scripts/check-version.sh
```

---

## LAST_VERSION 是干啥的

`LAST_VERSION` 文件记的是**上一次成功出包的上游 tag**。工作流跑之前会对比它，一样就直接跳过，省掉 macos runner 时间。

更新链条是这样：

```
每 6 小时触发 →  check-version 对比 LAST_VERSION  →  新的就 build
    ↑                                                  ↓
    └──  缓存读取  ←  cache save  +  (可选) git commit 回写
```

想重置状态让它再打一次？删 `LAST_VERSION` 文件，再去 Actions → Caches 清掉 `mindustry-ios-last-version-*` 这几条缓存。

---

## 经常会遇到的坑

**Q1：为什么非得按 tag 拉源码？直接用 master 不就完了？**
A：Anuken 自己的 Deployment CI 就是 tag push 才出正式包。我们按 tag 拉才能保证 build 号、资源包内容跟 App Store 上那版一致。

**Q2：版本号 `8.146.0` 这种格式是怎么来的？**
A：上游 `ios/build.gradle` 里有一段：
```groovy
props['app.version'] = versionNumber + "." + bversion + (bversion.contains(".") ? "" : ".0")
```
`versionNumber=8`，`bversion=146`，所以就 `8.146.0`。

**Q3：构建报 robovm / MetalANGLEKit 错怎么办？**
A：RoboVM 2.3.26 跟 Xcode 版本绑定得挺紧。建议：
- Runner 固定 `macos-14`（Xcode 15），已经这么写了；
- 检查上游 `ios/build.gradle` 里引用的 `robovm-gradle-plugin:2.3.26` 能不能下到；
- 本地排错就 `cd ios && ../gradlew createIPA -Pbuildversion=146` 看具体堆栈。

**Q4：TrollStore 装完点开就闪退？**
A：挨个排查：
1. TrollStore 本身装好了没？先装个别的 IPA 试试；
2. 你设备系统是不是比 `MinimumOSVersion=15.0.0` 还老（iOS 14 以前跑不动）；
3. arm64e 奇葩设备的兼容问题，本仓库只编 arm64。

**Q5：以后想改回签名走 TestFlight / App Store 要动哪几块？**
A：三件事：
1. `scripts/build-ipa.sh` 把 `SKIP_SIGNING="true"` 改回 `false`，并恢复 p12 / mobileprovision 导入那几行（之前的版本 git history 里都有，不用从零写）；
2. Workflow 里把签名相关凭据配置好，通过 env 传给 build-ipa.sh；
3. build-ipa job 末尾加一个 `apple-actions/upload-testflight@v1` 步骤，把 `dist/*.ipa` 传 App Store Connect。

---

## 协议 & 衍生说明

```
Mindustry iOS IPA Packager
Copyright (C) 2026

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

关于上游：

- 原作者：**Anuken** · 仓库：[`Anuken/Mindustry`](https://github.com/Anuken/Mindustry) · 协议：**GPLv3**
- iOS 用的是 [`RoboVM 2.3.x`](https://github.com/MobiVM/robovm)
- 要求 JDK 17

**本项目不会改游戏源码**，只在构建时按上游 tag 把源码 clone 下来；分发出来的 IPA 是上游源码的衍生作品，按 GPLv3 要附源码地址——构建元数据文件 `*.meta.txt` 里写了上游对应 tag 和 commit hash，拿那个就能把原源码拉出来。
