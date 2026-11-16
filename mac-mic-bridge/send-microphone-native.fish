#!/usr/bin/env fish
# Default input → AudioQueue (44.1 kHz stereo PCM) → SSH → BlackHole.
# Run inside an authorized Terminal session; Ctrl-C stops the bridge.
if test (count $argv) -ne 1
    echo 'Usage: fish send-microphone-native.fish user@host' >&2
    exit 2
end
if not test -x "$HOME/.local/bin/macmic-native-sender"
    echo 'Install macmic-native-sender in ~/.local/bin first' >&2
    exit 1
end
$HOME/.local/bin/macmic-native-sender | ssh -T -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=8 -o Compression=no -c aes128-gcm@openssh.com -- "$argv[1]" '~/.local/bin/blackhole-pcm-v2 44100'
