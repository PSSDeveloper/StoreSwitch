# StoreSwitch · App Store 账号切换

StoreSwitch 是面向个人自用的 macOS 菜单栏应用。它可保存多个 Apple Account 配置，并用系统辅助功能协助在 **App Store** 中退出和登录。各账号可以单独启用自动登录。验证码、Touch ID 和其他确认由你在 Apple 的原生界面完成。

## 构建和使用

1. 用 Xcode 打开 `StoreSwitch.xcodeproj`，选择 `StoreSwitchDev` 和 `My Mac`，按 ⌘R。也可在项目目录构建发布版：

   ```bash
   xcodebuild -project StoreSwitch.xcodeproj -scheme StoreSwitchDev \
     -configuration Release -destination 'platform=macOS' \
     -derivedDataPath .build/DerivedData build
   ```

   输出为 `.build/DerivedData/Build/Products/Release/StoreSwitch.app`。如果该路径下的应用正在运行，请先从菜单栏退出再构建。应用启动后在菜单栏显示双向箭头，Dock 中没有图标。最低系统版本为 macOS 14。

2. 从菜单打开「添加账号…」或「管理账号…」，填写邮箱并选择地区。不选地区时显示 🌐「未指定」，同一地区可以保存多个账号。点行末的删除按钮并保存即可移除账号。首次切换账号或检查登录状态时，StoreSwitch 会在需要授权时打开引导。也可从菜单点「开启辅助功能权限…」。在系统设置打开 **StoreSwitch** 的开关，再回到引导窗口。窗口会自动检查权限，确认后可继续刚才的操作。若找不到当前构建或开关未生效，可点「授权遇到问题？」查看处理步骤。POC 的授权与此应用独立。
3. 如需自动登录，先保存邮箱，再为该账号点「设置密码」，并在账号列表点「保存」。密码只存于本机 macOS 钥匙串。移除密码、更换邮箱和删除账号也在保存后生效。关闭窗口时，可以保存、放弃修改或继续编辑。
4. 在菜单中选择目标账号。如果已有账号登录，请核对目标邮箱并确认退出。启用自动登录时，StoreSwitch 会先读取钥匙串。无法读取时，可以在退出当前账号前取消切换，或继续手动登录。如果当前已退出，可以打开登录窗口或复制目标邮箱。请在 Apple 界面完成登录及后续验证。
5. StoreSwitch 检测到 App Store 已登录后会自动结束切换。你可以留在 App Store 查看登录结果。单独点「检查登录状态」时，如果 App Store 尚未运行，StoreSwitch 会先启动它。

**界面语言。** 从菜单下部的「语言 / Language」选择「简体中文」或「English」。界面即时更新，选择会保存。首次启动时使用系统首选的受支持语言。日志条目按生成时的语言保存。

**快捷键：**全局 `⌃⌥S` 打开 StoreSwitch 菜单，可从菜单关闭；也可点击菜单栏图标。菜单中的 `⌘1` 至 `⌘9` 对应账号列表的前九项。

## 发布与检查更新

从菜单点「检查更新…」会打开 Sparkle 2 的更新界面。发现新版后，由用户确认安装，Sparkle 负责下载、验签和重启。更新界面使用 macOS 为应用选择的语言。首次迁移到 Sparkle 的用户需通过 DMG 安装一次带 Sparkle 的版本。

1. 用 Sparkle 自带的 `generate_keys` 生成 EdDSA 密钥。保存和备份签名私钥，仅将输出的公钥用于构建。
2. 在 StoreSwitchDev 目标的构建设置中填写 `STORESWITCH_UPDATE_FEED_URL` 和 `STORESWITCH_UPDATE_PUBLIC_KEY`。也可以把 `'STORESWITCH_UPDATE_FEED_URL=https://downloads.example.com/storeswitch/appcast.xml'` 和 `'STORESWITCH_UPDATE_PUBLIC_KEY=你的公钥'` 传给 `xcodebuild`。开发构建可以留空，点「检查更新…」时会说明缺少配置。
3. 发布时递增构建号 `CURRENT_PROJECT_VERSION`。为 App 做 Developer ID 签名和 Apple 公证，完成 DMG 打包后，用 Sparkle 的 `generate_appcast --download-url-prefix https://downloads.example.com/storeswitch/ <DMG目录>` 生成 `appcast.xml` 和更新包签名。
4. 把新 DMG 和清单上传到可匿名访问的 HTTPS 下载目录，先上传 DMG，再替换清单。用已安装的旧构建点「检查更新…」，验证从检查到安装和重启的流程。

