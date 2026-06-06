# open-flower → AutoBuff (macOS/Swift) 迁移计划

> 本文档基于对 `open-flower` 项目**每一个源文件、每一个方法**的完整阅读整理而成。  
> 目的：在正式施工前逐项核对，确保迁移准确无误。  
> 目标平台：macOS 14+，Swift + SwiftUI，框架参考 ScreenCaptureKit / CoreGraphics / Accessibility。  
> **文档版本：1.1**（2026-06-06）— 已纳入 Python 基线修正、macOS 原生坐标策略、阶段顺序调整。

---

## 目录

1. [原项目功能总览](#1-原项目功能总览)
2. [Python 基线修正记录（v1.1）](#2-python-基线修正记录v11)
3. [macOS 框架选型确认](#3-macos-框架选型确认)
4. [macOS 坐标与截图规范（不严格复刻 Python）](#4-macos-坐标与截图规范不严格复刻-python)
5. [Windows → macOS 能力对照表](#5-windows--macos-能力对照表)
6. [原项目逐文件逐方法清单](#6-原项目逐文件逐方法清单)
7. [AutoBuff 目标目录结构](#7-autobuff-目标目录结构)
8. [分步骤迁移计划](#8-分步骤迁移计划)
9. [权限与 Entitlements 配置](#9-权限与-entitlements-配置)
10. [资源文件迁移清单](#10-资源文件迁移清单)
11. [风险点与待验证项](#11-风险点与待验证项)
12. [迁移验收核对表](#12-迁移验收核对表)

---

## 1. 原项目功能总览

**open-flower（枫灵 MapleKeeper v1.0.9）** 是一款 Windows 上的游戏 Buff 自动释放助手，核心能力：

| 模式 | 行为 |
|------|------|
| **活花模式** | 在当前位置循环计时 → 到期释放 Buff → 等待 → 循环 |
| **死花模式** | 在市场等待 → Buff 到期 → 离开市场 → 移动到刷怪点 → 释放 Buff → 点击「自由市场」回到市场 → 循环 |

**附加能力：**
- 最多 6 个 Buff 独立配置（启用/按键/持续时间）
- 小地图识别（深色区域检测、黄点玩家定位、蓝色传送门检测）
- 市场 Logo / 自由市场按钮 / 对话框「確定」按钮的模板匹配
- 拟人化键鼠输入（随机延迟、换向延迟、分步鼠标移动）
- 设置持久化（INI）
- PyQt6 图形界面 + 虚拟键盘 + 传送门手动标记
- 调试工具（测试离开市场 / 回到市场 / 关闭弹窗）

---

## 2. Python 基线修正记录（v1.1）

施工前已在 Python 版修复以下问题，**Swift 版按修正后的行为实现**（不再复刻旧 bug）：

| 问题 | 修正内容 |
|------|----------|
| `random_behavior_enabled/value` 未生效 | 活花启动时读取 UI 开关与数值，写入 `SkillConfig.random_delay`；关闭时传 `0` |
| `manual_countdown` 无引用 | 从 `settings_manager` 与 `settings.ini` 中**移除**该废弃字段 |
| `_wait_for_attack_key_release` | 已从活花 `SkillWorker` **移除**（不再等待 Ctrl 松开） |
| `main_window.py` 重复代码 | 删除重复的 `start_worker` 等方法块，保留一份 |

**Swift 额外改进（Python 尚未做）：**

| 项目 | Swift 计划 |
|------|-----------|
| `manual_portal_pos` 重启丢失 | 写入 `settings.json` 的 `manualPortalX/Y`（`null` 表示自动检测） |
| 死花随机提前释放 | 可选：与活花一致支持 `randomBehavior`（v1.1 暂不强制，后续迭代） |

---

## 3. macOS 框架选型确认

结合他人推荐与项目实际需求，确认如下框架方案：

### 3.1 屏幕录制与画面识别

| 能力 | 推荐框架 | 说明 |
|------|----------|------|
| 截取游戏窗口/区域 | **ScreenCaptureKit** | 官方高性能方案，可指定 Window 或 Display；首次调用触发「屏幕录制」权限 |
| 图像处理（模板匹配、颜色检测、形态学） | **OpenCV（Swift 封装）** 或 **Accelerate + vImage** | 原项目重度依赖 OpenCV；Vision 框架适合 ML 检测，**不适合**直接替代 `matchTemplate` |
| 像素数组运算 | **Accelerate / vDSP** | 辅助颜色阈值、轮廓分析 |

> **建议**：图像检测模块优先引入 OpenCV（通过 Swift Package 或 CocoaPods 的 opencv2.framework），保持算法逻辑与 Python 版一致，降低迁移误差。

### 3.2 模拟输入与辅助功能

| 能力 | 推荐框架 | 说明 |
|------|----------|------|
| 键盘模拟 | **CoreGraphics `CGEvent`** | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` |
| 鼠标模拟 | **CoreGraphics `CGEvent`** | `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` |
| 权限检查 | **ApplicationServices `AXIsProcessTrustedWithOptions`** | 辅助功能权限，用户需在「系统设置 → 隐私与安全性 → 辅助功能」勾选 |
| 发送到特定进程（后台） | **`CGEvent.postToPid(_:_:)`** | 取决于游戏渲染框架，可能无法后台收事件；需实测 |

### 3.3 窗口管理

| 能力 | 推荐 API | 说明 |
|------|----------|------|
| 枚举窗口 / 按标题查找 | **`CGWindowListCopyWindowInfo`** + **`NSRunningApplication`** | 替代 pywin32 `EnumWindows` |
| 窗口置前 | **`NSRunningApplication.activate`** + **`AXUIElement`** | 替代 `SetForegroundWindow`；macOS 限制较多 |
| 获取窗口客户区坐标 | **`CGWindowListCopyWindowInfo` 的 kCGWindowBounds** | 注意 Retina 缩放因子 |

### 3.4 UI 与配置

| 能力 | 推荐框架 | 说明 |
|------|----------|------|
| 图形界面 | **SwiftUI** | 替代 PyQt6 |
| 配置持久化 | **UserDefaults** 或 **JSON + Codable** | 替代 INI（`settings.ini`） |
| 后台任务 | **`Task` / `actor` / `DispatchQueue`** | 替代 Python `threading` / `QThread` |
| 日志 | **`ObservableObject` + `@Published`** | 替代 `Logger` 类 + QTextEdit |

---

## 4. macOS 坐标与截图规范（不严格复刻 Python）

> **原则：** 所有检测与点击在同一套「窗口截图像素坐标系」内完成，按 macOS 平台惯例实现，**不必**与 Windows 的 `GetClientRect` / 屏幕绝对坐标逻辑一一对应。

### 4.1 截图流水线（硬性要求）

```
ScreenCaptureKit（按 windowID 截取窗口内容）
    → CGImage
    → OpenCV Mat（BGR，统一转换）
    → 检测算法（模板匹配 / 颜色阈值）
```

- **禁止** 在未做 BGR 转换的情况下直接使用 `CGImage` 像素跑 OpenCV 阈值。
- 阶段 4 必须提供 `ImagePipeline.cgImageToBGRMat(_:)` 并通过单元测试（已知黄点/传送门样本图）。

### 4.2 坐标系策略

| 用途 | 规范 |
|------|------|
| 模板匹配 / 颜色检测 | 相对于**窗口截图**左上角，单位：**物理像素** |
| 鼠标点击 | 将截图内 `(x, y)` 转换为 `CGEvent` 屏幕坐标；**注意 macOS 鼠标 Y 轴原点在左下角**，需 `flipY` |
| 小地图区域 | 优先 ScreenCaptureKit 按 windowID 截全窗，再裁切子区域；不依赖 Windows 式「客户区偏移」 |
| Retina | 全程使用 `CGImage` 实际像素尺寸，不使用逻辑点 |

### 4.3 共享捕获服务

抽取 `GameCaptureService`（替代 Python 三处重复的 `capture_game_screen`）：

- 绑定 `windowID`
- 输出 `BGR Mat` + 截图宽高
- 提供 `captureRegion(_:)` 裁切小地图
- 点击坐标：`matPointToScreenPoint(_:)` 统一换算

---

## 5. Windows → macOS 能力对照表

| open-flower (Windows) | AutoBuff (macOS) | 迁移难度 |
|------------------------|------------------|----------|
| `pywin32` 窗口 API | CGWindowList + NSRunningApplication | 中 |
| `mss` 截图 | ScreenCaptureKit | 中 |
| `opencv-python` | OpenCV (Swift) | 低（算法可直搬） |
| `keyboard` / `pynput` | CGEvent | 中 |
| `pyautogui` 鼠标 | CGEvent | 低 |
| PyQt6 UI | SwiftUI | 高（UI 重写） |
| INI 配置 | Codable + JSON | 低 |
| 管理员权限 (`start_admin.bat`) | 辅助功能 + 屏幕录制权限 | — |
| DPI 感知 (`SetProcessDpiAwareness`) | Retina `@2x` 坐标换算 | 中 |

---

## 6. 原项目逐文件逐方法清单

> 以下为本仓库内**全部 Python 源文件**的方法级清单，施工时逐项打勾。

---

### 6.1 `main.py` — 程序入口

| 方法/逻辑 | 功能 | Swift 对应 |
|-----------|------|------------|
| DPI 感知设置 (`SetProcessDpiAwareness`) | Windows 高 DPI | macOS Retina 缩放处理 |
| `main()` | 创建 QApplication → MainWindow → exec | `AutoBuffApp` + `ContentView` |

---

### 6.2 `config/__init__.py` — 常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `APP_NAME` | "枫灵 MapleKeeper" | 应用名称 |
| `APP_VERSION` | "1.0.9" | 版本号 |
| `WINDOW_WIDTH/HEIGHT/X/Y` | 450/700/100/100 | 窗口尺寸（SwiftUI 用 `.frame`） |
| `DEFAULT_INTERVAL` | 5.0 | 默认释放间隔 |
| `DEFAULT_RANDOM_DELAY` | 2.0 | 默认随机延迟 |
| `MIN/MAX_INTERVAL` | 0.1 / 3600.0 | 间隔范围 |
| `THREAD_SLEEP_INTERVAL` | 0.1 | 线程轮询间隔 |
| `CYCLE_PAUSE_TIME` | 0.5 | 循环暂停 |
| `INITIAL_WAIT_TIME` | 0 | 启动前等待 |

→ Swift：`AppConstants.swift`

---

### 6.3 `models/skill_config.py` — SkillConfig

| 方法 | 功能 |
|------|------|
| `__init__(key, interval, random_delay)` | 构造 |
| `__str__` / `__repr__` | 字符串表示 |
| `to_dict()` | 序列化 |
| `from_dict(data)` | 反序列化 |

→ Swift：`SkillConfig.swift`（`Codable`）

---

### 6.4 `models/buff_config.py` — BuffConfig

| 方法 | 功能 |
|------|------|
| `__init__(enabled, key, duration)` | 构造 |
| `__str__` | 字符串表示 |
| `to_dict()` | 序列化 |
| `from_dict(data)` | 反序列化 |

→ Swift：`BuffConfig.swift`（`Codable`）

---

### 6.5 `models/game_config.py` — GameConfig

| 方法/属性 | 功能 |
|-----------|------|
| `resolution_width/height` | 游戏分辨率 |
| `backpack/ability/skill_hotkey` | 快捷键 B/Y/K（UI 中未直接使用） |
| `speed_threshold` | 速度阈值 1400（UI 隐藏字段） |
| `random_behavior_enabled/value` | 随机提前释放 |
| `set_resolution(w, h)` | 设置分辨率 |
| `get_resolution_str()` | 分辨率字符串 |
| `to_dict()` / `from_dict()` | 序列化 |

→ Swift：`GameConfig.swift`

---

### 6.6 `utils/keyboard_utils.py` — 键盘工具

| 方法/常量 | 功能 |
|-----------|------|
| `KEY_HOLD_MIN_MS / KEY_HOLD_MAX_MS` | 50~150ms 按住时间 |
| `press_key(key)` | 按下 → 随机等待 → 松开 |
| `is_key_pressed(key)` | 检测按键是否按住 |

→ Swift：`KeyboardUtils.swift`（基于 CGEvent）

---

### 6.7 `utils/screen_utils.py` — 屏幕工具

| 方法 | 功能 |
|------|------|
| `get_screen_resolution()` | 屏幕分辨率 |
| `get_window_resolution(title)` | 窗口分辨率（当前回退到屏幕） |
| `capture_screen(region)` | 区域截图（mss） |

→ Swift：`ScreenCaptureService.swift`（ScreenCaptureKit）

---

### 6.8 `utils/window_selector.py` — WindowSelector

| 方法 | 功能 |
|------|------|
| `get_all_windows()` | 枚举可见窗口，过滤小窗口，按面积排序 |
| `find_windows_by_title(pattern)` | 标题模糊匹配 |
| `auto_detect_game_window(keywords)` | 默认匹配 `"MapleStory Worlds-Artale"` 前缀 |
| `get_window_screenshot_region(hwnd)` | 客户区 → 屏幕坐标 |
| `bring_window_to_front(hwnd)` | 还原/显示/置前/聚焦 |
| `is_window_valid(hwnd)` | 窗口是否仍有效可见 |
| `get_window_info(hwnd)` | 获取标题/矩形/类名/尺寸 |

→ Swift：`WindowSelector.swift`（windowID 替代 hwnd）

---

### 6.9 `utils/settings_manager.py` — SettingsManager

| 方法 | 功能 |
|------|------|
| `save_settings(...)` | 保存 General + Buff1~6 到 INI |
| `load_settings()` | 加载全部配置 |

**General 字段：** `return_to_market`, `jump_key`, `sit_chair_enabled`, `chair_key`, `random_behavior_enabled`, `random_behavior_value`, `movement_mode`, `pre_skill_move_mode`

**Swift 额外字段：** `manualPortalX`, `manualPortalY`（可选，null=自动检测）

**已移除：** `manual_countdown`、`attack_key`、活花攻击键等待逻辑（v1.1）

**Buff 字段：** `enabled`, `key`, `duration`

→ Swift：`SettingsManager.swift`（JSON 或 UserDefaults）

---

### 6.10 `utils/logger.py` — Logger

| 方法 | 功能 |
|------|------|
| `log(message, level)` | 追加带时间戳日志 |
| `get_logs()` | 返回日志数组 |
| `get_logs_text()` | 拼接文本 |
| `clear()` | 清空 |
| `get_last_log()` | 最后一条 |

→ Swift：`AppLogger.swift`（`@Published var logs`）

---

### 6.11 `automation/human_input.py` — HumanInput ⭐核心

| 方法/属性 | 功能 | 拟人化参数 |
|-----------|------|------------|
| `direction_tap_duration` | 轻点微调 | 40~120ms |
| `direction_change_delay` | 换向延迟 | 50~200ms |
| `portal_press_duration` | 传送门上键 | 200~800ms |
| `key_offset_range` | 组合键偏移 | 10~80ms |
| `mouse_click_duration` | 鼠标按住 | 50~150ms |
| `mouse_move_steps` | 鼠标移动步数 | 3~8 |
| `_random_duration(range_ms)` | 正态分布随机时长 | — |
| `_sleep(seconds)` | 可中断睡眠 | — |
| `click_at(x, y, offset_range)` | 分步移动 + 随机偏移 + 点击 | — |
| `move_left()` / `move_right()` | 开始移动 | 换向延迟 |
| `stop_move()` | 停止移动 | — |
| `_change_direction(new)` | 先松旧键 → 延迟 → 按新键 | — |
| `use_portal()` | 停止 → 按上键 200~800ms | — |
| `tap_direction(dir)` | 轻点方向键 | — |
| `_get_key_object(dir)` | left/right/up/down 映射 | — |
| `release_all()` | 释放所有方向键 | 线程安全 |

→ Swift：`HumanInput.swift`（actor + CGEvent）

---

### 6.12 `detection/minimap_monitor.py` — MinimapMonitor ⭐核心

| 方法 | 功能 |
|------|------|
| `set_window_handle(hwnd)` | 绑定游戏窗口 |
| `set_minimap_region(x,y,w,h)` | 手动设置小地图区域 |
| `get_minimap_size()` | 返回 (w, h) |
| `auto_detect_dark_region(...)` | 左上角 400×400 搜索 → 二值化 → 连通域 → 最大矩形深色区域 |
| `capture_minimap()` | 截取小地图 BGR 图像 |
| `find_player_position()` | BGR 黄色阈值 → 最大轮廓质心 |
| `find_blue_portal(find_leftmost)` | HSV 蓝色阈值 → 最左或最大传送门 |
| `debug_save_minimap()` | 初始化检测（区域+传送门+玩家） |
| `capture_game_screen()` | 截取整个游戏客户区 |
| `find_template_on_screen(path, threshold)` | 单尺度模板匹配 → 屏幕绝对坐标 |
| `find_template_center(path, threshold)` | 模板中心坐标 |
| `find_template_multiscale(...)` | 多尺度宽高独立缩放匹配 |

**颜色阈值（必须原样移植）：**
- 玩家黄点 BGR：`[0,240,240]` ~ `[30,255,255]`
- 传送门 HSV：`[90,100,100]` ~ `[130,255,255]`
- 深色阈值：灰度 < 100

→ Swift：`MinimapMonitor.swift`

---

### 6.13 `detection/market_button.py` — MarketButtonDetector ⭐核心

| 方法 | 功能 |
|------|------|
| `set_window_handle(hwnd)` | 绑定窗口 |
| `is_template_exists()` | 检查 market_btn.png |
| `capture_game_screen()` | 截取游戏画面 |
| `find_market_button_in_game()` | 底部 15% 区域多尺度匹配 |
| `find_market_button()` | 返回屏幕绝对坐标 |
| `capture_minimap_region()` | 左上角 200×150 |
| `is_market_logo_visible(confidence)` | 完整模板 + 下半部分模板（应对公告遮挡） |
| `_match_logo_multiscale(region, template)` | Logo 多尺度匹配 |
| `is_in_market_by_minimap(confidence)` | 小地图模板匹配（备用方法） |
| `debug_find_market_button()` | 调试：画框保存截图 |

**模板路径：**
- `templates/market/market_btn.png`
- `templates/market/market_logo.png`
- `templates/minimap/market_minimap.png`

→ Swift：`MarketButtonDetector.swift`

---

### 6.14 `detection/dialog_detector.py` — DialogDetector

| 方法 | 功能 |
|------|------|
| `set_window_handle(hwnd)` | 绑定窗口 |
| `capture_game_screen()` | 截取游戏画面 |
| `find_confirm_button()` | 中间偏下 30% 以下区域多尺度匹配 confirm_btn.png |
| `find_and_click_confirm(human_input)` | 找到则拟人化点击 |

→ Swift：`DialogDetector.swift`

---

### 6.15 `workers/skill_worker.py` — SkillWorker（活花模式）⭐核心

| 方法/信号 | 功能 |
|-----------|------|
| **信号** `status_update`, `skill_pressed`, `error_occurred`, `countdown_update` | UI 回调 |
| `MOVEMENT_NONE/RIGHT/LEFT` | 移动模式常量 |
| `__init__(skills, window_selector, hwnd, movement_mode, sit_chair...)` | 初始化 |
| `_resolve_key(key_str)` | 特殊键映射 |
| `_sit_chair()` | 空闲坐椅子 |
| `start()` / `stop()` | 启停线程 |
| `_run_loop()` | 主循环：初始化批量释放 → 轮询到期技能 |
| `_release_skills_batch(...)` | 聚焦窗口 → 前移动 → 批量按键 → 后移动 |
| `_release_single_skill_only(skill)` | 双次按键（间隔 100~300ms） |
| `_release_skill(skill)` | 单技能释放（委托 batch） |
| `_move_before_skill()` / `_move_after_skill()` | 根据 movement_mode 移动 |
| `_move_direction(dir, min_ms, max_ms)` | 按住方向键移动 |
| `_ensure_game_window_focus()` | 窗口置前 |

**时间常量：**
- 技能间隔：2000~3000ms
- 释放前右移：500~1000ms
- 释放后左移：2000~3000ms

→ Swift：`LiveFlowerWorker.swift`（`ObservableObject` 或 `actor`）

---

### 6.16 `workers/dead_flower_worker.py` — DeadFlowerWorker（死花模式）⭐最复杂

| 方法/信号 | 功能 |
|-----------|------|
| **信号** `log_update`, `finished_signal`, `error_signal`, `countdown_update` | UI 回调 |
| `__init__(hwnd, buffs, jump_key, sit_chair..., pre_skill_move_mode, manual_portal_pos)` | 初始化 + 缓存 |
| `_bring_window_to_front()` | 窗口置前 |
| `_interruptible_sleep(seconds)` | 100ms 步进 + 每秒更新倒计时 |
| `_random_sleep(min, max)` | 随机延迟 |
| `_is_market_logo_visible()` | Logo 检测 |
| `_is_in_market()` | Logo + 按钮 = 在市场 |
| `_is_market_btn_visible()` | 按钮可见 |
| `_is_in_monster_map()` | 无 Logo + 有按钮 = 怪物地图 |
| `_get_window_size()` / `_check_window_size_changed()` | 窗口大小缓存失效 |
| `_get_market_button_pos()` | 屏幕坐标（缓存） |
| `_get_market_button_in_game_pos()` | 游戏内坐标（缓存） |
| `_get_portal_pos()` | 传送门坐标（手动 > 缓存 > 自动） |
| `_get_buffs_to_cast(include_upcoming)` | 到期或 10 秒内到期 |
| `_resolve_key(key_str)` | 特殊键映射 |
| `_cast_buff(buff)` | 拟人化按键 + 更新下次时间 |
| `_cast_all_ready_buffs()` | 批量释放（间隔 1~2s） |
| `_move_right_before_skill()` | 出市场后右微调 100~300ms |
| `_move_left_wiggle()` | 左微调 100~300ms |
| `_sit_chair()` | 空闲坐椅子 |
| `_jump_before_move()` | 跳跃拟人化（代码中有定义，主循环未调用） |
| `_return_to_market()` | 找按钮 → 2~3 次点击 → 等黑屏 2.5s → 检测回到市场 |
| `_leave_market()` | 导航到传送门 → 进入 → 等黑屏 → 检测离开市场 |
| `_update_countdown_display()` | 发送倒计时 |
| `_get_time_until_next_cast()` | 最近到期时间 |
| `run()` | **主循环**（见下方流程） |
| `stop()` | 停止 + release_all |

**死花主循环逻辑：**
```
while running:
  if 有 buff 到期:
    if 在怪物地图 → 直接释放
    elif 在市场 → 离开市场 → 出市场移动 → 释放 → 回市场
    elif 未知 → 等待 2s
  else:
    空闲等待 + 弹窗检测(每5s) + 坐椅子
```

**导航参数：** TOLERANCE=5, BATCH_CAST_WINDOW=10s, BLACK_SCREEN_WAIT=2.5s, STUCK_THRESHOLD=5

→ Swift：`DeadFlowerWorker.swift`

---

### 6.17 `workers/market_worker.py` — MarketWorker（调试）

| 方法 | 功能 |
|------|------|
| `_bring_window_to_front()` | 窗口置前 |
| `run()` | 初始化小地图 → 找传送门 → 导航 → 进入 |
| `_random_sleep(min_ms, max_ms)` | 随机延迟 |
| `stop()` | 停止 |

→ Swift：合并到调试模块 `DebugTools.swift`

---

### 6.18 `ui/main_window.py` — MainWindow ⭐UI 核心

| 方法 | 功能 |
|------|------|
| `load_default_config()` | 加载设置或默认 |
| `_apply_saved_settings()` / `_apply_default_settings()` | 应用配置 |
| `save_settings()` | 保存到 INI |
| `init_ui()` | 暗色主题 UI 构建 |
| `_apply_dark_theme()` | QSS 样式 |
| `_create_header()` | 标题栏 + 窗口状态 |
| `_create_mode_tabs()` | 死花/活花 Tab |
| `_switch_mode_tab()` / `_update_mode_tab_style()` | 模式切换 |
| `create_settings_section()` | Buff 配置 + 高级设置 |
| `create_control_section()` | 识别/标记/开始/调试按钮 |
| `create_log_section()` | 日志区 |
| `on_buff_toggled/key/duration` | Buff 配置回调 |
| `on_movement_mode_changed()` | 活花移动模式 |
| `on_pre_skill_move_mode_changed()` | 死花出市场模式 |
| `auto_identify_on_startup()` | 启动自动识别窗口 |
| `on_identify_window()` | 手动识别 |
| `on_mark_portal()` | 打开传送门标记对话框 |
| `on_toggle_worker()` / `start_worker()` / `stop_worker()` | 启停 |
| `on_countdown_update()` | 倒计时 UI 更新（颜色分级） |
| `start_test_market_nav()` | 调试：离开市场 |
| `start_test_return_to_market()` | 调试：回到市场 |
| `start_test_dismiss_dialog()` | 调试：关闭弹窗 |
| `on_select_jump_key()` / `on_select_chair_key()` | 虚拟键盘选键 |
| `closeEvent()` | 关闭时保存设置 + 停止 worker |

→ Swift：`ContentView.swift` + 多个子 View + `MainViewModel.swift`

---

### 6.19 `ui/virtual_keyboard.py` — VirtualKeyboardDialog

| 方法 | 功能 |
|------|------|
| `init_ui()` | 750×380 键盘布局 |
| `create_main_keyboard()` | 主键盘区（Esc, F1-F12, 字母数字, Ctrl/Alt/Space） |
| `create_right_section()` | 右侧功能键 + 方向键 |
| `add_key()` / `create_key_button()` | 创建按键 |
| `on_key_clicked(key)` | 选择高亮 |
| `get_selected_key()` | 返回选中键 |

→ Swift：`VirtualKeyboardView.swift`（Sheet）

---

### 6.20 `ui/portal_marker_dialog.py` — PortalMarkerDialog

| 类/方法 | 功能 |
|---------|------|
| `ClickableImageLabel` | 可点击图片 |
| `PortalMarkerDialog.__init__()` | 2 倍放大小地图 |
| `_on_image_clicked()` | 点击 → 原始坐标 |
| `_update_image()` | 蓝点=自动，红点=手动 |
| `_on_confirm()` / `_on_clear()` | 确认/清除 |
| `get_marked_position()` | 返回结果 |

→ Swift：`PortalMarkerView.swift`

---

### 6.21 其他文件

| 文件 | 说明 | 是否迁移 |
|------|------|----------|
| `hooks/runtime_hook.py` | PyInstaller numpy 修复 | ❌ 不需要 |
| `build.spec` | PyInstaller 打包 | ❌ 改用 Xcode Archive |
| `start_admin.bat` | 管理员启动 | ❌ macOS 用权限引导 |
| `requirements.txt` | Python 依赖 | ❌ 改用 Swift Package |
| `小地图匹配与寻路方案详解.md` | 集成文档（maps/shichang） | ⚠️ 参考，当前代码未直接使用 maps 目录 |

---

## 7. AutoBuff 目标目录结构

```
AutoBuff/
├── AutoBuff/
│   ├── AutoBuffApp.swift
│   ├── ContentView.swift
│   ├── Constants/
│   │   ├── AppConstants.swift
│   │   └── KeyCodeMap.swift              # 虚拟键码映射
│   ├── Models/
│   │   ├── BuffConfig.swift
│   │   ├── SkillConfig.swift
│   │   └── GameConfig.swift
│   ├── Services/
│   │   ├── SettingsManager.swift
│   │   ├── PermissionManager.swift       # 屏幕录制 + 辅助功能
│   │   ├── WindowSelector.swift          # 含手动选窗
│   │   ├── GameCaptureService.swift      # 统一截图 → BGR Mat
│   │   ├── ImagePipeline.swift           # CGImage ↔ BGR Mat 转换
│   │   ├── HumanInput.swift              # actor + CGEvent
│   │   └── KeyboardUtils.swift
│   ├── Detection/
│   │   ├── MinimapMonitor.swift
│   │   ├── MarketButtonDetector.swift
│   │   └── DialogDetector.swift
│   ├── Workers/
│   │   ├── LiveFlowerWorker.swift
│   │   ├── DeadFlowerWorker.swift
│   │   └── DebugTools.swift
│   ├── ViewModels/
│   │   └── MainViewModel.swift
│   ├── Views/
│   │   ├── DebugPanelView.swift          # 早期调试：截图预览 + 检测 overlay
│   │   ├── SettingsSectionView.swift
│   │   ├── LogSectionView.swift
│   │   ├── WindowPickerView.swift        # 手动选择游戏窗口
│   │   ├── VirtualKeyboardView.swift
│   │   └── PortalMarkerView.swift
│   ├── Utilities/
│   │   └── AppLogger.swift
│   ├── Resources/
│   │   └── Templates/                    # git pull 获取
│   └── AutoBuff.entitlements
├── MIGRATION_PLAN.md
└── AutoBuff.xcodeproj
```

---

## 8. 分步骤迁移计划

> **最低系统版本：macOS 14.0**（使用 `SCScreenshotManager` 简化截图；若需支持 13，改用 `SCStream` 并增加适配分支）

### 阶段 0：环境与 Spike（第 1 步）

- [ ] **0.1** Xcode 15+，Deployment Target **macOS 14.0**
- [ ] **0.2** `git pull` 拉取 `open-flower/templates/` 模板资源，复制到 `Resources/Templates/`
- [ ] **0.3** **OpenCV Spike（阻塞项）**：选定集成方式（SPM 社区包 / 手动 framework），跑通 `matchTemplate`  hello world
- [ ] **0.4** 配置 `Info.plist`：`NSScreenCaptureDescription`
- [ ] **0.5** 配置 `AutoBuff.entitlements`（关闭 App Sandbox，见第 9 节）
- [ ] **0.6** 实现 `PermissionManager`：辅助功能 + 试截屏验证屏幕录制权限

**验收：** OpenCV 可编译；权限引导可用；模板 PNG 已就位。

---

### 阶段 1：数据模型与配置（第 2 步）

- [ ] **1.1** `BuffConfig`、`SkillConfig`、`GameConfig`（Codable）
- [ ] **1.2** `AppConstants.swift`
- [ ] **1.3** `SettingsManager` → `Application Support/AutoBuff/settings.json`
  - 含 `randomBehaviorEnabled/Value`、`manualPortalX/Y`
  - **不含** `manualCountdown`
- [ ] **1.4** `AppLogger`（`@Published`）
- [ ] **1.5** 单元测试：配置读写往返

**验收：** 字段与修正后 Python 版 `settings.ini` 一致（+ Swift 额外 portal 字段）。

---

### 阶段 2：最小 Debug UI（第 3 步）— 新增

- [ ] **2.1** `DebugPanelView`：窗口状态 + 日志 + 截图预览按钮
- [ ] **2.2** `MainViewModel` 骨架
- [ ] **2.3** 后续阶段在此 UI 上叠加功能，避免「盲写底层」

**验收：** App 可启动，日志区可见，布局可扩展。

---

### 阶段 3：窗口识别（第 4 步）

- [ ] **3.1** `WindowSelector`：`getAllWindows`、`autoDetectGameWindow`、手动选窗
- [ ] **3.2** `WindowPickerView`：列表选择游戏窗口
- [ ] **3.3** `bringWindowToFront`、`isWindowValid`

**验收：** 自动识别 + 手动选窗均可用。

---

### 阶段 4：截图与图像管道（第 5 步）— 含硬性 BGR 步骤

- [ ] **4.1** `GameCaptureService`：ScreenCaptureKit 按 windowID 截窗
- [ ] **4.2** `ImagePipeline.cgImageToBGRMat(_:)` — **硬性步骤，所有检测必须经过此函数**
- [ ] **4.3** `captureRegion(_:)` 小地图裁切
- [ ] **4.4** `matPointToScreenPoint(_:)` 坐标换算（含 Y 轴 flip）
- [ ] **4.5** Debug UI 显示截图 + 像素尺寸

**验收：** 截图预览正确；BGR 转换单元测试通过；Retina 下像素尺寸与 `CGImage.width` 一致。

---

### 阶段 5：拟人化输入（第 6 步）

- [ ] **5.1** `KeyCodeMap.swift` 完整虚拟键码表
- [ ] **5.2** `KeyboardUtils.pressKey`（50~150ms）
- [ ] **5.3** `HumanInput` actor：完整移植拟人化参数与方法
- [ ] **5.4** `clickAt` 分步移动 + Y 轴 flip
- [ ] **5.5** `releaseAll()`

**验收：** 方向键、上键传送门、鼠标点击、双次 Buff 按键手动测试通过。

---

### 阶段 6：图像检测（第 7 步）

- [ ] **6.1** `MinimapMonitor`（基于 `GameCaptureService`，不各自截图）
- [ ] **6.2** `MarketButtonDetector`
- [ ] **6.3** `DialogDetector`
- [ ] **6.4** Debug UI 叠加检测结果（框/点）

**验收：** 市场内 Logo、按钮、传送门、黄点检测可视化正确。

---

### 阶段 7：活花 Worker（第 8 步）

- [ ] **7.1** `LiveFlowerWorker`（`Task` + `@MainActor` 回调）
- [ ] **7.2** 读取 `randomBehaviorEnabled/Value` → `SkillConfig.randomDelay`
- [ ] **7.3** 三种 `movementMode`

**验收：** 活花完整循环 + 随机提前释放 + 倒计时 UI。

---

### 阶段 8：死花 Worker（第 9 步）

- [ ] **8.1** `DeadFlowerWorker` 完整主循环
- [ ] **8.2** 场景判断、离开/回到市场、导航卡住重试
- [ ] **8.3** `manualPortalX/Y` 持久化读取
- [ ] **8.4** 空闲弹窗检测 + 坐椅子

**验收：** 连续 3 轮死花循环无卡死。

---

### 阶段 9：完整 SwiftUI 主界面（第 10 步）

- [ ] **9.1** 合并 Debug UI 为正式暗色主题界面
- [ ] **9.2** 死花/活花 Tab、Buff 配置、虚拟键盘、传送门标记
- [ ] **9.3** 调试工具折叠区
- [ ] **9.4** 关闭 App 自动保存

**验收：** UI 与 Python 版功能一一对应。

---

### 阶段 10：测试与发布（第 11 步）

- [ ] **10.1** 活花/死花各 30 分钟稳定性测试
- [ ] **10.2** Retina + 多显示器 + 全屏 Spaces
- [ ] **10.3** 权限撤销 graceful 降级
- [ ] **10.4** Archive + 公证（如需分发）

---

## 9. 权限与 Entitlements 配置

当前 `AutoBuff.entitlements` 为空，施工时需添加：

```xml
<!-- 辅助功能：CGEvent 模拟输入 -->
<!-- 无需 entitlement 条目，但运行时必须 AXIsProcessTrusted -->

<!-- 屏幕录制：ScreenCaptureKit -->
<!-- 无需 entitlement 条目，但 Info.plist 需 NSScreenCaptureDescription -->

<!-- 如需沙盒外分发，建议关闭 App Sandbox 或添加： -->
<key>com.apple.security.app-sandbox</key>
<false/>
```

**代码示例（权限检查）：**

```swift
import ApplicationServices

func requestAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}
```

**注意：** macOS 没有 Windows 的「管理员权限」概念；辅助功能 + 屏幕录制 = 等价权限组合。

---

## 10. 资源文件迁移清单

从 `open-flower/templates/` 复制到 `AutoBuff/AutoBuff/Resources/Templates/`（**`git pull` 后获取**）：

| 文件 | 用途 | 必须 |
|------|------|------|
| `market/market_btn.png` | 自由市场按钮模板 | ✅ |
| `market/market_logo.png` | 市场 Logo 检测 | ✅ |
| `dialog/confirm_btn.png` | 確定按钮 | ✅ |
| `minimap/market_minimap.png` | 市场小地图模板（备用） | ⚠️ 可选 |
| `maps/shichang_full.png` | 完整小地图（文档用） | ❌ 当前代码未用 |
| `maps/shichang_config.json` | 地图配置（文档用） | ❌ 当前代码未用 |

> **获取方式：** 在 `open-flower` 目录执行 `git pull`，模板 PNG 随仓库更新。

---

## 11. 风险点与待验证项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|----------|
| 1 | **OpenCV 集成** — 无官方 SPM | 阶段 0 阻塞 | 阶段 0 Spike 先行；备选自研 `matchTemplate` |
| 2 | **后台按键** — CGEvent 需前台 | 自动化中断 | 强制 `bringWindowToFront`；可选 `postToPid` 实测 |
| 3 | **Retina + Y 轴翻转** | 点击偏移 | `ImagePipeline` 统一换算；阶段 4/5 点击验收 |
| 4 | **BGR 颜色空间** | 检测全失效 | 硬性 `cgImageToBGRMat` 管道 |
| 5 | **ScreenCaptureKit 延迟** | 导航卡顿 | 仅截小地图区域；导航时降低全窗截图频率 |
| 6 | **窗口标题变化** | 自动识别失败 | 手动选窗（阶段 3 必做） |
| 7 | **全屏 / Spaces** | windowID 失效 | 监听窗口变化；提示用户窗口模式 |
| 8 | **屏幕录制权限** — 无查询 API | 无法预判 | 试截屏 + 友好错误提示 |
| 9 | **Python `debug_find_market_button`** — `SCREENSHOTS_DIR` 未定义 | 仅影响 Python 调试 | Swift 版写入 Application Support |

---

## 12. 迁移验收核对表

施工完成后，逐项打勾：

### 基础
- [ ] App 启动无崩溃
- [ ] 屏幕录制权限引导正常
- [ ] 辅助功能权限引导正常
- [ ] 设置保存/加载与 Python 版字段一致

### 窗口
- [ ] 自动识别 MapleStory Worlds-Artale 窗口
- [ ] **手动选择窗口**（WindowPickerView）
- [ ] 窗口关闭后重新识别

### 图像管道
- [ ] `cgImageToBGRMat` 转换正确
- [ ] 模板匹配 + 颜色检测在 Debug UI 可视化
- [ ] 鼠标点击位置与检测框对齐（Y 轴 flip 验收）

### 活花模式
- [ ] 6 个 Buff 独立计时
- [ ] 双次按键释放
- [ ] 三种移动模式（none/right/left）
- [ ] **随机提前释放**（读取 `randomBehaviorEnabled/Value`，非硬编码）
- [ ] 空闲坐椅子
- [ ] 倒计时 UI 颜色分级
- [ ] 停止后 releaseAll

### 死花模式
- [ ] 市场/怪物地图场景判断
- [ ] 离开市场（传送门导航 + 卡住重试）
- [ ] 出市场后移动（right_left / left_only）
- [ ] Buff 批量释放
- [ ] 回到市场（多次点击 + 场景确认）
- [ ] 窗口大小变化后缓存失效
- [ ] 手动标记传送门（**持久化到 settings.json**）
- [ ] 空闲弹窗自动关闭
- [ ] 空闲坐椅子

### 调试
- [ ] 测试离开市场
- [ ] 测试回到市场
- [ ] 测试关闭弹窗

### UI
- [ ] 虚拟键盘选键
- [ ] 传送门标记对话框
- [ ] 日志实时更新
- [ ] 死花/活花 Tab 切换

---

## 附录 A：虚拟键码映射参考（Swift 施工用）

| Python 键名 | macOS virtualKeyCode |
|-------------|---------------------|
| left/right/up/down | 0x7B / 0x7C / 0x7E / 0x7D |
| space | 0x31 |
| return/enter | 0x24 |
| tab | 0x30 |
| escape | 0x35 |
| ctrl | 0x3B (left) |
| alt/option | 0x3A (left) |
| shift | 0x38 (left) |
| 0-9 | 0x1D ~ 0x26 |
| A-Z | 0x00 ~ 0x19 (需查 kVK_ANSI_* 表) |
| F1-F12 | 0x7A, 0x78, ... |

完整映射表施工时在 `KeyCodeMap.swift` 中维护。

---

## 附录 B：Python 依赖 → Swift 依赖

| Python | Swift 替代 |
|--------|-----------|
| PyQt6 | SwiftUI (系统内置) |
| keyboard | CGEvent |
| pynput | CGEvent |
| pywin32 | CGWindowList + NSRunningApplication |
| opencv-contrib-python | OpenCV Swift / opencv2.framework |
| numpy | OpenCV Mat / Accelerate |
| mss | ScreenCaptureKit |
| pillow | CoreGraphics / NSImage |
| pyautogui | CGEvent |
| configparser | Codable + JSONEncoder |

---

**文档版本：** 1.1  
**更新日期：** 2026-06-06  
**基于 open-flower 版本：** v1.0.9（含 Python 基线修正）  
**目标项目：** AutoBuff (Swift/macOS 14+)

> 请在本文件上逐项打勾核对。确认无误后再按「阶段 0 → 阶段 10」顺序施工。
