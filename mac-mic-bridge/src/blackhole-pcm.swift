import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

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
let player = AVAudioPlayerNode()
let rate = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) : 48000
guard let rate, rate == 44100 || rate == 48000 else { fputs("Usage: blackhole-pcm [44100|48000]\n", stderr); exit(2) }
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
do { try engine.start() } catch { fputs("Audio engine failed: \(error)\n", stderr); exit(1) }
player.play()
let inflight = DispatchSemaphore(value: 4)
while true {
 let more = autoreleasepool { () -> Bool in
 let data = FileHandle.standardInput.readData(ofLength: 8192)
 if data.isEmpty { return false }
 let frames = data.count / 4
 if frames == 0 { return true }
 guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channels = buffer.floatChannelData else { return false }
 buffer.frameLength = AVAudioFrameCount(frames)
 data.withUnsafeBytes { raw in
  let bytes = raw.bindMemory(to: UInt8.self)
  for i in 0..<frames {
   for channel in 0..<2 {
    let offset = i * 4 + channel * 2
    let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    channels[channel][i] = Float(Int16(bitPattern: bits)) / 32768.0
   }
  }
 }
 inflight.wait()
 player.scheduleBuffer(buffer) { inflight.signal() }
 return true
 }
 if !more { break }
}
for _ in 0..<4 { _ = inflight.wait(timeout: .now() + 2) }
engine.stop()
