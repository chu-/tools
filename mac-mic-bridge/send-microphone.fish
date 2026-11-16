#!/usr/bin/env fish
# Microphone → FFmpeg/AVFoundation → SSH → Core Audio → BlackHole 2ch.
# Usage: fish send-microphone.fish user@host audio_device_index
# The selected device index can change when audio devices are added or removed.
# Run from a logged-in Terminal session with microphone permission; Ctrl-C stops it.
if test (count $argv) -ne 2
    echo 'Usage: fish send-microphone.fish user@host audio_device_index' >&2
    exit 2
end
if not string match -rq '^[0-9]+$' -- "$argv[2]"
    echo 'audio_device_index must be a non-negative number' >&2
    exit 2
end
if not command -sq ffmpeg
    echo 'FFmpeg not found in PATH' >&2
    exit 1
end

ffmpeg -nostdin -hide_banner -loglevel warning -f avfoundation -i ":$argv[2]" -ac 2 -ar 48000 -f s16le -flush_packets 1 pipe:1 | ssh -T -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=8 -- "$argv[1]" '~/.local/bin/blackhole-pcm'