相关工具和签名要求见 [Sparkle 官方文档](https://sparkle-project.org/documentation/)。

## 恢复和日志

- 如果 App Store 刚启动，应用会短暂重读「商店」菜单；若仍读不到，可点「重新检查」。如果退出操作已发出但结果未确认，先处理 App Store 的原生退出提示，再点「继续登录」。需要完整说明时可点「查看切换详情」。
- 如果原生登录窗口没打开，可点「打开登录窗口」；若表单已显示但没填入邮箱，可点「重填邮箱」，或复制邮箱后手动填写。Apple 的账号选择器和独立认证界面由你在原生窗口操作。
- 如果 Apple 的密码框不允许辅助功能填写，或表单无法确认，请在 App Store 继续。密码提交结果不确定时，先查看原生界面。恢复操作只预填邮箱。
- StoreSwitch 的密码共用一个本机钥匙串条目。「始终允许」适用于该条目与当前受信任的应用。旧版逐账号保存的密码会在各自首次成功读取时自动迁移，迁移前 macOS 仍可能逐条询问。更换或移除密码时会清理对应旧条目。重新编译或升级临时签名版本后，macOS 也可能要求重新授权。
- 等待人工操作时可以选择「结束切换」。需要排查时，从「关于 StoreSwitch」打开「诊断日志」。调试版也可从菜单点「查看日志」或按 ⌘L。日志保留最近 300 条，可导出。邮箱、密码和验证码不写入日志。

`./check-menu.sh` 可离线检查流程安全和恢复逻辑；`./build.sh` 可构建原 POC 并运行其离线自检。真机验收时可先验证取消退出，再用测试或自有账号验证原生登录与地区。辅助功能选择器、登录窗口和商店状态以本机 App Store 显示为准。

## 第一阶段 POC

这是在本机运行的原生 Swift / AppKit 验证工具。它用公开的 macOS Accessibility API 检查和操作系统 App Store。测试邮箱固定为 `poc-test@example.com`，只在确认后写入，验证以原生界面显示为准。

### 运行与重新构建

在访达双击同目录的 `StoreSwitchPOC.app`。如果从 Git 检出后目录里还没有这个应用，先运行下面的构建脚本。若窗口仍运行的是先前构建，先按 ⌘Q 退出验证工具，再双击启动。

重新构建时，在终端进入本目录并运行：

```bash
./build.sh
```

脚本调用当前 Xcode 的 Swift 编译器，生成适配当前架构的应用，做本地临时签名、签名校验和 11 项离线自检。它不依赖第三方包。重新构建会更新应用签名，macOS 可能要求重新授权。也可以直接复跑离线检查：

```bash
./StoreSwitchPOC.app/Contents/MacOS/StoreSwitchPOC --self-check
```

### 手动验证

| 步骤 | 操作 | 要记录的结果 |
|---|---|---|
| 1. 辅助功能 | 在工具内点「请求授权」。在 **系统设置 → 隐私与安全性 → 辅助功能** 开启此工具。本机搜索「允许辅助应用程序控制电脑」会打开「设备控制和数据访问」。若列表里没有工具，用「+」添加同目录下的 App。回到工具点「检查授权」，必要时退出工具再启动。 | `AXIsProcessTrusted=true` 才能继续读 App Store。提示的初次返回值为 `false` 是正常的，授权需要手动完成。 |
| 2. 启动与探测 | 点「打开 App Store」。切回工具，点「只读检查」。用「展开 Store 菜单」单独验证菜单展开后的属性，之后可在 App Store 按 Esc 收起。 | `启动后前台 App Store=true`。已登录时，预期菜单内仅匹配一个 `Sign Out`。菜单展开后，检查退出项是否报告 `AXEnabled=true` 和 `AXPress=true`。 |
| 3. 退出 | 当你准备好退出当前 App Store 账号时，点「退出当前账号…」，核对弹窗后点「退出当前账号」。工具会激活 App Store，在需要时展开「商店」菜单并重新读取「退出登录」。如果 App Store 又显示确认框，在原生界面自行决定并操作。若当前本来就已退出，可直接测试第 4 步。 | 记录确认、`AXPress` 返回值、退出后菜单检查。预期从 `Sign Out` 变成 `Sign In`，同时可在 App Store 左下角看到登录入口。 |
| 4. 打开原生登录 | 点「打开原生登录」。如果工具没有找到入口，在 App Store 左下角手动点「登录」，或按原生界面提示进入 Apple Account 输入页。等界面加载后切回工具点「只读检查」。 | 记录登录入口、普通文本框匹配数量及 `AXValue` 是否可写。账号选择器、触控 ID 或独立认证窗口可能导致工具看不到输入框。 |
| 5. 预填测试邮箱 | 如果只读检查只匹配一个可写的 Apple Account 文本框，点「预填测试邮箱…」，核对弹窗后确认。该动作可能覆盖框内文字。 | 记录 `AXSetValue` 返回值，并肉眼核对框里出现 `poc-test@example.com`。核对后关闭或取消原生登录，避免提交测试邮箱。 |
| 6. 真实账号与状态 | 如需验证完整切换，重新打开原生登录，由你输入目标账号、密码并完成 Apple 要求的双重认证。认证完回到工具点「只读检查」。 | `Sign Out` 再次出现只说明界面疑似已登录。请在 App Store 原生账号界面人工核对目标账号或商店地区。记录通过或失败即可。 |
| 7. 保存 | 在工具内点「保存日志…」，保存到你选择的位置。 | 日志含时间、应用环境、匹配计数和 AX 返回码。日志采用 UTC，后缀为 `Z`。测试结束可在系统设置撤销该工具的辅助功能授权。 |

### 本机记录

表格中的日志文件保存在本机交付目录，Git 版本仅包含下列测试摘要。

| 项目 | 2026-11-11 本机结果 |
|---|---|
| 环境 | Apple Silicon（arm64）、macOS 27.2.1（26B131）、Xcode 27.2（27B52）、macOS SDK 27.2、Swift 6.4.2、App Store 3.0、首选语言 `zh-Hans-CN` |
| 构建 | Swift 编译、签名校验及 11 项离线自检通过。见 [Build.log](Build.log)。自检覆盖菜单文案、状态冲突、通用输入框和安全输入框拒绝规则。 |
| 原生界面 | POC 启动成功，App Store 启动并成为前台。POC 请求了 macOS 授权提示。未授权时只读检查中止，两个确认弹窗均以取消结束。日志成功导出。见 [StoreSwitchPOC.log](StoreSwitchPOC.log)。 |
| 真机只读检查 | 移除旧的授权项并重新添加当前构建后，`AXIsProcessTrusted=true`。连续三次读取均找到 1 个「商店」菜单、18 个条目和 1 个「退出登录」。菜单收起时，退出项报告 `AXEnabled=false`；展开原生「商店」菜单后，再读为 `AXEnabled=true`、`AXPress=true`。见 [Menu-check.log](Menu-check.log)。 |
| POC 0.2 真机复测 | 授权、前台激活、两个确认框的取消路径均通过。后台读取退出项显示禁用，激活 App Store 后退出项显示可用。本轮激活后已可执行，未触发自动展开菜单的备用路径。 |
| 真机账号流程 | 经单独确认，执行一次实际退出，菜单从「退出登录」切换为「登录」。原生登录表单载入后找到唯一可写的账号框，确认预填后在原生表单中核对了 `poc-test@example.com`，随后取消表单。App Store 保持退出状态。真实账号登录与地区核对留给用户在 Apple 界面完成。见 [Retest-0.2.log](Retest-0.2.log) 中 `04:11:23Z` 起的复测记录。 |

### 如何看失败

- **开关已开启，应用仍显示未授权。** 本机出现过此现象。临时签名与具体构建绑定，同名授权项可能仍对应上一份构建。请从列表中移除旧的 `StoreSwitchPOC` 条目，用「+」添加当前的 `StoreSwitchPOC.app`，开启后重启工具，再检查授权。[Apple 代码签名与应用身份说明](https://developer.apple.com/documentation/Technotes/tn3127-inside-code-signing-requirements)
- **没有唯一的 Store / Sign Out。** App Store 可能尚未载入、菜单尚未展开、窗口处于模态状态，或者界面文案不在已知匹配集合。可等窗口稳定后重试，记录菜单匹配数及错误码。`完整=false` 时，工具会拒绝基于该菜单退出。
- **菜单收起时退出项显示禁用。** 本机复现了这个差异。原生「商店」菜单最下面、紧接「账户」的是「退出登录」。0.2 版会尝试展开菜单并重新定位；如果前台切换失败，或退出项始终无法唯一匹配并启用，操作会停止。
- **AX 动作不可用。** `AXEnabled` 和 `AXPress` 必须都明确可用。`cannotComplete`（-25204）可能表示 App Store 没及时返回，动作仍可能生效。先查看原生界面，再决定是否需要手动操作。`invalidUIElement`（-25202）表示原对象已失效，需重新检查。
- **没有唯一可写的文本框。** POC 只扫描系统 App Store 进程的窗口或原生表单，识别普通的 Apple Account 文本框。如果认证由独立进程显示，AX 树不完整，或未公开可写属性，就在 Apple 原生界面手动输入。
- **刚打开表单时只看到空的 AXSheet。** 0.2 版真机复测中，首次扫描早于表单加载。等表单可见后点「只读检查」，即可找到账号输入框。
- **预填返回成功但未显示。** 以原生界面实际显示为准。某些控件可能接受 AX 调用但不更新界面，或后续将值替换。
- **显示已登录但身份未知。** 菜单状态只能推断会话状态。具体账号和地区请在 App Store 内核对。

### 兼容性与下一步

构建最低部署目标为 macOS 14.0，实机运行记录来自上表这一套系统。当前标签覆盖常见英文、简体中文、繁体中文和土耳其语拼写。匹配跟随 **App Store 界面语言**，Apple ID 注册地区不决定匹配语言。应用只使用系统 App Store 的进程和窗口，日志只包含已知标签及结构，代码不读取任何输入框的内容。退出和测试预填都需要单独确认，预填后由用户在原生界面决定下一步。

在需要验证完整换区流程时，逐个用中国大陆、美国、土耳其账号完成原生登录并核对目标账号和地区。后续扩展其他 macOS 版本或语言时，以对应版本的 AX 日志为准。

[Apple App Store 登录与退出说明](https://support.apple.com/en-euro/guide/app-store/fir6253293d/3.0/mac/27) · [Apple AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h) · [AppKit 协作式应用激活](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)
