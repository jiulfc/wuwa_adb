# Adb Quick

一个运行在 macOS 上的 Swift 应用：借助 **scrcpy 的 server 端**，把 Android 设备屏幕实时投屏到窗口，并支持触摸控制。

- 启动后弹出居中的、宽度 360 的窗口，以列表展示已连接的 ADB 设备。
- 每行右侧有一个箭头，点击后关闭列表窗口，打开实时渲染窗口（大小 = 设备大小，方向 = 设备方向）。
- 应用菜单里有「设置」，可指定本地 `adb` 命令的位置（以及 `scrcpy-server` 路径）。
- 设置中的「连接后关闭手机屏幕」默认开启：收到首个视频帧后通过 scrcpy 关闭手机实体屏幕，电脑投屏和控制继续运行。取消勾选则不更改手机屏幕状态；保存后下次连接生效。

## 前置依赖

- macOS 12+（使用 AppKit / VideoToolbox 硬件解码 H.264）
- 已安装 [scrcpy](https://github.com/Genymobile/scrcpy)（需要其 server 文件 `scrcpy-server`，默认位置：
  `/opt/homebrew/share/scrcpy/scrcpy-server` 或 `/usr/local/share/scrcpy/scrcpy-server`）
- 已安装 `adb`（默认从 `~/Library/Android/sdk/platform-tools/adb` 等常见位置自动探测，可在设置中修改）
- 已通过 USB 或无线连接并授权一台 Android 设备

## 构建

```bash
./build.sh        # 仅编译可执行文件 AdbQuick
./build_app.sh    # 打包成 AdbQuick.app（已做 ad-hoc 签名）
```

> 说明：本机沙箱下 `swift build` 的模块缓存目录不可写，因此 `build.sh` 直接用
> `swiftc -module-cache-path` 编译，缓存存放于 `.clangcache` 下按项目绝对路径区分的子目录，避免搬迁后复用失效缓存，并避免依赖 SwiftPM。

## 运行

```bash
./AdbQuick                 # 直接运行可执行文件
open AdbQuick.app          # 或双击 .app
```

## 操作

| 操作 | 效果 |
| --- | --- |
| 鼠标按下 / 拖动 / 抬起 | 对应设备上的触摸 down / move / up |
| 滚轮 / 触控板滚动 | 注入滚动事件 |
| `ESC` 或 `Backspace` | 返回键（Back） |
| `Cmd+Shift+H` | 主页键（Home） |
| `Cmd+Shift+R` | 旋转设备（演示方向切换） |
| `Cmd+O` | 打开 v3 流程编排器 |

流程编排器可从「视图 → 流程编排器」打开。它支持拖放全部 v3 命令、编辑嵌套步骤和变量，也可直接编辑完整 JSON；打开、校验和保存均复用应用内的 v3 解析器。只有通过校验的 JSON 才会写入文件。

## 实现要点

- 目录 `Sources/` 下为全部源码，纯 AppKit，无第三方依赖。
- 协议对接 scrcpy **5.0.1**（server 版本号 `5.0.1` 必须与本地 scrcpy-server 保持一致）：
  1. `adb push` 推送 `scrcpy-server` 到 `/data/local/tmp/scrcpy-server.jar`；
  2. `adb reverse localabstract:scrcpy_<scid> tcp:<port>` 建立反向隧道；
  3. 本机 `TcpServer` 监听随机端口，依次接受视频、控制两条连接；
  4. 视频流：读取 64 字节设备名 → 4 字节编解码器 id → 12 字节会话包/帧头 → H.264 裸流；
  5. 用 `CMVideoFormatDescriptionCreateFromH264ParameterSets` 解析 SPS/PPS，把 Annex-B 转成
     AVCC 后封装成 `CMSampleBuffer`，交给 `VTDecompressionSession` 解码，像素帧由 `AVSampleBufferDisplayLayer` 显示并供条件回放取图；
  6. 控制流：按 scrcpy 控制协议序列化触摸/按键/滚动消息写入控制 socket。

- 旋转：设备旋转时 server 会发送新的会话包（含新的宽高），应用据此重建解码器并调整窗口尺寸。

## 已知限制

- 编译时 `AVSampleBufferDisplayLayer.enqueue/flush` 在 macOS 15 上会提示已弃用，但功能正常
  （仅警告，可继续使用）。
- 暂未实现音频、剪贴板同步、键盘全键位映射等高级功能。

## 录制脚本重复回放（JSON v3）

录制只生成 JSON v3 事件脚本。可选的顶层整数 `repeatCount`：例如 `"repeatCount": 3` 表示完整播放 `events` 共 3 次。省略或值不大于 1 时只播放一次。每轮保留事件的相对时间，最后一个事件后保留原有的 0.1 秒余量，再开始下一轮；空事件列表直接结束。再次点击回放可取消剩余轮次。

## 流程回放（JSON v3）

仅支持 JSON v3，v1/v2 会被拒绝。v3 包含 `events` 录制脚本、`vars` / `steps` DSL 和 `script_loop_count` / `run` 顺序流程；加载器按顶层字段区分格式。旧 `type: "battle"` / `type: "pickup"` 格式已移除。

### vars / steps DSL

```json
{
  "version": 3,
  "vars": { "count": 0, "text": "", "number": 0, "text_roi": [100, 200, 300, 80] },
  "steps": [
    { "type": "assign", "target": "${count}", "value": "${count + 1}" },
    { "type": "ocr_text", "roi": "${text_roi}", "output": "${text}" },
    { "type": "ocr_text", "roi": "${text_roi}", "output": "${number:int}" },
    { "type": "if", "condition": "${text == 'DONE'}", "then": [{ "type": "return" }] },
    { "type": "tap", "point": [250, 240], "duration_ms": 100 },
    { "type": "wait", "wait_ms": 500 }
  ]
}
```

DSL 回放支持 `assign`、`while`、`if`、`run_for`、`run_until`、`script`、`tap`、`drag`、`wait`、`break`、`continue`、`return` 和受限表达式。`run_for` 在 `duration_ms` 后取消其 `steps` 并继续；`run_until` 运行 `steps`，同时每隔 `check_every_ms` 执行 `check`，`until` 匹配后取消 `steps` 并继续，达到 `timeout_ms` 则报错。`vars` 可以保存 JSON 数组，ROI、点位等字段可直接使用 `"${roi}"` 引用。`ocr_text` 默认返回字符串；`output` 使用 `${name:int}` 或 `${name:double}` 时，会把去除首尾空白的完整 OCR 结果解析为数字，空值或非数字会终止流程。

`circle_percentage` 的 `default` profile 读取固定 72×72 ROI 内半径 30–36 px 的有色圆环，红、绿、蓝等颜色都会计入，白色、半透明白色和灰色不计，返回 `0.0`–`1.0`。例如检查左上角为 `(1270, 1270)` 的圆环是否已满：

```json
{
  "version": 3,
  "vars": { "circle_percent": 0 },
  "steps": [
    {
      "type": "circle_percentage",
      "roi": [1270, 1270, 72, 72],
      "profile": "default",
      "output": "${circle_percent}"
    },
    {
      "type": "if",
      "condition": "${circle_percent >= 0.9}",
      "then": [{ "type": "return" }]
    }
  ]
}
```

执行时会在调试控制台和 `/tmp/adbquick.log` 输出例如
`[Workflow] Step: type=circle_percentage, output=circle_percent, percentage=0.35555555555555557`。

所有 version 3 文件的顶层、DSL 步骤、`run` 对象条目和录制事件都可以添加可选字符串 `label` 作为注释。`label` 不影响执行。

子脚本路径相对于引用文件，变量在每个 DSL 文件内局部生效；`run_for` / `run_until` 会取消并等待已结束的分支。坐标使用当前设备方向下的像素坐标。`drag` 的 `from` / `to` 是起止像素坐标，`duration_ms` 是移到终点后的持续时间；完成、取消或出错都会释放触摸。

当前设备适配器实现了 `ocr_text`、`skill_check` 和 `circle_percentage`。`skill_check` 使用设置中的 `wuwa_classify` 项目，当前要求 `model: "default"` 和 `threshold: 0`；`circle_percentage` 当前要求 `profile: "default"` 和 72×72 ROI；`template_match` 仍会明确报错。

### 流程组合

现有主流程 `scripts/4c_xin_loop_team_kxq/main.json` 本身是 DSL，按顺序执行 prepare → combat DSL → pickup DSL → finish，共 20 轮。`script` 可引用 v3 录制脚本、DSL 或 `run` 顺序流程；路径相对于引用文件。

`run` 流程仍支持 `script_loop_count`、字符串文件名和 `{"id":"combat","name":"combat.json"}` 条目。`id` 在同一流程内必须非空且唯一；省略时使用 `step_1`、`step_2` 等位置标识。`interval`、`steps`、`stop_when` 和 `when` 已移除，对应逻辑用 DSL `while` / `run_until` 表达。

所有引用文件在发送任何操作前递归读取并验证；缺失文件、未知版本、循环引用（含符号链接）或超过 64 层的嵌套会拒绝整次回放。错误和手动取消会终止整个流程并释放触摸。

### combat DSL

`scripts/common/combat_role_*.json` 是可直接执行的 v3 DSL。技能 ROI 和点位保存在数组变量中，每轮按角色优先级执行 `skill_check`，只点击第一个 `state == "usable"` 的技能。最多执行 200 轮，每轮后等待 500 ms；外层 `run_until` 匹配结束文字时会取消 combat 脚本。

`combat_role_katixiya_optimize_1.json` 按 `A → A → A → 重击 A → E → A` 执行；任一连招步骤检查为不可用时，从第一个 A 重新开始。每轮还会独立检查 S，可用时点击，不可用时忽略且不重置连招。`vars` 中的 `lock_tap_ms`、`s_tap_ms`、`a_1_tap_ms` 到 `a_4_tap_ms`、`heavy_a_tap_ms` 和 `e_tap_ms` 可分别调整每一步的按压时间。

锁定按键在第一轮和每 5 轮点击一次。shortcut: 这是基于轮数的近似定时，实际间隔为至少 2.5 秒加分类耗时；需要精确间隔时再为 DSL 增加单调时间。

在设置中选择相邻的 `wuwa_classify` 项目目录（包含 `.venv/bin/python`、`live.py` 和训练好的模型）。第一次 `skill_check` 才启动分类器，每次完整回放只加载一次。模型返回的 `useable` / `not_useable` 会映射为 DSL 的 `usable` / `unusable`；响应缺失或未知分类会终止流程。

### pickup.json

`scripts/4c_xin_loop_team_kxq/pickup.json` 是可直接执行的 v3 DSL。它用变量记录路线阶段、剩余移动时间和命中区域，用 `while` 遍历校准路线：

```json
{
  "version": 3,
  "vars": {"remaining_ms": 1000, "move_to": [501, 880], "pickup_text": ""},
  "steps": [
    {"type": "while", "condition": "${remaining_ms > 0}", "steps": [
      {"type": "drag", "from": [501, 1080], "to": "${move_to}", "duration_ms": 250},
      {"type": "assign", "target": "${remaining_ms}", "value": "${remaining_ms - 250}"},
      {"type": "wait", "wait_ms": 150},
      {"type": "ocr_text", "roi": [2041, 589, 111, 46], "output": "${pickup_text}"}
    ]}
  ]
}
```

`pickup.json` 先按顺序检查两个绝对像素 ROI，首个识别到“吸收”的区域会被点击一次。没有匹配时，保留原有 21 段校准路线；每次 `drag` 最多 250 ms，松开摇杆并等待 150 ms 后再 OCR。路径耗尽后直接结束，不无限搜索。

`drag.from` 是摇杆中心，`drag.to` 是方向终点，都是当前方向下的绝对像素坐标。路线相对于镜头，没有定位或避障，分辨率、移动速度或镜头变化后需要重新校准。

`pickup.json` 可以被主 DSL 的 `script` 直接引用，也可以在回放面板直接选择，不再需要 `pickup_flow.json` 包装。旧 `type: "pickup"` 格式已移除。JSON 参数更新后重新选择回放即可；从旧应用升级需要重新编译应用。

日志写入终端和 `/tmp/adbquick.log`，临时帧图和分类器进程日志在回放完成后清理。

### 开发检查命令

不依赖设备、OCR 或模型的 v3 流程检查：

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-flow-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Tests/flow.swift
/tmp/adbquick-flow-check

swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-workflow-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Tests/WorkflowParserTests.swift
/tmp/adbquick-workflow-check

swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-circle-check \
  Sources/WorkflowModel.swift Sources/CirclePercentageDetector.swift \
  Tests/CirclePercentageTests.swift
/tmp/adbquick-circle-check rect.png
```

包括真实 OCR 的原有检查：

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-replay-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift Sources/SkillClassifier.swift \
  Sources/VideoDecoder.swift Sources/Socket.swift Tests/check.swift
/tmp/adbquick-replay-check ../wuwa_classify
```

在项目根目录运行；不传项目目录时检查脚本逻辑、生成图片的真实 OCR 区域识别，以及 `demo.png` 中的中文“领取奖励”。传入目录时还检查真实模型的 Swift/Python 通信，并使用 `video_tools/xin.mp4` 检查 H.264 解码、PNG 截取和 YOLO 推理链路；不会向 Android 设备发送控制事件。
