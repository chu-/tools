# Live audio timestamp test

For the current implementation, buffer settings, and continuity checks, see [Latency reduction](../README.md#latency-reduction) ([中文说明](../README.zh-CN.md#延迟优化)).

Prefer monotonic host timestamps when testing latency: wall clocks can step during network time synchronization. Current marker output includes a `host=...` value in seconds. On macOS with Python 3.10 or newer, run `python3 clock-offset.py '<ssh-user>@<macbook-host>' --monotonic` and use the `host` values in the same delay formula below. Repeat the clock probe before and after the test to check drift. Do not mix wall-clock and monotonic values.

The native sender can provide source events directly with `macmic-native-sender --diagnostics` while streaming PCM on stdout. Its stderr reports transient timestamps (threshold 0.02, minimum spacing 0.7 seconds), capture age and drop counts; no audio is saved. Run the receiving marker with `./audio-marker receiver 0.02` and match isolated transients. Disable diagnostics after the measurement to stop ongoing log writes.

On November 16, 2026, four matched live transients with the initial 128-frame sender and 20 ms receiver (superseded after audible dropouts were found) measured 46.6, 57.0, 60.3 and 50.6 ms from the microphone to BlackHole (median 53.8 ms). Monotonic clock probes before and after differed by 0.86 ms, with round-trip uncertainty up to ±3.2 ms; allow approximately ±4 ms for clock estimation, plus transient matching error. This was a direct local-network connection (approximately 5 ms RTT), not a bound on other networks or downstream applications.

`audio-marker.swift` prints the time of loud transient peaks from the current system default input. `clock-offset.py` estimates the difference between the two Macs' wall clocks. Neither tool saves audio. These are diagnostic tools, not part of the bridge's audio path.

## Setup

Compile the marker on each Mac:

```fish
swiftc -O audio-marker.swift -o audio-marker
```

Choose the MacBook microphone in **System Settings > Sound > Input** on the source Mac, and **BlackHole 2ch** on the receiving Mac. Keep the microphone bridge running. Run the marker in a local graphical Terminal session on each Mac; allow Terminal microphone access if prompted. A capture process launched through SSH may get silence because of macOS privacy permissions.

On the MacBook:

```fish
./audio-marker source 0.15
```

On the Mac mini:

```fish
./audio-marker receiver 0.15
```

The second argument is the threshold between 0 and 1. Adjust it if a clap is missed or background sounds trigger false events; the levels may differ between devices. Start both markers, make several distinct claps near the MacBook microphone, and stop with **Control-C**. Each line reports an epoch time in seconds and a peak level; no audio is stored.

From the Mac mini, check clock offset just before or after the measurement, replacing the placeholder:

```fish
python3 clock-offset.py '<ssh-user>@<macbook-host>'
```

The output is `MacBook clock minus Mac mini clock` with a round-trip-based uncertainty bound. For each matching clap:

```text
bridge delay = receiver timestamp - source timestamp + clock offset
```

Convert the offset from milliseconds to seconds before adding it. For example, offset +50 ms, source timestamp 100.100 s, receiver timestamp 100.300 s gives 0.250 s. Match the same clap, repeat several times, and report the results with the clock uncertainty. Asymmetric SSH transport, changing clock offsets, different thresholds and processing can add error. `timestamp=estimated` means the audio callback did not provide a host timestamp and the result is less precise. The input marker includes the measurement devices' capture and buffering delays; it is an estimate rather than a laboratory-grade latency measurement.

This compares the source microphone against the BlackHole input. It does not timestamp Voice Memos' waveform drawing. Compare that display separately with a high-frame-rate video that shows the physical clap and both displays, accounting for camera frame duration.

On November 17, 2026, continuity checks invalidated the initial low-latency result as a quality claim: the 20 ms implementation dropped frames and produced underruns, and it held a mutex during PCM decoding. Decoding now runs outside the mutex; playback uses a 40 ms reserve and an 80 ms cap. The current buffer settings have not been verified below 100 ms end to end. Arrival-gap instrumentation and an independent paced TCP test also found roughly 120–400 ms stalls on both the overlay and direct LAN paths. A 15-second direct-LAN test with no microphone or audio program had 20 receive gaps over 80 ms and a maximum near 399 ms. The source of those transport stalls remains unresolved. Keep continuity/drop counters alongside latency measurements; short-transient latency alone does not verify audio quality.

## Receiver batch conversion

The receiver reuses an aligned 4096-byte input buffer and an 8192-byte Float buffer. Accelerate converts complete stereo frames in batches; zero to three trailing bytes carry over to the next read. Small reads are processed immediately once a complete frame is available. The format, 40 ms prefill and 80 ms queue cap are unchanged.

On November 17, 2026, two 30-second live measurements using process CPU-time deltas showed the receiver alone dropping from approximately 1.40% to 0.90% of one logical core (about 36% lower in this comparison). SSH, Core Audio and Tailscale CPU are excluded. This is a short before/after sample, not a guaranteed reduction or a new latency measurement.

An isolated synthetic ingest-and-render benchmark used 20000 iterations per run and the median of three runs for each block size:

| Input block | Previous CPU seconds | Batch conversion CPU seconds |
| --- | ---: | ---: |
| 512 bytes | 0.104062 | 0.004663 |
| 4096 bytes | 0.810006 | 0.024114 |

These numbers describe the synthetic data-processing loop, not whole-process speedup. The expanded `--self-test` compares all 65536 Int16 values on both channels with scalar conversion, including fragmented, unaligned and oversized reads. It also passes with AddressSanitizer enabled. All benchmark/test audio is synthetic and never reaches an audio device.
