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
- `bin/blackhole-pcm-arm64`：保留作为参考的旧版 Apple Silicon 二进制，构建目标为 macOS 27.2；它不含内存释放修复。该二进制使用临时签名，未经过 Apple 公证。
- `bin/blackhole-pcm-v2-arm64`：支持指定 44100 或 48000 Hz 的接收器，构建目标为 macOS 27.2。
- `bin/macmic-native-sender-x86_64`：Intel 发送器，构建目标为 macOS 13.0；其他架构可从源码编译。
- `send-microphone-native.fish`：使用默认麦克风的低 CPU 脚本。
- `send-microphone.fish`：发送端脚本，目标地址和麦克风编号通过参数提供。
- `skills/mac-mic-bridge/SKILL.md`：供 Agent 部署和排查本方案的可选 Skill。
- `tools/`：用于[音频时间戳与时钟差测量](tools/README.md)的诊断工具。

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

备用方案使用原有接收器路径；在接收端将 v2 构建安装为 `~/.local/bin/blackhole-pcm`（不带采样率参数时默认 48000 Hz）。旧版接收器不含内存释放修复，应避免使用。

在发送端克隆仓库并进入本目录，在本机图形会话的 **Terminal** 中列出 AVFoundation 音频设备：

```fish
ffmpeg -hide_banner -f avfoundation -list_devices true -i ''
```

在输出的 `AVFoundation audio devices` 中找到麦克风的数字编号。上面的列表命令结束时可能提示输入错误，这是列出设备时的正常表现。运行脚本时把示例占位符替换为实际的接收端 SSH 用户、主机名或 Tailscale 地址及麦克风编号：

```fish
fish send-microphone.fish '<ssh-user>@<mac-mini-host>' '<audio-device-index>'
```

示例中的尖括号表示需要替换的内容。首次运行时如果出现提示，请允许 **Terminal** 使用麦克风。保持 Terminal 窗口打开；按 **Control-C** 停止。脚本不保存音频文件。麦克风设备顺序变化后应重新检查编号。

## 延迟优化

核心改动是减少等待音频块填满的时间，并限制旧音频积压。旧原生链路每块采集 4096 字节（23.2ms），接收端每块读取 8192 字节（46.4ms），允许四块播放队列加一块等候数据。这五块接收端数据就代表约 232ms 音频，此外还有管道、SSH 和设备缓冲。这解释了积压机制，但不能单凭源码认定某次一秒延迟的全部来源。以下时长按 44.1 kHz、双声道、16 位 PCM 计算，即每秒 176400 字节。

| 环节 | 当前实现 | 作用 |
| --- | --- | --- |
| 采集 | 每个缓冲 128 帧、512 字节，约 2.90ms | 缩短单块采集等待；硬件和 AudioQueue 仍可能成批交付回调。 |
| 写入 SSH 管道 | 非阻塞写入，单次不超过 Darwin 的 `PIPE_BUF`；遇到 `EAGAIN` 丢弃整块 | 避免 SSH 反压阻塞采集回调，同时保持 PCM 帧对齐。 |
| 接收读取 | 使用 POSIX `read`，收到多少就处理多少，保留跨读取拆开的双声道帧 | 取消等待凑满 8192 字节；当前 4096 字节读取容量只是上限，不要求填满。 |
| 播放 | `AVAudioSourceNode` 按设备需要从环形缓冲取数，上限 80ms；溢出时丢弃最旧帧 | 跟上实时声音，避免播放调度队列持续增长。 |
| 抖动处理 | 开始播放及缺帧恢复时预留 40ms，数据不足时补静音 | 为不均匀到达的数据留出余量；80ms 上限不等于固定等待 80ms。 |
| 回调同步 | PCM 解码移到锁外，锁内仅做短暂复制和队列更新；播放端使用 `trylock` | 避免输入线程解码时，让播放回调跳过整块声音。 |

发送端还使用 16 个空采集缓冲、独立的 user-interactive 调度队列，并在采集期间保持 latency-critical 活动。空缓冲用于承接硬件突发数据，不等于额外的固定播放排队。用户级采集锁防止后台助手重启后出现重复的原生发送器；多路声音叠加也可能产生重音或金属感。原生 SSH 脚本关闭压缩和 X11 forwarding，并请求 `IPQoS=ef`；该优先级请求是否生效取决于网络支持，不保证延迟。

### 降低延迟时保留声音连续性

最初将接收队列压到 20ms 后，瞬态延迟降低，但出现丢帧和机械音。PCM 解码占用共享锁又加重了问题：播放回调遇到锁竞争就会输出静音。最终采用 **40ms 预留量、80ms 队列上限**，并将解码移到锁外。继续盲目缩小缓冲会损害声音连续性。链路没有使用有损编码，但丢帧和补静音仍会损失声音片段。

这些改动限制的是应用内播放缓冲；SSH/TCP 在传输停顿时仍可能积压旧音频。独立的定时 TCP 测试复现了接近 399ms 的接收间隔，直接局域网路径也出现了停顿，具体来源仍未确定。40ms 余量无法掩盖数百毫秒中断，80ms 队列上限也不代表端到端延迟保证。

### 部署与验证

按前文步骤，在两台 Mac 上重新编译或安装更新后的程序，并重启链路。修改源码不会更新正在运行的进程。核对已安装程序与预期构建的校验值，并确认只有一套发送和接收进程。

运行 `blackhole-pcm-v2 --self-test`，可在不打开音频设备的情况下检查溢出、字节拆包、双声道转换、环绕、缺帧和预缓冲。实际测量使用[时间戳工具](tools/README.md)，在匹配瞬态前后测量单调时钟差。同时检查连续性：接收器退出时报告丢帧、缺帧、锁竞争、启动后的缺失帧和读取间隔统计；发送器可选参数 `--diagnostics` 输出采集数据年龄、回调间隔、电平、丢块数和瞬态时间戳，不保存音频，测试结束后应关闭。

2026 年 11 月 17 日，用户反馈当前运行版本已无明显延迟，但当前配置尚未重新测量准确的端到端数值。此前约 54ms 的中位数属于已被替换的 20ms 配置，不能作为当前配置或音频连续性的验收结果。低于 100ms 的验收需要同时检查校正后的时间戳和声音连续性；下游会议应用还可能额外缓冲。

## 验证与排查

在接收端 **System Settings > Sound > Input** 选择 **BlackHole 2ch**，对着发送端麦克风说话，确认 **Input level** 持续跳动。随后在目标会议或录音应用中选择 **BlackHole 2ch**，并录制片段验证。

如果没有声音，依次检查发送端的麦克风电平和 **System Settings > Privacy & Security > Microphone**、脚本选择的设备编号、SSH 连接、接收端程序路径以及目标应用的输入设备。不要通过 SSH 会话直接启动麦克风采集作为权限测试：macOS 可能不允许 SSH 服务弹出麦克风授权，导致采集到静音。网络抖动可能增加延迟；连接中断后需重新启动脚本。

如果需要在发送端录屏时同时听到系统声音，可以在 **Audio MIDI Setup** 创建包含扬声器和 BlackHole 的 **Multi-Output Device**。这是本机录屏用途，与上述网络麦克风传输相互独立。
