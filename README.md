# Adb Quick

A native macOS app for mirroring and controlling Android devices over ADB, with recorded input playback and JSON workflows for Wuthering Waves automation.

Built with Swift, AppKit, VideoToolbox, Vision, and WebKit. The app uses the scrcpy server for video and control; it does not launch the scrcpy desktop client.

## Features

- Live H.264 screen mirroring with touch, drag, scroll, and device rotation.
- A control panel with navigation, power, screenshots, recording, playback progress, and absolute/relative pointer coordinates.
- Text clipboard support: paste from the Mac with `Cmd+V` and receive device clipboard updates.
- JSON v3 automation with variables, expressions, loops, conditional branches, nested scripts, and timed cancellation.
- On-screen OCR, colored-ring percentage detection, and optional skill classification through `wuwa_classify`.
- A visual Flow Orchestrator for editing DSL workflows and their JSON.

## Requirements

- macOS; the app bundle declares macOS 12.0 as its minimum version.
- Xcode Command Line Tools with a Swift compiler supporting the source syntax (Swift 5.7 or newer).
- An executable `adb` and an authorized Android device connected over USB or wireless ADB.
- **scrcpy-server 5.0.1**. The server version is hard-coded in `Sources/AdbClient.swift`; the local server file must match.
- ImageMagick (`magick`) when generating the app icon during packaging.
- Optional: a configured `wuwa_classify` project for workflows using `skill_check`.

No Swift package dependencies are required. Builds use `swiftc` directly.

## Build and launch

Run from the repository root:

```bash
# Build and run the executable
./build.sh
./AdbQuick

# Or build and open the app bundle
./build_app.sh
open AdbQuick.app
```

`build.sh` creates `AdbQuick` and keeps compiler caches in `.clangcache/`, keyed by the repository's absolute path. `build_app.sh` rebuilds the executable, generates the icon, replaces `AdbQuick.app`, bundles the editor, and attempts ad-hoc signing.

When running the standalone executable, keep `assets/orchestration.html` beside it in the `assets/` directory so the editor can load. Workflow files remain in the repository; packaging does not copy `scripts/` into the app.

To connect directly to a device instead of choosing it in the device list:

```bash
./AdbQuick --mirror DEVICE_SERIAL
```

## Connect and configure

1. Enable USB debugging on Android, connect the device, and accept its authorization prompt. For wireless use, establish the ADB connection first.
2. Check that `adb devices -l` reports the device as `device`.
3. Launch Adb Quick. Open **Settings…** (`Cmd+,`) if the detected paths need changing.
4. Choose the device in the device list to open its mirrored screen.

| Setting | Purpose / default |
| --- | --- |
| ADB Path | Android SDK and common Homebrew locations are checked automatically. Set an absolute executable path if detection fails. |
| scrcpy-server Path | Common locations include `/opt/homebrew/share/scrcpy/scrcpy-server` and `/usr/local/share/scrcpy/scrcpy-server`. |
| Screenshot Directory | Defaults to the Mac's Downloads folder. |
| wuwa_classify Project | Defaults to a sibling `wuwa_classify` directory; needed only for skill classification. |
| Turn off phone screen after connecting | Enabled by default. Turns off the physical display after the first video frame while mirroring continues. Changes apply on the next connection. |

## Controls

Device shortcuts apply while the mirrored screen has focus.

| Input | Action |
| --- | --- |
| Mouse down / drag / up | Touch down / move / release |
| Scroll wheel or trackpad | Device scroll |
| `Esc` or `Backspace` | Back |
| `Cmd+Shift+H` | Home |
| `Cmd+Shift+R` | Rotate device |
| `Cmd+V` | Paste Mac clipboard text into the device |
| `Cmd+K` | Show/hide Control Panel |
| `Cmd+O` | Open Flow Orchestrator |
| `Cmd+,` | Open Settings |

The **Control Panel** also provides Home, Back, Rotate, Power, and Screenshot buttons. Screenshots are saved as timestamped PNGs and revealed in Finder.

### Record and replay

