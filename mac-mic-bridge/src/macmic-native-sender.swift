import Foundation
import AudioToolbox
import CoreFoundation
import Darwin

let bufferSize: UInt32 = 4096
let callback: AudioQueueInputCallback = { _, queue, buffer, _, _, _ in
    let count = Int(buffer.pointee.mAudioDataByteSize)
    let bytes = buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self)
    var written = 0
    while written < count {
        let n = Darwin.write(STDOUT_FILENO, bytes.advanced(by: written), count - written)
        if n <= 0 { Darwin._exit(1) }
        written += n
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}
var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
var queue: AudioQueueRef?
var status = AudioQueueNewInput(&format, callback, nil, nil, nil, 0, &queue)
guard status == noErr, let queue else { fputs("AudioQueueNewInput failed: \(status)\n", stderr); exit(1) }
for _ in 0..<4 {
    var buffer: AudioQueueBufferRef?
    status = AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
    guard status == noErr, let buffer else { fputs("AudioQueueAllocateBuffer failed: \(status)\n", stderr); exit(1) }
    status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    guard status == noErr else { fputs("AudioQueueEnqueueBuffer failed: \(status)\n", stderr); exit(1) }
}
status = AudioQueueStart(queue, nil)
guard status == noErr else { fputs("AudioQueueStart failed: \(status)\n", stderr); exit(1) }
CFRunLoopRun()
