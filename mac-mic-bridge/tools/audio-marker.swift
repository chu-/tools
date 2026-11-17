import Foundation
import AudioToolbox
import CoreFoundation
import Darwin

// Reports transient peaks as timestamps only. Audio is never written to disk.
// Run on each Mac in an authorized GUI terminal session; compare event times
// only after checking the machines' wall-clock offset.
let arguments = CommandLine.arguments
let label = arguments.count > 1 ? arguments[1] : "input"
let threshold = arguments.count > 2 ? (Double(arguments[2]) ?? -1) : 0.15
guard threshold > 0 && threshold <= 1 else {
    fputs("Usage: audio-marker [label] [threshold 0..1]\n", stderr)
    exit(2)
}
let sampleRate = 44100.0
var lastEvent: Double = 0
let callback: AudioQueueInputCallback = { _, queue, buffer, timestamp, _, _ in
    let samples = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Int16>.size
    let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
    var maxValue: Int32 = 0
    var peakIndex = 0
    for index in 0..<samples {
        let value = abs(Int32(data[index]))
        if value > maxValue { maxValue = value; peakIndex = index }
    }
    if Double(maxValue) / 32768.0 >= threshold {
        let nowWall = Date().timeIntervalSince1970
        let nowHost = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let flags = timestamp.pointee.mFlags
        let hasHostTime = flags.contains(.hostTimeValid)
        let eventTime: Double
        if hasHostTime {
            let sampleHost = AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime)
            eventTime = nowWall + (Double(sampleHost) - Double(nowHost)) / 1_000_000_000 + Double(peakIndex) / sampleRate
        } else {
            // Approximation when Core Audio does not report a host timestamp.
            eventTime = nowWall - Double(samples - peakIndex) / sampleRate
        }
        if eventTime - lastEvent >= 0.7 {
            lastEvent = eventTime
            let quality = hasHostTime ? "host" : "estimated"
            let monotonic = hasHostTime
                ? Double(AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime)) / 1e9 + Double(peakIndex) / sampleRate
                : Double(nowHost) / 1e9 - Double(samples - peakIndex) / sampleRate
            print(String(format: "%@ %.6f peak=%.3f timestamp=%@ host=%.6f", label, eventTime, Double(maxValue) / 32768.0, quality, monotonic))
            fflush(stdout)
        }
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}

var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
var queue: AudioQueueRef?
var status = AudioQueueNewInput(&format, callback, nil, nil, nil, 0, &queue)
guard status == noErr, let queue else { fputs("AudioQueueNewInput failed: \(status)\n", stderr); exit(1) }
for _ in 0..<4 {
    var buffer: AudioQueueBufferRef?
    status = AudioQueueAllocateBuffer(queue, 1024, &buffer)
    guard status == noErr, let buffer else { fputs("AudioQueueAllocateBuffer failed: \(status)\n", stderr); exit(1) }
    status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    guard status == noErr else { fputs("AudioQueueEnqueueBuffer failed: \(status)\n", stderr); exit(1) }
}
status = AudioQueueStart(queue, nil)
guard status == noErr else { fputs("AudioQueueStart failed: \(status)\n", stderr); exit(1) }
fputs("Listening on the system default input; threshold \(threshold). Press Control-C to stop.\n", stderr)
CFRunLoopRun()
