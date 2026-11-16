# Mac Mic Bridge

[English](README.md) | 简体中文

将一台 Mac 的麦克风实时发送到另一台 Mac，并通过接收端的 BlackHole 2ch 提供给会议或录音应用。两台 Mac 可以通过 Wi-Fi 上的 Tailscale 连接。

**Agent 指引：** 如果用户要求部署、运行或排查 Mac Mic Bridge，请先阅读并遵循 [Mac Mic Bridge Skill](skills/mac-mic-bridge/SKILL.md)，再根据本 README 和当前设备状态执行。设备地址、用户和音频设备编号需要现场确认。

```text
发送端麦克风 → AudioQueue（或 FFmpeg）→ SSH → 接收端 blackhole-pcm
                                              ↓
                                      BlackHole 2ch → 目标应用
```

原生发送器通过 AudioQueue 采集默认输入，使用 44.1 kHz、双声道、16 位小端 PCM；也可使用 FFmpeg 作为 48 kHz 方案。SSH 将音频流传给接收端；`blackhole-pcm` 使用 macOS Core Audio 将其写入 BlackHole。BlackHole 提供本机虚拟输入，本身不传输网络音频。SSH 加密传输，Tailscale 可以提供设备之间的连接；Tailscale 可能直连或使用中继。

## 文件

- `src/blackhole-pcm.swift`：接收程序 Swift 源码。
- `src/macmic-native-sender.swift`：低 CPU 的原生采集程序 Swift 源码。
- `bin/blackhole-pcm-arm64`：已验证使用的 Apple Silicon 二进制，构建目标为 macOS 27.2。其他系统版本或架构请从源码重新编译；该二进制使用临时签名，未经过 Apple 公证。
- `bin/blackhole-pcm-v2-arm64`：支持指定 44100 或 48000 Hz 的接收器，构建目标为 macOS 27.2。
- `bin/macmic-native-sender-x86_64`：Intel 发送器，构建目标为 macOS 13.0；其他架构可从源码编译。
- `send-microphone-native.fish`：使用默认麦克风的低 CPU 脚本。
- `send-microphone.fish`：发送端脚本，目标地址和麦克风编号通过参数提供。
- `skills/mac-mic-bridge/SKILL.md`：供 Agent 部署和排查本方案的可选 Skill。

## 前提

两台机器运行 macOS，接收端安装 [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)，发送端需要 fish。FFmpeg 仅用于下方的备用方案。两端需要可访问的 SSH 连接；以下示例使用 Tailscale，但 SSH 可通过其他可达网络运行。

在接收端的 **System Settings > General > Sharing** 打开 **Remote Login**。配置发送端到接收端的 SSH 密钥登录，并先人工连接一次以核对并接受主机密钥。确保发送端登录用户有权在接收端运行其用户目录中的程序。

## 接收端：部署程序

在接收端克隆仓库并进入本目录。使用 Apple Silicon 且系统版本满足上面的条件时，可安装预编译文件：

```fish
mkdir -p ~/.local/bin
install -m 755 bin/blackhole-pcm-v2-arm64 ~/.local/bin/blackhole-pcm-v2
```

也可以用 Xcode 或 Command Line Tools 中的 Swift 在接收端本机编译：

```fish
mkdir -p ~/.local/bin
swiftc -O src/blackhole-pcm.swift -o ~/.local/bin/blackhole-pcm-v2
```

确认 **System Settings > Sound > Input** 中能看到 **BlackHole 2ch**。如果安装器要求，重启 Mac。确保目标应用有麦克风权限。

## 发送端：低 CPU 模式

在发送端克隆仓库并进入本目录。Intel Mac（macOS 13.0 或更新）可安装预编译文件：

```fish
mkdir -p ~/.local/bin
install -m 755 bin/macmic-native-sender-x86_64 ~/.local/bin/macmic-native-sender
```

也可在发送端本机编译（需要 Xcode 或 Command Line Tools）：

```fish
mkdir -p ~/.local/bin
swiftc -O src/macmic-native-sender.swift -o ~/.local/bin/macmic-native-sender
```

在发送端的 **System Settings > Sound > Input** 选择要使用的麦克风。在本机图形会话的 **Terminal** 中运行，并将占位符替换为接收端 SSH 用户和主机名或 Tailscale 地址：

```fish
fish send-microphone-native.fish '<ssh-user>@<mac-mini-host>'
```

首次运行时允许 Terminal 使用麦克风，保持窗口打开；按 **Control-C** 停止。该模式禁用 SSH 压缩，使用 `aes128-gcm@openssh.com`，需要两端 SSH 支持该加密算法。某次 20 秒测试中，Intel MacBook 上采集和 SSH 进程合计约占一个逻辑核心的 0.8%；实际占用随硬件和环境变化。

## 发送端：FFmpeg 备用模式

备用方案使用原有接收器路径；在接收端安装兼容的 `bin/blackhole-pcm-arm64` 为 `~/.local/bin/blackhole-pcm`，或将 v2 构建安装到该路径（不带采样率参数时默认 48000 Hz）。

在发送端克隆仓库并进入本目录，在本机图形会话的 **Terminal** 中列出 AVFoundation 音频设备：

```fish
ffmpeg -hide_banner -f avfoundation -list_devices true -i ''
```

在输出的 `AVFoundation audio devices` 中找到麦克风的数字编号。上面的列表命令结束时可能提示输入错误，这是列出设备时的正常表现。运行脚本时把示例占位符替换为实际的接收端 SSH 用户、主机名或 Tailscale 地址及麦克风编号：

```fish
fish send-microphone.fish '<ssh-user>@<mac-mini-host>' '<audio-device-index>'
```

示例中的尖括号表示需要替换的内容。首次运行时如果出现提示，请允许 **Terminal** 使用麦克风。保持 Terminal 窗口打开；按 **Control-C** 停止。脚本不保存音频文件。麦克风设备顺序变化后应重新检查编号。

## 验证与排查

在接收端 **System Settings > Sound > Input** 选择 **BlackHole 2ch**，对着发送端麦克风说话，确认 **Input level** 持续跳动。随后在目标会议或录音应用中选择 **BlackHole 2ch**，并录制片段验证。

如果没有声音，依次检查发送端的麦克风电平和 **System Settings > Privacy & Security > Microphone**、脚本选择的设备编号、SSH 连接、接收端程序路径以及目标应用的输入设备。不要通过 SSH 会话直接启动麦克风采集作为权限测试：macOS 可能不允许 SSH 服务弹出麦克风授权，导致采集到静音。网络抖动可能增加延迟；连接中断后需重新启动脚本。

如果需要在发送端录屏时同时听到系统声音，可以在 **Audio MIDI Setup** 创建包含扬声器和 BlackHole 的 **Multi-Output Device**。这是本机录屏用途，与上述网络麦克风传输相互独立。
