---
name: mac-mic-bridge
description: Deploy, operate, or troubleshoot Mac Mic Bridge for streaming one Mac's microphone to another Mac's BlackHole input over SSH. Use for requests involving this bridge, its receiver, or its audio routing; do not use for unrelated microphone or screen-recording issues.
---

# Mac Mic Bridge

Use the maintained project at https://github.com/chu-/tools/tree/main/mac-mic-bridge. Find an existing local checkout and read its `mac-mic-bridge/README.md` for deployment and file paths. If no checkout is available, obtain the project from its repository when needed. Reuse its source and scripts rather than creating parallel implementations.

## Operating principles

- The path is source microphone → FFmpeg/AVFoundation → SSH → receiver's `blackhole-pcm` Core Audio program → BlackHole 2ch input. BlackHole is a local loopback driver, not a network receiver. Both the sender and receiver must run while the bridge is in use.
- Discover the two hosts, SSH identity, FFmpeg audio device index, installed BlackHole device, and receiver path from the current environment. Never assume a particular IP address, username, or device index. Tailscale is optional if another suitable SSH path is available; preserve the user's choice.
- The supplied ARM64 binary targets macOS 27.2 or newer. Check the receiver's architecture and OS; build from `src/blackhole-pcm.swift` when the binary is unsuitable. Follow the project README for setup and avoid changing existing audio defaults unless needed or requested.
- Run microphone capture from the sender's graphical login session with the responsible application granted microphone access. A process started under SSH may receive silence because macOS denies microphone access to the SSH service. If user interaction is required, explain the exact step and continue other independent checks.
- When diagnosing, verify the sender's physical input level, sender and receiver processes, SSH connectivity, receiver output device, and the target application's selected BlackHole input. Distinguish nonzero signal reaching the receiver from nonzero signal appearing at BlackHole; a network test tone alone does not prove live microphone capture works. Check timestamps, buffers and actual connection path before attributing intermittent silence to Tailscale.
- Do not record or retain microphone audio for diagnostics unless requested. Prefer short-lived level measurements, avoid injecting test tones into a potentially live call, and remove temporary diagnostic logs when finished. Treat hostnames, addresses and account names as private when sharing artifacts.
