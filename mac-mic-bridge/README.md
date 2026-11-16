# Mac Mic Bridge

English | [简体中文](README.zh-CN.md)

Stream a Mac's microphone to another Mac and expose it to meeting or recording apps through BlackHole 2ch. The Macs can connect over Wi-Fi using Tailscale.

**For agents:** Before deploying, operating, or troubleshooting Mac Mic Bridge, read and follow the [Mac Mic Bridge Skill](skills/mac-mic-bridge/SKILL.md), then use this guide and the current device state. Discover device addresses, users, and audio device indices rather than assuming them.

```text
Source microphone → AudioQueue (or FFmpeg) → SSH → blackhole-pcm on receiving Mac
                                                          ↓
                                                BlackHole 2ch → target app
```

The native sender captures the default input as 44.1 kHz, stereo, 16-bit little-endian PCM. An FFmpeg fallback uses 48 kHz. SSH carries the audio stream to the receiver, where `blackhole-pcm` uses macOS Core Audio to write it to BlackHole. BlackHole provides a local virtual input; it does not transport audio over the network. SSH encrypts the stream. Tailscale can provide connectivity, either directly or through a relay.

## Files

- `src/blackhole-pcm.swift`: Swift source for the receiver.
- `src/macmic-native-sender.swift`: Swift source for the low-CPU native sender.
- `bin/blackhole-pcm-arm64`: the original Apple Silicon receiver binary, built for macOS 27.2; retained for reference, but it lacks the memory-release fix. It is ad hoc signed and not notarized by Apple.
- `bin/blackhole-pcm-v2-arm64`: receiver with selectable 44100 or 48000 Hz sample rate, built for macOS 27.2.
- `bin/macmic-native-sender-x86_64`: Intel sender binary built for macOS 13.0 or later.
- `send-microphone-native.fish`: low-CPU sender script using the default microphone.
- `send-microphone.fish`: FFmpeg sender script with configurable host and microphone index.
- `skills/mac-mic-bridge/SKILL.md`: optional agent skill for deploying and troubleshooting the bridge.
- `tools/`: [audio timestamp and clock-offset diagnostics](tools/README.md).

The prebuilt binaries are architecture-specific. Build from source on the target Mac if its architecture or OS version is not supported.

## Requirements

Both machines need macOS. Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) on the receiving Mac; the sender needs fish. FFmpeg with AVFoundation input support is required only for the fallback mode. The machines need SSH connectivity: Tailscale is an option, but SSH can use another reachable network.

On the receiving Mac, enable **System Settings > General > Sharing > Remote Login**. Set up SSH key authentication from the sender, then connect manually once to verify and accept the host key. Ensure that the receiving account can execute programs in its home directory.

## Receiver setup

Clone the repository on the receiving Mac and change into this directory. On Apple Silicon with a supported OS, install the prebuilt receiver:

```fish
mkdir -p ~/.local/bin
install -m 755 bin/blackhole-pcm-v2-arm64 ~/.local/bin/blackhole-pcm-v2
```

Alternatively, compile locally with Swift from Xcode or Command Line Tools:

```fish
mkdir -p ~/.local/bin
swiftc -O src/blackhole-pcm.swift -o ~/.local/bin/blackhole-pcm-v2
```

Confirm that **BlackHole 2ch** appears in **System Settings > Sound > Input**. Restart the Mac if the installer requests it, and make sure the target app has microphone permission.

## Sender: low-CPU mode

Clone the repository on the sending Mac and change into this directory. On Intel Macs running macOS 13.0 or later, install the prebuilt sender:

```fish
mkdir -p ~/.local/bin
install -m 755 bin/macmic-native-sender-x86_64 ~/.local/bin/macmic-native-sender
```

Alternatively, compile locally with Xcode or Command Line Tools:

```fish
mkdir -p ~/.local/bin
swiftc -O src/macmic-native-sender.swift -o ~/.local/bin/macmic-native-sender
```

Choose the microphone on the sending Mac under **System Settings > Sound > Input**. In **Terminal** within the local graphical session, run the following command after replacing the placeholders with the receiving account and its hostname or Tailscale address:

```fish
fish send-microphone-native.fish '<ssh-user>@<mac-mini-host>'
```

If prompted, allow Terminal to access the microphone. Keep the window open and press **Control-C** to stop. This mode disables SSH compression and uses `aes128-gcm@openssh.com`, which both SSH endpoints must support. In one 20-second test on an Intel MacBook, the capture and SSH processes together averaged approximately 0.8% of one logical CPU; results vary by hardware and environment.

## Sender: FFmpeg fallback

The fallback expects `~/.local/bin/blackhole-pcm` on the receiver. Install the v2 build at that path; without a sample-rate argument, v2 defaults to 48000 Hz. Avoid the legacy receiver binary because it lacks the memory-release fix.

On the sending Mac, clone the repository and change into this directory. List AVFoundation devices from **Terminal** in the local graphical session:

```fish
ffmpeg -hide_banner -f avfoundation -list_devices true -i ''
```

Find the microphone index under `AVFoundation audio devices`. The listing command may end with an input error; that is expected when listing devices. Replace the placeholders below with the receiving account, hostname or Tailscale address, and microphone index:

```fish
fish send-microphone.fish '<ssh-user>@<mac-mini-host>' '<audio-device-index>'
```

If prompted, allow Terminal to access the microphone. Keep the window open and press **Control-C** to stop. The script does not save audio files. Recheck the device index if audio devices change.

## Verify and troubleshoot

On the receiving Mac, select **BlackHole 2ch** under **System Settings > Sound > Input**. Speak into the sending Mac's microphone and confirm that **Input level** moves continuously. Then select **BlackHole 2ch** in the target meeting or recording app and make a short test recording.

If there is no sound, check the sender's microphone level and **System Settings > Privacy & Security > Microphone**, the selected device index if using FFmpeg, SSH connectivity, the receiver program path, and the target app's input device. Do not use microphone capture started through an SSH session as a permission test: macOS may deny the SSH service access without displaying a prompt, resulting in silence. Network jitter can add latency; restart the script if the connection drops.

To record the sending Mac's screen while hearing its system audio, create a **Multi-Output Device** containing speakers and BlackHole in **Audio MIDI Setup**. That local recording setup is independent of the network microphone bridge.
