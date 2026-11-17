import Foundation
import AudioToolbox
import CoreFoundation
import Darwin

// This sender normally runs in a background GUI helper. Keep App Nap and
// timer coalescing from batching time-sensitive microphone work.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "Live microphone streaming")

let stateDirectory = NSHomeDirectory() + "/.local/state/mac-mic-bridge"
try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
let captureLock = Darwin.open(stateDirectory + "/capture.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard captureLock >= 0, flock(captureLock, LOCK_EX | LOCK_NB) == 0 else {
    fputs("A microphone sender is already running, or its lock is unavailable\n", stderr); exit(1)
}

// 128 stereo frames = 2.90 ms on Darwin (PIPE_BUF is only 512 bytes).
// A congested SSH pipe must never stall the AudioQueue callback.
let bufferSize = UInt32(PIPE_BUF / 4 * 4)
let diagnostics = CommandLine.arguments.contains("--diagnostics")
var diagnosticBlocks = 0
var diagnosticMaxAge = 0.0
var diagnosticPeak: Int32 = 0
var diagnosticDrops = 0
var lastCaptureHost = AudioGetCurrentHostTime()
var maxCaptureGap = 0.0
var lastDiagnosticEvent = 0.0
signal(SIGPIPE, SIG_IGN)
let flags = fcntl(STDOUT_FILENO, F_GETFL)
guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
    perror("nonblocking stdout"); exit(1)
}
let callback: AudioQueueInputCallback = { _, queue, buffer, timestamp, _, _ in
    let count = Int(buffer.pointee.mAudioDataByteSize)
    let bytes = buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self)
    // Pipe writes <= PIPE_BUF are all-or-nothing. Drop a whole packet on
    // EAGAIN rather than accumulating old microphone audio. A short write
    // is fatal: continuing would corrupt the stereo PCM frame alignment.
    var n: Int
    repeat { n = Darwin.write(STDOUT_FILENO, bytes, count) } while n < 0 && errno == EINTR
    if n != count && !(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { Darwin._exit(1) }
    if diagnostics {
        let nowHost = AudioGetCurrentHostTime()
        maxCaptureGap = max(maxCaptureGap, Double(AudioConvertHostTimeToNanos(nowHost - lastCaptureHost)) / 1e6)
        lastCaptureHost = nowHost
        diagnosticBlocks += 1
        if n < 0 { diagnosticDrops += 1 }
        if timestamp.pointee.mFlags.contains(.hostTimeValid) {
            let now = Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
            let captured = Double(AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime))
            diagnosticMaxAge = max(diagnosticMaxAge, (now - captured) / 1e6)
        }
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        var peak: Int32 = 0
        var peakFrame = 0
        for i in 0..<(count / 2) {
            let value = abs(Int32(samples[i]))
            if value > peak { peak = value; peakFrame = i / 2 }
        }
        diagnosticPeak = max(diagnosticPeak, peak)
        if peak >= 655 && timestamp.pointee.mFlags.contains(.hostTimeValid) {
            let captured = Double(AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime))
            let now = Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
            let event = Date().timeIntervalSince1970 + (captured - now) / 1e9 + Double(peakFrame) / 44100
            if event - lastDiagnosticEvent >= 0.7 {
                let host = captured / 1e9 + Double(peakFrame) / 44100
                fputs(String(format: "source %.6f peak=%.3f host=%.6f\n", event, Double(peak) / 32768, host), stderr)
                lastDiagnosticEvent = event
            }
        }
        if diagnosticBlocks == 344 {
            fputs("Capture: max age \(diagnosticMaxAge) ms, gap \(maxCaptureGap) ms, peak \(Double(diagnosticPeak) / 32768), dropped \(diagnosticDrops) blocks\n", stderr)
            diagnosticBlocks = 0; diagnosticMaxAge = 0; diagnosticPeak = 0; diagnosticDrops = 0
            maxCaptureGap = 0
        }
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}
var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
var queue: AudioQueueRef?
let captureDispatch = DispatchQueue(label: "macmic.capture", qos: .userInteractive)
var status = AudioQueueNewInputWithDispatchQueue(&queue, &format, 0, captureDispatch) {
    queue, buffer, timestamp, packets, descriptions in
    callback(nil, queue, buffer, timestamp, packets, descriptions)
}
guard status == noErr, let queue else { fputs("AudioQueueNewInput failed: \(status)\n", stderr); exit(1) }
// These are empty capture buffers, not a playback queue. Keep enough available
// for AudioQueue to split a hardware input burst without exhausting the pool.
for _ in 0..<16 {
    var buffer: AudioQueueBufferRef?
    status = AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
    guard status == noErr, let buffer else { fputs("AudioQueueAllocateBuffer failed: \(status)\n", stderr); exit(1) }
    status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    guard status == noErr else { fputs("AudioQueueEnqueueBuffer failed: \(status)\n", stderr); exit(1) }
}
status = AudioQueueStart(queue, nil)
guard status == noErr else { fputs("AudioQueueStart failed: \(status)\n", stderr); exit(1) }
withExtendedLifetime(activity) { CFRunLoopRun() }
