# YzY - Auto Buff

YzY - Auto Buff 是 `open-flower` 的 macOS 原生移植版，用于在 MapleStory Worlds-Artale 中按配置循环释放 Buff。

当前版本：**2.1.4**

## 当前状态

以下链路已经实现并通过本机编译：

- macOS 14+ SwiftUI 应用
- 启动时使用监控服务账号登录，不再使用机器码或激活码
- 用户名仅用于登录；登录后只展示注册昵称
- 左侧栏使用图标加简短功能名称
- 地图库直接展示常驻地图列表，不使用下拉选择
- 云端地图支持上传当前选中的单张地图，也可批量上传全部地图
- 建图使用单帧小地图识别，避免多帧合成造成模糊；修改地图时可抓取当前小地图，用未被红、黄、橙标记遮挡的区域修补并保存参考图
- 登录时上报 macOS 客户端版本；被超级管理员禁用的版本会提示更新并拒绝登录
- 左侧栏底部常驻显示当前客户端版本号，切换任何功能都可见
- 游戏窗口自动识别与手动选择
- 辅助功能、屏幕录制权限检查与引导
- ScreenCaptureKit 窗口截图
- 原生 Accelerate/vImage 模板匹配，无 OpenCV 依赖
- 黄点玩家、蓝色传送门、小地图深色区域检测
- 市场按钮、市场 Logo、确定按钮模板检测
- CoreGraphics 键盘、方向键和鼠标输入
- 活花与死花 Worker
- 设置持久化、虚拟键盘、传送门标记、日志与截图预览

项目已通过 Debug/Release 构建和 16 项核心单元测试，并已对真实签名应用完成窗口与布局检查。游戏画面、模板和地图会随客户端版本、窗口比例及 UI 缩放变化，因此发布前仍需按照本文末尾的“游戏内验收”完成实机校准。

## 与 Windows 版的关系

`open-flower` 是行为基线，AutoBuff 不逐行翻译 Python，而是按 macOS 的 API 和坐标规则重新实现。

本次复核修正了早期移植稿中的几个关键错误：

- 不再把 Retina 截图尺寸固定乘以 2；截图按 Quartz 点分辨率生成。
- `CGWindow` 与 `CGEvent` 都使用左上角原点的全局显示坐标，点击时不进行错误的 Y 轴翻转。
- 字母键使用真实 macOS 虚拟键码，不再用字母序号代替键码。
- OpenCV HSV 的 Hue 范围是 0～180；蓝色阈值已按该范围正确换算。
- 模板匹配改为 Accelerate/vImage 卷积和归一化相关，不再逐像素创建临时图片。
- 死花导航会在越过传送门后换向，窗口移动或缩放后会清除坐标缓存。
- 活花和死花的“坐椅子”只触发一次，不会每 100 ms 重复按键。
- Buff 计时按槽位 ID 保存，同一个按键不会破坏倒计时字典。

## 系统要求

- macOS 14.0 或更高
- Xcode 16 推荐
- 游戏使用窗口模式或无边框窗口模式
- 辅助功能权限：发送键盘和鼠标事件
- 屏幕与系统音频录制权限：截取并识别游戏窗口

AutoBuff 明确关闭 App Sandbox。辅助功能和屏幕录制仍由 macOS 隐私设置控制。

## 构建

用 Xcode 打开：

```text
AutoBuff/AutoBuff.xcodeproj
```

选择 `AutoBuff` Scheme 和 `My Mac` 后运行。

也可以在终端构建：

```bash
cd AutoBuff
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project AutoBuff.xcodeproj \
  -scheme AutoBuff \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  build CODE_SIGNING_ALLOWED=NO
```

如果 `xcodebuild` 提示当前目录是 Command Line Tools，可继续使用上面的 `DEVELOPER_DIR`，或自行将 `xcode-select` 切换到完整 Xcode。

## 首次运行

1. 启动游戏并保持游戏窗口可见。
2. 启动 AutoBuff。
3. 分别点击“辅助功能”和“屏幕录制”的“授权”按钮。
4. 在“系统设置 → 隐私与安全性”中允许 AutoBuff。
5. 屏幕录制权限首次开启后，按系统提示重新打开 AutoBuff。
6. 点击“识别窗口”。自动识别失败时，从窗口列表中手动选择。
7. 展开“调试工具”，先执行“截图预览”和三个检测按钮。
8. 检测结果正常后再配置 Buff 并开始运行。

### 辅助功能显示未授权

辅助功能授权会绑定应用的代码签名身份。若 Xcode 显示 `Sign to Run Locally`，
每次重新构建都可能产生新的临时身份，系统设置中已勾选的旧 AutoBuff 不能授权
当前构建。