1. Click **Record** in the Control Panel, then interact with the device.
2. Click the recording button again to stop and save a JSON v3 file.
3. Click **Playback** and select a recording or workflow.
4. Click **Playback** again to cancel execution.

Recordings capture touch, scroll, and supported device-key actions with relative timing. Clipboard paste and screenshots are not recorded input events.

## Workflows

See [SCHEMA.md](SCHEMA.md) for the JSON DSL reference, examples, commands, expressions, child-script props, and vision support.

Open **View → Flow Orchestrator** (`Cmd+O`) to create or edit a workflow, then select the saved file through **Playback** to run it.

### Included Wuthering Waves workflows

| Entry point | Workflow |
| --- | --- |
| [4c/xin_loop_team_kxq/main.json](scripts/4c/xin_loop_team_kxq/main.json) | Preparation, combat, pickup, and finish loop; defaults to 20 rounds |
| [4c/qianran_loop_team_kxq/main.json](scripts/4c/qianran_loop_team_kxq/main.json) | Qianran loop |
| [juluo/juluo.json](scripts/juluo/juluo.json) | Runs the five Juluo routes in sequence |
| [mengyan/mengyan.json](scripts/mengyan/mengyan.json) | Runs the five Mengyan routes in sequence |
| [common/](scripts/common/) | Shared combat, team reset, role switching, and text-region helpers |

These scripts contain calibrated screen coordinates, Chinese OCR text, and route assumptions. Adapt them to your resolution, UI layout, team, camera, and movement speed before running. Pickup routes do not provide positioning or obstacle avoidance.

## Development

| Location | Contents |
| --- | --- |
| `Sources/` | AppKit windows, ADB/scrcpy transport, decoding, input, workflow parsing/execution, and vision adapters |
| `assets/` | App icon and the WebKit orchestration editor |
| `scripts/` | JSON workflows |
| `Tests/` | Standalone Swift checks and editor JavaScript checks |

Run these checks from the repository root; they require no Android device or classifier:

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-props-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Tests/WorkflowPropsTests.swift
/tmp/adbquick-props-check

swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-circle-check \
  Sources/WorkflowModel.swift Sources/CirclePercentageDetector.swift \
  Tests/CirclePercentageTests.swift
/tmp/adbquick-circle-check

# Requires Node.js
node Tests/orchestration_props.cjs
```

Other checks have additional fixture requirements. In particular, `Tests/flow.swift` and `Tests/WorkflowParserTests.swift` still reference the old `scripts/4c_xin_loop_team_kxq/` layout; the parser check also reads a sibling `wuwa_mass/project.md`. They need fixture updates before serving as clean-checkout checks. `Tests/check.swift` exercises OCR and optionally the external classifier/video pipeline.

## Troubleshooting and limitations

- **Device missing or unauthorized:** check `adb devices -l`, the configured ADB path, and the Android authorization prompt.
- **Connection fails or times out:** verify the server file is version 5.0.1. Inspect `/tmp/adbquick.log` for app/workflow logs and `/tmp/adbquick-server.log` for scrcpy server output.
- **Classifier fails:** verify the configured project's Python executable, `live.py`, and model. Temporary replay frames and worker logs are removed when replay cleanup finishes.
- **Workflow coordinates fail:** recalibrate against the current device size and orientation using the Control Panel. Vision regions must fit inside the current frame.
- Audio is disabled, and general keyboard typing/key mapping is not implemented. Use clipboard paste for text.

### Debug window

Open **View > Debug** for live playback status, selected script path, executing script,
current step/event, repeat progress, the current script’s variables and props, latest workflow result/error, and
device/input coordinates. While a subscript runs, its variables are shown. The console and `/tmp/adbquick.log`
also receive variable snapshots when the script or values change. Parallel workflow
steps show the latest activity; step numbers are local to their block. The window
refreshes five times per second, supports text selection/copy, and has an **Always on
Top** checkbox. The Control Panel is fixed at 460 points wide.

Debug checks (from `wuwa_adb`, on macOS):

```bash
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-debug-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/ControlPanelWindowController.swift Sources/DebugWindowController.swift \
  Tests/DebugInfoTests.swift
/tmp/adbquick-debug-check
```
