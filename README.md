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

仅支持 JSON v3，v1/v2 会被拒绝。v3 包含 `events` 录制脚本、`vars` / `steps` DSL、`script_loop_count` / `run` 流程以及带 `type` 的 battle/pickup 配置；加载器按顶层字段区分格式。

### vars / steps DSL

```json
{
  "version": 3,
  "vars": { "count": 0, "text": "" },
  "steps": [
    { "type": "assign", "target": "${count}", "value": "${count + 1}" },
    { "type": "ocr_text", "roi": [100, 200, 300, 80], "output": "${text}" },
    { "type": "if", "condition": "${text == 'DONE'}", "then": [{ "type": "return" }] },
    { "type": "tap", "point": [250, 240], "duration_ms": 100 },
    { "type": "wait", "wait_ms": 500 }
  ]
}
```

DSL 回放支持 `assign`、`while`、`if`、`monitor`、`script`、`tap`、`wait`、`break`、`continue`、`return` 和受限表达式。子脚本路径相对于引用文件，变量在每个 DSL 文件内局部生效；monitor 会取消并等待已结束的分支。坐标使用当前设备方向下的像素坐标。

解析器也验证 `template_match`、`skill_check`、`circle_percentage` 的输入并将它们交给视觉回调；当前设备适配器只实现了 `ocr_text`。其余三种命令在回放时明确报错，直到接入相应的已校准视觉后端。

### run 流程

现有主流程为 `scripts/4c_xin_loop_team_kxq/main.json`，按顺序执行 `prepare.json` → combat 包装流程 → pickup 包装流程 → `finish.json`，共 20 轮。

在设置中选择相邻的 `wuwa_classify` 项目目录（包含 `.venv/bin/python`、`live.py` 和训练好的模型）。连接设备后点击 **回放**，选择 v3 JSON。再次点击回放、关闭窗口、断开连接或视频尺寸变化会取消整个流程并释放触摸；任何执行错误同样终止剩余流程。只有执行到 battle 时才启动分类器，每次完整回放只加载一次，嵌套和重复共用它。

### 主流程

以下是结构示例，文件名与区域需要对应实际脚本和游戏画面：

```json
{
  "version": 3,
  "script_loop_count": 20,
  "run": [
    {
      "id": "prepare",
      "name": "prepare_xin.json"
    },
    {
      "id": "combat",
      "name": "battle_xin_4c.json",
      "interval": 0.5,
      "steps": 200,
      "stop_when": {
        "check_interval": 0.5,
        "match": {
          "type": "text_any",
          "text": [
            "领取",
            "明日",
            "BATTLE DONE"
          ],
          "text_regions": [
            [
              0.068181818,
              0.277777778,
              0.054924242,
              0.031944444
            ]
          ]
        }
      }
    },
    {
      "id": "pickup",
      "name": "pickup.json"
    },
    {
      "id": "finish",
      "name": "finish.json"
    }
  ]
}
```

- `script_loop_count`：整个 `run` 的执行次数，正整数，默认 1。字段名是 **loop**（不是 `script_look_count`）。
- `run`：非空数组，严格按从左到右的顺序逐个完成，不需要额外 `sort`。字符串 `"file.json"` 等价于 `{"name":"file.json"}`。
- `name`：可引用 v3 录制脚本、嵌套流程，或带 `type` 的 battle/pickup 配置。路径相对于**引用它的流程文件**，也支持绝对路径。
- `interval` / `steps`：只允许用于 battle，分别为技能判断的间隔秒数和最大次数，默认 0.5 / 200，必须为正数 / 正整数。录制脚本保留自身事件时间和 `repeatCount`，run 流程保留自身 `script_loop_count`。
- `id`：条目标识，用于执行日志。同一流程内必须非空且唯一；嵌套流程各自独立。省略时自动使用 `step_1`、`step_2` 等位置标识，字符串简写仍然支持。显式 ID 也不能与自动 ID 冲突。
- 所有条目正常完成后继续下一条，不再支持 `when` 或记录前一步结果。battle 因文字匹配结束或次数耗尽后都会运行 pickup；错误和手动取消仍终止整个流程。

所有引用文件在发送任何操作前递归读取并验证；缺失文件、未知版本、无效区域/参数、循环引用（含符号链接）或超过 64 层的嵌套会拒绝整次回放。相同文件可在不同位置重复引用。没有通用 JSON 合并或任意代码执行。

### stop_when 的作用范围

