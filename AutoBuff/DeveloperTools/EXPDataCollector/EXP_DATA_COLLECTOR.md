# EXP 数据采集器

这是一个仅供数据采集使用的独立开发工具，不参与正式游戏操作逻辑。

## 数据位置

运行后数据默认保存在：

`~/Library/Application Support/AutoBuff/EXP-Dataset/`

- `rows/auto/`：连续三帧一致且达到置信度要求的整行文字。
- `chars/auto/<字符>/`：Vision 自动定位并分类的字符。
- `context/auto/`：自动样本对应的下方中央搜索区域。
- `review/`：疑似 EXP 但格式或置信度未通过的样本。
- `manifest.jsonl`：样本标签、置信度和文件路径。

`auto` 数据属于程序自动标注结果，正式制作模板或训练集前仍应抽查。

## 删除

以后不再需要采集功能时：

1. 删除整个 `DeveloperTools/EXPDataCollector/` 目录。
2. 删除 `MainViewModel` 中带有 `expDataCollection` 的属性和方法。
3. 删除 `DebugPanelView` 中的“EXP 样本采集”区块。

正式识别、截图和工作模式不依赖这个目录。
