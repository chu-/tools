import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

let activity = ProcessInfo.processInfo.beginActivity(
 options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
 reason: "Live microphone playback")

// Storage is allocated once. The render callback tries the mutex and never
// waits for stdin. Overflow discards the oldest complete stereo frames.
final class LivePCM {
 let capacity: Int
 private let samples: UnsafeMutablePointer<Float>
 private var lock = pthread_mutex_t()
 private var head = 0
 private var count = 0
 private var partial: [UInt8] = []
 private let prefill: Int
 private var playing: Bool
 private(set) var dropped = 0
 private(set) var underrunFrames = 0
 private(set) var contentionFrames = 0
 private(set) var maxRenderFrames = 0
 private var firstInputHost: UInt64?
 private var steady = false
 private(set) var steadyDropped = 0
 private(set) var steadyMissing = 0
 init(capacity: Int, prefill: Int = 0) {
  self.capacity = capacity
  self.prefill = prefill
  playing = prefill == 0
  samples = .allocate(capacity: capacity * 2)
  samples.initialize(repeating: 0, count: capacity * 2)
  partial.reserveCapacity(4)
  pthread_mutex_init(&lock, nil)
 }
 deinit { samples.deallocate(); pthread_mutex_destroy(&lock) }
 func ingest(_ bytes: UnsafeBufferPointer<UInt8>) {
  // Decode outside the shared lock. Holding it while decoding every byte made
  // the real-time callback skip entire device blocks under normal traffic.
  var converted: [Float] = []
  converted.reserveCapacity((bytes.count + partial.count) / 4 * 2)
  for byte in bytes {
   partial.append(byte)
   if partial.count != 4 { continue }
   for channel in 0..<2 {
    let bits = UInt16(partial[channel * 2]) | UInt16(partial[channel * 2 + 1]) << 8
    converted.append(Float(Int16(bitPattern: bits)) / 32768)
   }
   partial.removeAll(keepingCapacity: true)
  }
  let incoming = converted.count / 2
  guard incoming > 0 else { return }
  pthread_mutex_lock(&lock)
  defer { pthread_mutex_unlock(&lock) }
  let now = AudioGetCurrentHostTime()
  if firstInputHost == nil { firstInputHost = now }
  steady = now - firstInputHost! >= AudioConvertNanosToHostTime(3_000_000_000)
  let overflow = max(0, count + incoming - capacity)
  dropped += overflow
  if steady { steadyDropped += overflow }
  let discardOld = min(count, overflow)
  head = (head + discardOld) % capacity
  count -= discardOld
  let keep = min(capacity, incoming)
  let tail = (head + count) % capacity
  let first = min(keep, capacity - tail)
  converted.withUnsafeBufferPointer { data in
   let start = data.baseAddress!.advanced(by: (incoming - keep) * 2)
   samples.advanced(by: tail * 2).update(from: start, count: first * 2)
   if keep > first { samples.update(from: start.advanced(by: first * 2), count: (keep - first) * 2) }
  }
  count += keep
 }
 func render(_ frames: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
  left.update(repeating: 0, count: frames)
  right.update(repeating: 0, count: frames)
  maxRenderFrames = max(maxRenderFrames, frames)
  guard pthread_mutex_trylock(&lock) == 0 else { contentionFrames += frames; return }
  defer { pthread_mutex_unlock(&lock) }
  if !playing {
   guard count >= max(prefill, frames) else {
    if steady { steadyMissing += frames }
    return
   }
   playing = true
  }
  let available = min(frames, count)
  underrunFrames += frames - available
  if steady { steadyMissing += frames - available }
  if available < frames && prefill > 0 { playing = false }
  for i in 0..<available {
   let index = (head + i) % capacity
   left[i] = samples[index * 2]
   right[i] = samples[index * 2 + 1]
  }
  head = (head + available) % capacity
  count -= available
 }
}

