# Adb Quick

macOS Swift 应用：借助 scrcpy server 端投屏并控制 Android 设备。

## 功能

- **设备列表**：居中 360 宽窗口，展示已连接 ADB 设备，右侧箭头选择，行底分隔线。
- **实时渲染**：拿到视频尺寸后再显示（无跳变）；VideoToolbox 硬解 H.264；旋转自动适配。
- **输入映射**：鼠标 → 触摸（含 Y 轴翻转修正）；滚轮 → 滚动；ESC/Backspace=返回、Cmd+Shift+H=主页、Cmd+Shift+R=旋转。
- **双向剪贴板**：电脑 Cmd+V → 手机；手机复制 → 电脑剪贴板。
- **控制面板**（Cmd+K，可置顶）：设备名/尺寸、当前操作 + 绝对/相对坐标；按钮：主页/返回/旋转/电源/截图/录制/回放。
- **截图**：`adb screencap` 存 PNG，目录可配置（默认下载），保存后 Finder 定位。
- **脚本录制/回放**：录制控制操作存 JSON，回放按时间轴重放；窗口标题显示「录制中/回放中」。
- **条件回放**：仅支持 JSON v3；combat 使用 `while` / `skill_check` DSL，pickup 使用 `while` / `ocr_text` / `drag` DSL；支持嵌套、重复、技能区域、优先级、间隔和次数；从 scrcpy 解码帧调用持久 Python YOLO 分类器，点击首个可用技能；再次点击回放可停止。
- **设置**：ADB 路径、scrcpy-server 路径、截图目录、wuwa_classify 项目目录。

## 技术

- 纯 Swift（AppKit），无第三方依赖（图标处理用 ImageMagick）。
- 对接 scrcpy 5.0：push server、adb reverse 隧道、视频/控制双连接。
- 解码：VTDecompressionSession 输出像素帧，AVSampleBufferDisplayLayer 显示；Annex-B→AVCC 单次遍历。
- 关闭窗口：shutdown 打断 socket、移除 readabilityHandler、延迟释放 delegate，避免崩溃。
- 构建：`./build.sh`（可执行）/ `./build_app.sh`（.app，含圆角图标）。
