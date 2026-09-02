# Mindustry iOS IPA 自动打包工程

> 自动从 [Anuken/Mindustry](https://github.com/Anuken/Mindustry) 获取源码，
> **严格按上游版本号** 打包 iOS IPA，支持 GitHub Actions 定时检测新版本并自动构建。

*本仓库是 Mindustry（GPLv3）的**衍生构建工程**，自身亦采用 **GNU GPLv3** 协议，见 [`LICENSE`](./LICENSE)。*

---

## 一、版本号严格映射规则（关键）

为了与 **App Store** 版本号完全一致，打包工程严格遵守以下映射：

| 项目 | 值示例 | 来源 |
| --- | --- | --- |
| 上游 GitHub Release Tag | `v146` | Anuken/Mindustry `releases/latest` |
| 源码检出点 | `refs/tags/v146` | 严格按 tag `--depth 1` 克隆 |
| `build.gradle#versionNumber` | `8`（主版本号） | 源码头 `build.gradle` 内 `versionNumber = '8'` |
| 构建参数 `-Pbuildversion` | `146` | 从 tag 去掉前缀 `v` |
| `core/assets/version.properties` `build=` | `146` | `core:preGen` 自动写入 |
| **CFBundleShortVersionString**（App Store 显示版本） | **`8.146.0`** | `ios/robovm.properties` 中 `app.version = 8.<build>.0` |
| **CFBundleVersion**（内部构建号） | **`146`** | `ios/robovm.properties` 中 `app.build = <build>` |
| IPA 最终文件名 | `Mindustry-iOS-v146_8.146.0.ipa` | 由 `scripts/build-ipa.sh` 重命名 |

> **强制规则**：如果手动通过 Actions 传入一个不存在于 Anuken/Mindustry 的 `build_version`，
> `check-version` job 会**直接报错终止**，防止随意打包非官方版本。

### App Store 版本校验（可选）

在 `.github/workflows/ios-ipa-build.yml` 的 `check-version` job 中设置
`CHECK_APPSTORE=true` 即可启用 iTunes Lookup API 自动对比 App Store 上
`io.anuke.mindustry` 的当前显示版本，当与预期的 `8.<build>.0` 不一致时打印 WARN。

---

## 二、目录结构

```
Mindustry-iOS-Packager/
├── .github/workflows/
│   └── ios-ipa-build.yml      # 自动检测 + 构建 工作流
├── scripts/
│   ├── check-version.sh       # 检测上游最新 release / App Store 版本对比
│   ├── build-ipa.sh           # 核心：拉源码→同步版本→签名→打包 IPA
│   └── bump-last-version.sh   # 构建成功后更新 LAST_VERSION 状态文件
├── LAST_VERSION               # 上次成功构建的 tag（持久化状态，如 v146）
├── dist/                      # 构建产物输出目录
│   ├── Mindustry-iOS-v146_8.146.0.ipa
│   └── Mindustry-iOS-v146_8.146.0.ipa.meta.txt
├── LICENSE                    # GNU GPLv3（与上游一致）
└── README.md                  # 本文档
```

---

## 三、GitHub Actions 配置

### 3.1 触发方式

| 方式 | 说明 |
| --- | --- |
| **Schedule** | 每 6 小时（UTC 0/6/12/18:17）自动检测上游 Release；新版本 → 自动构建 |
| **workflow_dispatch** | 在 Actions 页面手动触发；可传入 `build_version` 强制构建某个历史版本 |

### 3.2 必选 Secrets（真机签名）

| Secret 名称 | 说明 | 获取方式 |
| --- | --- | --- |
| `IOS_CERT_BASE64` | 开发者 `.p12` 证书的 Base64 字符串 | 钥匙串导出 `Certificates.p12` → `base64 -i Certificates.p12` |
| `IOS_CERT_PASSWORD` | `.p12` 证书密码 | 导出时自行设置 |
| `IOS_PROV_PROFILE_BASE64` | `.mobileprovision` 文件的 Base64 | Apple Dev Portal → Profiles → Download → `base64 -i *.mobileprovision` |
| `IOS_PROV_PROFILE_UUID` | Provisioning Profile UUID | Profile 文件内 `<key>UUID</key>` 或 Apple Dev Portal 详情页 |
| `IOS_SIGN_IDENTITY` | 签名身份全称 | `security find-identity -p codesigning -v` 输出中的长名字 |
| `IOS_PROV_PROFILE_NAME` | Provisioning Profile 名称 | Apple Dev Portal 配置的名称 |

### 3.3 可选 Secrets

| Secret 名称 | 说明 |
| --- | --- |
| `PAT_GITHUB` | 具有 `contents:write` 权限的 Personal Access Token；用于在 schedule 构建成功后 **自动 commit 回写 `LAST_VERSION`**，避免跨 run 缓存漂移。未设置时仅依赖 cache。 |

### 3.4 手动触发参数

```
build_version: 146              # 留空=自动检测；否则必须严格是 Anuken/Mindustry 已存在的 tag v<build_version>
force_build:  false             # 即使 LAST_VERSION 已是最新也强制构建
skip_signing: false             # 跳过签名，生成未签名 IPA（需 AltStore/TrollStore 等方式安装）
```

---

## 四、本地构建（macOS）

> 要求：macOS 13+ / Xcode 14+ 且已安装 Command Line Tools、JDK 17

### 4.1 未签名快速构建（验证流程）

```bash
cd Mindustry-iOS-Packager
BUILD_VERSION=146 SKIP_SIGNING=true ./scripts/build-ipa.sh
```

产物：

```
dist/Mindustry-iOS-v146_8.146.0.ipa            ← 未签名 IPA
dist/Mindustry-iOS-v146_8.146.0.ipa.meta.txt   ← 构建元数据（commit hash、版本号、工具版本）
```

### 4.2 真机签名构建

预先把 Apple Development 证书和描述文件安装到本机，然后：

```bash
BUILD_VERSION=146 \
IOS_SIGN_IDENTITY="Apple Development: Your Name (TEAM12345)" \
IOS_PROV_PROFILE_NAME="Mindustry iOS Dev" \
./scripts/build-ipa.sh
```

---

## 五、版本检测脚本单独使用

单独执行检测而不构建：

```bash
./scripts/check-version.sh
```

输出：

```
RELEASE_TAG=v146
BUILD_VERSION=146
APP_STORE_VERSION=8.146.0
NEEDS_BUILD=true
```

启用 App Store 对比：

```bash
CHECK_APPSTORE=true APPSTORE_BUNDLE_ID=io.anuke.mindustry ./scripts/check-version.sh
```

---

## 六、版本状态管理

`LAST_VERSION` 文件记录**上一次成功构建**的上游 tag，避免重复构建。
更新路径：

```
┌──────────────┐    needs build=true     ┌──────────────┐   success    ┌─────────────────┐
│ schedule每6h │ ─────────────────────▶ │ macos 构建IPA │ ───────────▶ │ bump LAST_VERSION│
└──────────────┘                        └──────────────┘              └──────┬──────────┘
       ▲                                                                    │
       │                                                                    ▼
    读取缓存                                              cache save + （可选）git commit 回写
```

如果要**重置状态**，删除仓库内 `LAST_VERSION` 文件和 Actions cache 中的
`mindustry-ios-last-version-*` 即可。

---

## 七、常见问题 FAQ

**Q1：为什么要按 tag v146 检出，而不是直接用 master 或某个 commit？**
A：为了确保打包内容与上游发布到 App Store / Google Play 的内容**完全一致**。
上游 Deployment CI 也是在 `v*` tag push 时执行 `./gradlew -Pbuildversion=${RELEASE_VERSION:1}`，
完全沿用这套规则才能保证版本号与 App Store 完全对齐。

**Q2：`CFBundleShortVersionString` 为什么是 `8.<build>.0`？**
A：参考上游 `ios/build.gradle`：
```groovy
props['app.version'] = versionNumber + "." + bversion + (bversion.contains(".") ? "" : ".0")
```
其中 `versionNumber=8`，`bversion` 是 build version（如 146），因此格式就是 `8.146.0`。

**Q3：构建失败提示 `robovm` / `MetalANGLEKit` 错误？**
A：RoboVM 2.3.26 与 Xcode 版本强相关，建议：
- `macos-14` + Xcode 15（默认）
- 确认 `ios/build.gradle` 里的 `robovm-gradle-plugin:2.3.26` 可用
- 本地验证：`cd ios && ../gradlew createIPA -Pbuildversion=XXX ...`

**Q4：签名通过但真机闪退？**
A：常见原因：
1. 设备 UDID 未加入 Provisioning Profile
2. `MinimumOSVersion=15.0.0` 导致 iOS 14 以下不能运行
3. arm64e 架构异常（当前仅编译 arm64）

**Q5：如何上传到 App Store / TestFlight？**
A：在 build-ipa job 末尾追加以下步骤即可：
```yaml
- name: Upload to App Store Connect
  uses: apple-actions/upload-testflight@v1
  with:
    ipaPath: dist/*.ipa
    username: ${{ secrets.APPLE_ID }}
    password: ${{ secrets.APPLE_APP_PASSWORD }}
```

---

## 八、协议与衍生声明

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
along with this program. If not, see <https://www.gnu.org/licenses/>.
```

### 关于上游 Mindustry

Mindustry 原版作者：**Anuken**（@Anuken）
- 上游仓库：<https://github.com/Anuken/Mindustry>
- 上游协议：**GNU General Public License v3.0**（同仓库 [`LICENSE`](https://github.com/Anuken/Mindustry/blob/master/LICENSE)）
- 上游 README 指明：
  - 主版本：`versionNumber = 8`
  - JDK 版本：**必须 JDK 17**
  - iOS 构建框架：[RoboVM 2.3.x](https://github.com/MobiVM/robovm)

**本打包工程不修改任何游戏源码**，仅提供自动化脚本；**构建期从上游 tag 完整拉取源码**。
分发的 IPA 文件是上游 Mindustry 源码的衍生作品，同样受 GPLv3 约束，因此必须随 IPA
一起提供获取对应源码的方式（上游 tag URL 已写入构建元数据 `.meta.txt`）。
