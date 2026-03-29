# MediaKit

Shared media processing tools for copilot-ios apps.

## Tools

- **ffmpeg** — Run arbitrary ffmpeg commands for resize, trim, split, extract/remove audio, convert formats, etc.
- **ffprobe** — Inspect media file metadata (duration, resolution, codecs, bitrate)

## Dependencies

- [CopilotSDK](../CopilotSDK) — for `ToolDefinition`
- [ffmpeg-kit-spm](https://github.com/yangliu-1995/ffmpeg-kit-spm) — FFmpeg 6.0 with full-gpl codec support

## Usage

```swift
import MediaKit

let ffmpeg = FFmpegToolProvider()
// or with custom base directory:
let ffmpeg = FFmpegToolProvider(baseDirectory: myURL)

// Register tools with agent
let tools = ffmpeg.tools  // [ToolDefinition] — ffmpeg, ffprobe
```

Relative paths in ffmpeg commands are resolved from the base directory (default: `Documents/workspace/`).
