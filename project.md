# Adb Quick

A macOS Swift app that mirrors and controls an Android device via the scrcpy server.

## Features

- **Device list**: a centered 360-wide window shows connected ADB devices; the arrow on the right selects one; separator lines under each row.
- **Live rendering**: the window appears only after the video size is known (no jump); VideoToolbox hardware-decodes H.264; rotation adapts automatically.
- **Input mapping**: mouse → touch (with Y-axis flip correction); wheel → scroll; ESC/Backspace = Back, Cmd+Shift+H = Home, Cmd+Shift+R = Rotate.
- **Two-way clipboard**: Cmd+V on the computer → the phone; copying on the phone → the computer clipboard.
- **Control panel** (Cmd+K, can float on top): device name/size, current action plus absolute/relative coordinates; buttons: Home/Back/Rotate/Power/Screenshot/Record/Replay.
- **Screenshot**: `adb screencap` saved as PNG to a configurable directory (Downloads by default); revealed in Finder after saving.
- **Script recording/replay**: records control actions to JSON and replays them along the timeline; the window title shows the recording/replaying status.
- **Conditional replay**: JSON v3 only; combat uses the `while` / `skill_check` DSL, pickup uses the `while` / `ocr_text` / `drag` DSL; supports nesting, repetition, skill regions, priority, intervals, and counts; a persistent Python YOLO classifier runs on frames decoded from scrcpy and the first usable skill is clicked; clicking replay again stops it.
- **Settings**: ADB path, scrcpy-server path, screenshot directory, wuwa_classify project directory.

## Technology

- Pure Swift (AppKit), no third-party dependencies (ImageMagick is used for icon processing).
- Targets scrcpy 5.0: push server, adb reverse tunnel, dual video/control connections.
- Decoding: VTDecompressionSession outputs pixel frames, AVSampleBufferDisplayLayer displays them; Annex-B→AVCC in a single pass.
- Closing the window: shutdown interrupts the socket, removes the readabilityHandler, and releases the delegate after a delay to avoid crashes.
- Build: `./build.sh` (executable) / `./build_app.sh` (.app with a rounded icon).