AutoBuff 检测到临时签名时会显示“未授权（临时签名）”。可以点击“修复”清除
该 Bundle ID 的旧辅助功能记录，然后在系统设置中重新启用当前 AutoBuff。
持续开发时应使用稳定的 Apple Development 或本地开发签名。

当前开发机已配置 `AutoBuff Local Development` 本地签名。换到其他 Mac 时，
需要改用该机器的 Apple Development 证书，或创建同名本地代码签名证书后再构建。

应用启动时会关闭同一 Bundle ID 的旧实例，避免 Xcode、命令行构建目录和旧
DerivedData 中的多个 AutoBuff 同时运行并争用 TCC 权限。

## 使用方式

每个 Buff 槽包含：

- 启用开关
- 技能按键
- 持续时间（0.1～3600 秒）
- 运行时倒计时

界面默认提供 3 个 Buff 槽位，点击“添加”可按需增加，最多支持 8 个。旧配置中已经填写的额外槽位会保留，空白的旧槽位会自动收缩到 3 个。主窗口默认使用 `520×620` 紧凑布局，游戏窗口信息合并到顶部状态栏，模式参数使用横向紧凑控件，并保留可见的运行日志折叠入口。

### 活花模式

启动后立即释放所有已启用 Buff，此后每个槽位独立计时。技能默认连续按两次，间隔 100～300 ms。

可选项：

- 原地不动
- 向右移动后释放，再向左返回
- 向左移动后释放，再向右返回
- 随机提前释放
- 空闲时坐椅子

### 死花模式

工作流：

```text
市场等待
→ Buff 到期
→ 识别玩家和传送门
→ 导航并离开市场
→ 出市场后微调位置
→ 批量释放到期及 10 秒内即将到期的 Buff
→ 点击自由市场按钮
→ 确认返回市场
→ 继续等待
```

手动标记的传送门坐标优先于自动蓝色检测。打开标记界面前会先确认当前位于自由市场；不在市场或无法确认地图时会弹窗提示，不会进入截图选点界面。游戏窗口大小改变后建议重新标记。

出市场后移动方式支持：

- 先右再左
- 只向左（鱼窝）
- 只向右（骨龙、忘却）

### 神殿模式

神殿模式用于时间神殿地图，提供“休息室”“挂绳组队”“进出自由”三选一功能，
并与其他模式共用 Buff 槽位。“进出自由”当前复用死花模式的完整进出市场与
Buff 释放流程；“休息室”和“挂绳组队”已支持选择和保存，专属配置与执行方式
将在后续补充。

### 跟补模式

运行前需要设置加血键和瞬移键、选择回位方案，并在小地图上手动标记跟补基准点。默认使用左右走防卡。确认点位时会同时保存小地图区域；运行时只使用该点的 X 坐标作为基准点，直接复用保存的小地图区域读取黄点。加血键每轮持续按住 8～12 秒，轮次之间随机等待 0.25～0.6 秒。Buff 到期时会立刻松开加血键，优先按两次释放到期 Buff，并合并 10 秒内即将到期的 Buff，短暂等待后继续加血。

跟补模式只看横向位置，不处理纵向坐标。左右走防卡方案每隔随机 5～8 秒执行一次完整双向短走，总时长约 310～450ms，结束后立即恢复治疗；越界时朝标记点方向瞬移，落地稳定后仍在界外会按最新位置重试，单次事件最多 3 次。瞬移回位方案保留原有逻辑：每隔随机 4～7 秒修正，近点时先向外瞬移再返回，并在界限的 75% 处提前保护。两套方案使用独立的回位与定时修正方法。

跟补模式需要屏幕录制权限，因为它依赖小地图黄点检测。

## 图像与坐标约定

AutoBuff 使用统一的窗口截图坐标：

- 截图左上角为 `(0, 0)`。
- ScreenCaptureKit 输出尺寸配置为与窗口 Quartz 点尺寸一致。
- 检测坐标转换到屏幕时按截图尺寸和当前窗口 bounds 比例换算。
- Quartz 全局显示坐标和 `CGEvent` 均为左上角原点，Y 值向下增加。
- 鼠标当前位置也从 `CGEvent` 获取，不混用 AppKit 的未翻转坐标。

模板资源位于：

```text
AutoBuff/Resources/Templates/market/market_btn.png
AutoBuff/Resources/Templates/market/market_logo.png
AutoBuff/Resources/Templates/dialog/confirm_btn.png
```

模板已包含在项目中。若游戏 UI 更新，应重新截取紧边界、无鼠标遮挡的 PNG，并保持与实际窗口 UI 缩放接近。

## 设置文件

设置保存在：

```text
~/Library/Application Support/AutoBuff/settings.json
```

主要字段：

