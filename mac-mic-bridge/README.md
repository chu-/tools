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

## Latency reduction

The main change is to reduce block-filling waits and keep queued audio bounded. The previous native path captured 4096 bytes at a time (23.2 ms), read 8192 bytes per receiver block (46.4 ms), and allowed four scheduled player buffers plus a pending block before applying backpressure. Those five receiver blocks represent approximately 232 ms of audio, before pipe, SSH and device buffering. This explains an accumulation mechanism, rather than proving the full cause of a particular one-second delay. Durations here use 44.1 kHz stereo, 16-bit PCM: 176400 bytes per second.

| Stage | Current implementation | Purpose |
| --- | --- | --- |
| Capture | 128 frames / 512 bytes per buffer, approximately 2.90 ms | Reduce the time needed to fill each capture buffer. Hardware and AudioQueue may still deliver callbacks in batches. |
| Pipe to SSH | Nonblocking writes no larger than Darwin's `PIPE_BUF`; drop a whole block on `EAGAIN` | Keep SSH backpressure from blocking the capture callback; preserve PCM frame alignment. |
| Receiver input | POSIX `read` processes available bytes immediately and preserves incomplete stereo frames across reads | Remove the wait to fill an 8192-byte input block. The current 4096-byte read capacity is a maximum, not a fill requirement. |
| Playback | `AVAudioSourceNode` pulls from a ring buffer capped at 80 ms; overflow discards the oldest frames | Follow live audio without an expanding scheduled-player queue. |
| Jitter handling | Prefill 40 ms at startup and after underrun; output silence when audio is unavailable | Provide a reserve for uneven arrival while keeping the queue bounded. The cap is not a fixed 80 ms wait. |
| Callback synchronization | Decode PCM outside the mutex; hold it only for short copies and queue updates; render uses `trylock` | Avoid skipping entire playback blocks while the input thread decodes data. |

The sender also uses 16 empty capture buffers, a dedicated dispatch queue with user-interactive QoS, and a latency-critical activity retained while capture runs. The empty buffers accommodate hardware bursts without adding a fixed playback queue. A per-user capture lock prevents duplicate native senders after helper restarts; overlapping streams can sound doubled or metallic. The native SSH script disables compression and X11 forwarding and requests `IPQoS=ef`; that QoS request depends on network support and does not guarantee latency.

### Preserve continuity while reducing delay

The initial 20 ms receiver cap reduced transient delay but caused audible dropouts and a robotic sound. Decoding under the shared mutex made this worse because render callbacks returned silence on contention. The final settings use a **40 ms prefill reserve and an 80 ms queue cap**, with decoding outside the mutex. Simply shrinking buffers further can sacrifice sound continuity. PCM has no lossy codec here, but discarded frames and inserted silence still lose parts of the sound.

These changes bound application playback buffering; SSH/TCP can still retain old audio during a transport stall. Independent paced TCP testing reproduced receive gaps near 399 ms, including on the direct LAN path. The source of those stalls remains unresolved. A 40 ms reserve cannot hide a several-hundred-millisecond interruption, and the 80 ms cap is not an end-to-end latency guarantee.

### Deploy and verify

Rebuild or install the updated binaries on **both** Macs using the setup instructions above, then restart the bridge. Editing source files does not update a running process. Check installed binary hashes against the intended builds and confirm that only one sender and receiver are active.

Run `blackhole-pcm-v2 --self-test` without opening an audio device to check overflow, fragmented reads, stereo conversion, wraparound, underrun and prefill behavior. For a live check, use the [timestamp tools](tools/README.md) with monotonic clock probes before and after matching transients. Also inspect continuity: the receiver reports dropped frames, underruns, contention, missing frames after startup, and read-gap statistics on exit. The sender's optional `--diagnostics` flag reports capture age, callback gaps, peaks, dropped blocks and transient timestamps to stderr without saving audio; disable it after testing.

On November 17, 2026, the user reported no noticeable delay with the current running version. Its exact end-to-end latency has not been remeasured. The earlier approximately 54 ms median belongs to the superseded 20 ms configuration and is not validation of the current settings or of uninterrupted audio. Accept a sub-100 ms result only after checking both corrected timestamps and audio continuity; downstream meeting apps may add buffering.

## Verify and troubleshoot

On the receiving Mac, select **BlackHole 2ch** under **System Settings > Sound > Input**. Speak into the sending Mac's microphone and confirm that **Input level** moves continuously. Then select **BlackHole 2ch** in the target meeting or recording app and make a short test recording.

If there is no sound, check the sender's microphone level and **System Settings > Privacy & Security > Microphone**, the selected device index if using FFmpeg, SSH connectivity, the receiver program path, and the target app's input device. Do not use microphone capture started through an SSH session as a permission test: macOS may deny the SSH service access without displaying a prompt, resulting in silence. Network jitter can add latency; restart the script if the connection drops.

To record the sending Mac's screen while hearing its system audio, create a **Multi-Output Device** containing speakers and BlackHole in **Audio MIDI Setup**. That local recording setup is independent of the network microphone bridge.