if CommandLine.arguments.dropFirst() == ["--self-test"] {
 let pcm = LivePCM(capacity: 4)
 let bytes: [UInt8] = (1...6).flatMap { i -> [UInt8] in
  let l = UInt16(i * 1000)
  let r = UInt16(bitPattern: -Int16(i * 1000))
  return [UInt8(l & 255), UInt8(l >> 8), UInt8(r & 255), UInt8(r >> 8)]
 }
 for byte in bytes { [byte].withUnsafeBufferPointer { pcm.ingest($0) } }
 var left = [Float](repeating: 0, count: 6)
 var right = left
 left.withUnsafeMutableBufferPointer { l in
  right.withUnsafeMutableBufferPointer { r in pcm.render(6, l.baseAddress!, r.baseAddress!) }
 }
 precondition(pcm.dropped == 2)
 precondition(left == [3000, 4000, 5000, 6000, 0, 0].map { Float($0) / 32768 })
 precondition(right == left.map { -$0 })
 bytes.prefix(4).withContiguousStorageIfAvailable { pcm.ingest($0) }
 left.withUnsafeMutableBufferPointer { l in
  right.withUnsafeMutableBufferPointer { r in pcm.render(6, l.baseAddress!, r.baseAddress!) }
 }
 precondition(left[0] == Float(1000) / 32768 && left[1...] == [0, 0, 0, 0, 0])
 let burst = LivePCM(capacity: 4)
 bytes.withUnsafeBufferPointer { burst.ingest($0) }
 left.withUnsafeMutableBufferPointer { l in
  right.withUnsafeMutableBufferPointer { r in burst.render(6, l.baseAddress!, r.baseAddress!) }
 }
 precondition(burst.dropped == 2 && left[0] == Float(3000) / 32768 && left[3] == Float(6000) / 32768)
 let jitter = LivePCM(capacity: 8, prefill: 4)
 bytes.prefix(8).withContiguousStorageIfAvailable { jitter.ingest($0) }
 left.withUnsafeMutableBufferPointer { l in
  right.withUnsafeMutableBufferPointer { r in jitter.render(2, l.baseAddress!, r.baseAddress!) }
 }
 precondition(left[0] == 0 && left[1] == 0) // reserve is not ready
 bytes.dropFirst(8).prefix(8).withContiguousStorageIfAvailable { jitter.ingest($0) }
 left.withUnsafeMutableBufferPointer { l in
  right.withUnsafeMutableBufferPointer { r in jitter.render(2, l.baseAddress!, r.baseAddress!) }
 }
 precondition(left[0] == Float(1000) / 32768 && left[1] == Float(2000) / 32768)
 print("PASS: overflow, fragmented frames, stereo, wraparound and underrun")
 exit(0)
}

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
var target: AudioDeviceID = 0
for device in devices {
 var prop = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
 var uid: CFString = "" as CFString
 var bytes = UInt32(MemoryLayout<CFString>.size)
 if AudioObjectGetPropertyData(device, &prop, 0, nil, &bytes, &uid) == 0 && (uid as String) == "BlackHole2ch_UID" { target = device; break }
}
guard target != 0 else { fputs("BlackHole 2ch not found\n", stderr); exit(1) }
let engine = AVAudioEngine()
let output = engine.outputNode
guard let audioUnit = output.audioUnit else { fputs("No output audio unit\n", stderr); exit(1) }
let err = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
guard err == noErr else { fputs("Unable to select BlackHole: \(err)\n", stderr); exit(1) }
let rate = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) : 48000
guard let rate, rate == 44100 || rate == 48000 else { fputs("Usage: blackhole-pcm [44100|48000]\n", stderr); exit(2) }
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
// Keep a small jitter reserve instead of repeatedly consuming down to zero.
// A burst may span several device callbacks, so capacity exceeds the reserve.
let pcm = LivePCM(capacity: Int(rate * 0.080), prefill: Int(rate * 0.040))
let source = AVAudioSourceNode(format: format) { _, _, frames, audioBufferList in
 let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
 guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return kAudio_ParamError }
 pcm.render(Int(frames), left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self))
 return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)
do { try engine.start() } catch { fputs("Audio engine failed: \(error)\n", stderr); exit(1) }
fputs("Live PCM: \(Int(rate)) Hz, queue cap 80 ms, prefill 40 ms, output latency \(output.presentationLatency * 1000) ms\n", stderr)
var input = [UInt8](repeating: 0, count: 4096)
var failed = false
let started = ProcessInfo.processInfo.systemUptime
var receivedBytes = 0
var previousRead = AudioGetCurrentHostTime()
var maxReadGap = 0.0
var gaps = [Int](repeating: 0, count: 5)
while true {
 let n = input.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count) }
 if n == 0 { break }
 if n < 0 {
  if errno == EINTR { continue }
  perror("stdin"); failed = true; break
 }
 receivedBytes += n
 let now = AudioGetCurrentHostTime()
 let gap = Double(AudioConvertHostTimeToNanos(now - previousRead)) / 1e6
 maxReadGap = max(maxReadGap, gap)
 gaps[gap < 10 ? 0 : gap < 20 ? 1 : gap < 40 ? 2 : gap < 80 ? 3 : 4] += 1
 previousRead = now
 input.withUnsafeBufferPointer { pcm.ingest(UnsafeBufferPointer(start: $0.baseAddress!, count: n)) }
}
Thread.sleep(forTimeInterval: 0.080 + output.presentationLatency)
engine.stop()
fputs("Live PCM: dropped \(pcm.dropped) old frames\n", stderr)
fputs("Live PCM: underrun \(pcm.underrunFrames), contention \(pcm.contentionFrames), max render \(pcm.maxRenderFrames) frames\n", stderr)
fputs("Live PCM: received \(receivedBytes / 4) frames in \(ProcessInfo.processInfo.systemUptime - started) seconds\n", stderr)
fputs("Live PCM: after startup dropped \(pcm.steadyDropped), missing \(pcm.steadyMissing) frames\n", stderr)
fputs("Live PCM: max read gap \(maxReadGap) ms, gap bins <10/20/40/80/other: \(gaps)\n", stderr)
exit(failed ? 1 : 0)