| 字段 | 说明 |
|---|---|
| `mode` | 上次选择的运行模式：死花、活花、神殿、跟补或监控 |
| `buffs` | 默认 3 个、最多 8 个 Buff 槽的启用状态、按键和持续时间 |
| `returnToMarket` | 兼容旧配置的死花/活花字段，新版本会根据 `mode` 自动维护 |
| `templeFunction` | 神殿模式功能：休息室、挂绳组队或进出自由 |
| `healSkillKey` | 跟补模式的加血技能键 |
| `teleportSkillKey` | 跟补模式的瞬移技能键 |
| `healAnchorX/Y` | 跟补模式手动标记的基准点坐标，运行时使用 X 坐标 |
| `followHealBoundaryTolerance` | 跟补基准点左右允许范围，旧配置默认为 ±6 个小地图点 |
| `followHealReturnStrategy` | 跟补方案：左右走防卡或瞬移回位，缺失配置时默认左右走防卡 |
| `healMinimapRegionX/Y/Width/Height` | 跟补模式标记基准点时保存的小地图区域，避免启动后重新阻塞识别 |
| `movementMode` | 活花移动模式 |
| `randomBehaviorEnabled/Value` | 活花随机提前释放 |
| `preSkillMoveMode` | 死花出市场后的移动方式 |
| `jumpKey` | 死花开始导航前的防卡跳跃键 |
| `sitChairEnabled/chairKey` | 空闲坐椅子 |
| `manualPortalX/Y` | 小地图内的手动传送门坐标 |

删除该文件可恢复默认设置。

## 测试

运行核心单元测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project AutoBuff.xcodeproj \
  -scheme AutoBuff \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  test -only-testing:AutoBuffTests CODE_SIGNING_ALLOWED=NO
```

单元测试覆盖：

- 设置读写
- CGImage → BGR 转换与行方向
- 截图坐标 → Quartz 屏幕坐标
- macOS 虚拟键码
- 黄点和蓝色检测
- 小地图深色区域的形态学处理
- 小地图外轮廓面积与多灰度阈值检测
- 三个运行时模板的 Bundle 打包与读取
- Accelerate 模板匹配位置

UI Test Runner 需要正常的本机代码签名环境。无签名命令行构建适合编译和单元测试，不适合启动 UI Test Runner。

在 Xcode 的“Sign to Run Locally”环境下，`AutoBuffUITests.testExample` 会启动应用并检查主标题、模式按钮、窗口识别按钮、开始按钮和 Buff 配置区域。

## 游戏内验收

建议按以下顺序验收，不要一上来直接运行死花：

- [ ] 截图预览方向正确，尺寸接近游戏窗口点尺寸
- [ ] 自动或手动选择窗口正常
- [ ] 市场 Logo 检测正常
- [ ] 自由市场按钮坐标正确
- [ ] 确定按钮坐标正确
- [ ] 小地图区域、玩家黄点、蓝色传送门位置正确
- [ ] 辅助功能授权后，测试按键不会发到其他窗口
- [ ] 活花原地模式连续运行 10 分钟
- [ ] 活花移动模式停止后没有方向键卡住
- [ ] 死花单轮离开、释放、返回成功
- [ ] 死花连续运行至少 3 轮
- [ ] 跟补模式能手动标记基准点，并使用该点 X 坐标持续补血
- [ ] 跟补模式 Buff 到期时会暂停补血、释放 Buff、再继续补血
- [ ] 跟补模式能每隔约 4～7 秒在持续加血时用方向键加瞬移向基准 X 修正
- [ ] 跟补模式被碰撞或手动离开基准区域后，能保持加血并连续瞬移回到区域内
- [ ] 移动游戏窗口后，按钮点击位置仍正确

## 已知限制

- macOS 不保证向后台窗口发送游戏输入；AutoBuff 会在操作前激活游戏应用。
- 全屏 Spaces、窗口被遮挡、最小化或标题变化都可能影响识别，建议使用固定大小的窗口模式。
- 模板匹配仍依赖客户端 UI 外观。游戏更新后可能需要替换模板或调整阈值。
- 当前没有真实游戏画面的自动化回归样本，最终准确率必须通过上述游戏内验收确认。
- 使用自动化工具可能违反游戏服务条款，请自行判断并承担风险。

## 项目结构

```text
AutoBuff/
├── Constants/       常量、模板路径、macOS 键码
├── Models/          设置与 Buff 数据模型
├── Services/        截图、图像处理、输入、权限、窗口、设置
├── Detection/       小地图、市场按钮、弹窗检测
├── Workers/         活花、死花和调试逻辑
├── ViewModels/      主界面状态和 Worker 编排
├── Views/           SwiftUI 界面
└── Resources/       模板 PNG
```

详细的迁移结论与后续验收项见 [MIGRATION_PLAN.md](MIGRATION_PLAN.md)。