`run` 条目内的 `stop_when` 使用 `{ "check_interval": 0.5, "match": { "type": "text_any", "text": ["DONE"], "text_regions": [[0,0,1,1]] } }` 格式，**只结束当前 battle**，随后继续 `run` 中剩余条目及后续流程轮次，不中断录制脚本、pickup 或整个流程。省略时 battle 仅受 `steps` 限制。条件只属于配置它的 battle 条目，不继承到其他条目或嵌套流程。顶层 `stop_when` 已移除。

`match` 内的 `type` 仅支持 `text_any`；`text` 必须是非空字符串数组，任一区域识别到任一短语即匹配（忽略大小写并合并空白，使用子串匹配）。`text_regions` 必须是非空区域数组，每项为 `[x, y, width, height]`：左上角原点的 0–1 归一化坐标，宽高大于零且不得超出画面；例如检查全屏使用 `[[0, 0, 1, 1]]`。

`check_interval` 默认 0.5 秒，必须为正数。battle 开始时立即检查，之后按自己的间隔检查，不依赖技能点击间隔。OCR / 分类器串行运行，耗时可能推迟检查或点击，不并发补发；不是硬实时定时器。OCR 使用 macOS Vision 本地准确模式，支持中文和英文；错误会停止整个流程。

### battle.json

技能配置为带 `version: 3` 和 `type` 的数据文件，通过 v3 `run` 执行：

```json
{
  "version": 3,
  "type": "battle",
  "priority": ["S", "A"],
  "regions": {
    "S": [0.718434343, 0.65, 0.022727273, 0.05],
    "A": [0.772727273, 0.694444444, 0.075757576, 0.166666667]
  }
}
```

`regions` 是技能名到区域的**对象**，不是数组。`priority` 非空且不重复，每个技能必须有合法区域。每轮从最新视频帧分类，按优先级点击首个 `useable` 技能中心；全部为 `not_useable` 时跳过点击，该轮仍计入 `steps`。模型响应缺失或未知分类会终止流程。点击日志表示已请求发送操作，不代表游戏已响应。

`scripts/common/combat_role_*.json` 保留各角色的技能优先级和校准区域。

### pickup.json

`scripts/4c_xin_loop_team_kxq/pickup.json` 包含文字条件和移动路径，是可执行的 pickup 配置：

```json
{
  "version": 3,
  "type": "pickup",
  "pickup_text": {
    "text": "吸收",
    "regions": [[0.644255051, 0.409027778, 0.035037879, 0.031944444]]
  },
  "movement": {
    "joystick": [0.15814394, 0.75],
    "radius": [0.063131313, 0.138888889],
    "steps": [{"direction": "up", "seconds": 1}]
  }
}
```

`pickup_text.text` 支持非空字符串或非空字符串数组；`regions` 是非空区域数组。先按区域顺序检查，首个匹配区域被点击一次后结束；没有匹配才执行有限移动路径。每移动最多 0.25 秒松开摇杆，等待 0.15 秒画面更新，再检查新帧；OCR 期间静止。路径耗尽后继续下一条 run，不无限搜索。

`joystick` 是归一化摇杆中心，`radius` 是横纵拖动距离；方向支持 `up/right/down/left`，`seconds` 是正数累计移动时间，不包含 OCR 和等待时间。现有共用文件保留全部 21 段路线和校准值。方向相对于镜头，没有定位或避障，移动速度与镜头变化后需要重新校准。

不能直接选择 battle/pickup 配置作为顶层回放；单独执行时使用 `{"version":3,"run":["pickup.json"]}` 这样的包装流程。JSON 参数更新后重新选择回放即可；从旧应用升级到 v3 需要重新编译应用。

日志写入终端和 `/tmp/adbquick.log`，临时帧图和分类器进程日志在回放完成后清理。

### 开发检查命令

不依赖设备、OCR 或模型的 v3 流程检查：

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-flow-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Sources/PickupMovement.swift Tests/flow.swift
/tmp/adbquick-flow-check

swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-workflow-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Sources/PickupMovement.swift Tests/WorkflowParserTests.swift
/tmp/adbquick-workflow-check
```

包括真实 OCR 的原有检查：

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-replay-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift Sources/PickupMovement.swift Sources/SkillClassifier.swift \
  Sources/VideoDecoder.swift Sources/Socket.swift Tests/check.swift
/tmp/adbquick-replay-check ../wuwa_classify
```

在项目根目录运行；不传项目目录时检查脚本逻辑、生成图片的真实 OCR 区域识别，以及 `demo.png` 中的中文“领取奖励”。传入目录时还检查真实模型的 Swift/Python 通信，并使用 `video_tools/xin.mp4` 检查 H.264 解码、PNG 截取和 YOLO 推理链路；不会向 Android 设备发送控制事件。
