# 模板图片

当前目录包含从 `open-flower/templates/` 迁移的三个运行时模板：

- `market/market_btn.png` — 自由市场按钮
- `market/market_logo.png` — 市场 Logo
- `dialog/confirm_btn.png` — 弹窗「确定」按钮

Xcode 的文件系统同步分组会将 PNG 复制到 App Bundle 的 Resources 根目录，
`TemplatePaths` 同时兼容源码子目录和 Bundle 扁平目录。

游戏 UI 更新或缩放方式改变后，应重新截取紧边界、无遮挡的模板。没有这些
文件时 App 仍可编译，但死花模式的市场和弹窗检测会失效。
