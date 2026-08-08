# open-flower → AutoBuff 迁移记录

更新日期：2026-06-21
AutoBuff 版本：2.1.4
目标平台：macOS 14+

本文不再作为“尚未开始的施工计划”，而是记录已采用的实现、与 Windows 版的差异，以及仍需在真实游戏中完成的验收。

## 1. 迁移原则

`open-flower` 用于确认产品行为：

- 默认 3 个 Buff 槽位，可手动增加到 8 个
- 活花循环释放
- 死花离开市场、释放、返回市场
- 拟人化输入
- 小地图、市场按钮和弹窗检测
- 设置持久化与调试工具

平台实现不要求逐行一致。Windows 的 `pywin32`、`mss`、OpenCV、PyQt6 和 `pynput` 分别由 ScreenCaptureKit、CoreGraphics、Accelerate/vImage 与 SwiftUI 替代。

## 2. 最终技术选型

| 能力 | AutoBuff 实现 |
|---|---|
| UI | SwiftUI |
| 窗口枚举 | `CGWindowListCopyWindowInfo` |
| 激活游戏 | `NSRunningApplication.activate()` |
| 截图 | `SCScreenshotManager` |
| 图像格式 | 自有 `ImageBuffer`，BGR 三通道 |
| 模板匹配 | Accelerate/vImage 卷积 + 归一化相关 |
| 颜色检测 | Swift 连通域 + OpenCV 等价阈值 |
| 键鼠输入 | `CGEvent` |
| 辅助功能权限 | `AXIsProcessTrusted` |
| 屏幕录制权限 | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` |
| 设置 | Codable JSON |
| 后台流程 | Swift Concurrency `Task` + `actor` |

早期计划中的 OpenCV 集成已经取消。当前实现不需要第三方依赖。

## 3. 坐标结论

早期文档中“CGEvent 使用左下角原点，因此必须 flipY”的结论是错误的。

实际规则：

- `kCGWindowBounds`：主显示器左上角原点，Y 向下。
- `CGEvent.location`：Quartz 全局显示坐标，左上角原点，Y 向下。
- `CGEventGetUnflippedLocation` 才是相对主显示器左下角的坐标。
- `NSEvent.mouseLocation` 是未翻转坐标，不能直接与 `CGEvent` 混用。

AutoBuff 的截图、检测和点击统一使用左上角原点。截图点到屏幕点按截图尺寸与窗口 bounds 比例换算，不执行 Y 翻转。

ScreenCaptureKit 按窗口 Quartz 点尺寸输出截图，不固定乘 Retina 比例。这样可以：

- 降低模板匹配计算量
- 让 Windows 模板尺寸更接近 macOS 游戏 UI
- 让截图坐标与 CGEvent 坐标基本保持 1:1
- 仍可在尺寸有差异时通过比例转换保持正确点击

## 4. 已完成模块

### 基础与 UI

- [x] macOS 14 Deployment Target
- [x] SwiftUI 主界面
- [x] 死花/活花模式切换并持久化
- [x] 默认 3 个 Buff 配置，可动态增加和删除
- [x] 520×620 紧凑型蓝白卡片界面，默认露出运行日志折叠入口
- [x] 游戏窗口信息并入顶部状态栏
- [x] 模式参数使用横向紧凑控件
- [x] 日志与调试工具默认折叠，主运行按钮固定可见
- [x] 虚拟键盘
- [x] 传送门标记
- [x] 日志、倒计时、截图预览
- [x] 运行时锁定设置，避免 Worker 与 UI 配置不一致

### 权限与窗口

- [x] 辅助功能检查和系统授权提示
- [x] 屏幕录制检查和系统授权提示
- [x] 自动识别游戏窗口
- [x] 手动窗口选择
- [x] 窗口有效性检查
- [x] 窗口移动或缩放后清除死花坐标缓存

### 截图与图像

- [x] ScreenCaptureKit 窗口截图
- [x] CGImage → BGR
- [x] 区域裁切
- [x] Quartz 坐标换算
- [x] Accelerate 模板匹配
- [x] 市场按钮检测
- [x] 市场 Logo 完整/下半模板检测
- [x] 确定按钮检测
- [x] 小地图深色区域检测
- [x] 小地图外轮廓面积等价实现与多阈值回退
- [x] 玩家黄点最大连通域
- [x] 蓝色传送门连通域

### 输入

- [x] 正确的 ANSI 字母、数字和特殊键虚拟键码
- [x] 方向键持续按下与换向
- [x] 上键进入传送门
- [x] 拟人化鼠标移动与点击
- [x] 停止时释放全部方向键

### 活花

- [x] 启动时批量释放
- [x] 每槽位独立倒计时
- [x] 双次按键
- [x] 技能间随机间隔
- [x] 三种移动模式
- [x] 随机提前释放
- [x] 空闲坐椅子单次触发
- [x] 窗口失效时退出

### 死花

- [x] 严格到期后启动一轮
- [x] 10 秒内 Buff 合并释放
- [x] 出市场后支持先右再左、只向左（鱼窝）、只向右（骨龙、忘却）
- [x] 市场/怪物地图判断
- [x] 手动传送门优先
- [x] 自动蓝色传送门
- [x] 黄点导航
- [x] 停滞后重新按键
- [x] 越过传送门后换向
- [x] 导航前跳跃键
- [x] 出市场后移动
- [x] 怪物地图启动时释放后返回市场
- [x] 市场按钮多次点击
- [x] 场景确认和重试
- [x] 空闲弹窗检测
- [x] 空闲坐椅子单次触发
- [x] 窗口失效时退出

## 5. 与 Python 行为的差异

| 项目 | Python | AutoBuff |
|---|---|---|
| 模板匹配 | OpenCV | Accelerate/vImage |
| 截图 | Windows 客户区物理像素 | macOS 窗口 Quartz 点尺寸 |
| 点击坐标 | Win32 屏幕坐标 | Quartz 全局显示坐标 |
| Buff 计时键 | 按键字符串 | Buff 槽位 ID |
| 跳跃键 | 有方法但主循环未调用 | 导航前实际调用 |
| 手动传送门 | 运行期内存 | JSON 持久化 |
| 模式 | UI 状态 | UI 状态并持久化 |
| 模板性能 | OpenCV 优化 | vImage 卷积和积分图 |

## 6. 已修复的早期 AutoBuff 问题

- Retina 截图硬编码为窗口尺寸的 2 倍
- 点击坐标错误执行 Y 翻转
- `NSEvent.mouseLocation` 与 CGEvent 坐标混用
- 字母键码按 A～Z 序号生成
- HSV Hue 用 0～360 计算却套用 OpenCV 0～180 阈值
- 黄点取全部黄色像素质心，而不是最大连通域
- 模板匹配为每个候选位置创建裁剪图片，无法实时运行
- 死花提前 10 秒就开始离开市场
- 死花越过传送门后不换向
- 自动传送门和窗口尺寸缓存没有正确更新
- 从怪物地图启动时释放后不返回市场
- 坐椅子在主循环中高频重复按键
- 相同按键覆盖倒计时字典
- Worker 自然退出后 UI 仍显示“运行中”
- 早期任务停止后快速重启可能干扰新任务

## 7. 自动验证

本机验证命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project AutoBuff.xcodeproj \
  -scheme AutoBuff \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  build CODE_SIGNING_ALLOWED=NO
```

结果：Debug 构建成功，无编译警告。

核心单元测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project AutoBuff.xcodeproj \
  -scheme AutoBuff \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  test -only-testing:AutoBuffTests CODE_SIGNING_ALLOWED=NO
```

覆盖设置、BGR、图像方向、坐标、键码、颜色检测、小地图形态学处理、模板资源打包和模板匹配。

签名为“Sign to Run Locally”时，macOS UI 启动测试也已通过，覆盖应用启动和主要控件存在性。无签名命令行环境仍不能启动 UI Test Runner。

## 8. 尚需真实游戏验收

以下项目不能只靠源码和合成图片证明：

- [ ] 当前客户端下三个模板的匹配阈值
- [ ] 不同游戏窗口比例下的小地图自动区域
- [ ] 市场活动公告遮挡 Logo 时的识别率
- [ ] 多显示器排列下的鼠标落点
- [ ] 游戏是否接受 `CGEvent` 产生的按键
- [ ] 窗口激活后的输入时序
- [ ] 死花连续 3 轮以上稳定性
- [ ] 客户端更新后的模板兼容性

验收方式和排查顺序见项目 [README.md](README.md)。
