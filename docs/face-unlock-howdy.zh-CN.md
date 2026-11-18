# U9311 红外摄像头与 Windows Hello 式人脸解锁

让 **Fujitsu LIFEBOOK U9311** 的摄像头在 Arch / Omarchy 上做真正的人脸解锁——覆盖锁屏、
`sudo`、SDDM 登录，以及 polkit（1Password 的验证就在这条链上）。

和指纹那篇一样：所有内容在同一台真机上执行并实测，失败过的方案也写在里面。

**测试环境：** Fujitsu LIFEBOOK U9311 (i7-1165G7)、Arch Linux、kernel 6.x、Omarchy 4.x、
`howdy-next 3.4.2`、OpenCV 5.0.0。

> 英文完整版：[face-unlock-howdy.md](face-unlock-howdy.md)

---

## TL;DR

1. 这台机器**有红外摄像头**。`lsusb` 只显示一个 `FJ Camera`，但同一个 USB 设备暴露了
   **四个** video 节点，其中 `/dev/video2` 的 `Card type` 是 `FJ Camera: IR Camera`，
   格式 `GREY` 640×360。**不要用彩色节点** —— 彩色能被照片骗过，IR 不能。
2. 用 AUR 的 `howdy-next`（C++ 重写，OpenCV YuNet + SFace）。不依赖 dlib，
   编译约 10 分钟，比老的 python howdy 省事太多。
3. **`timeout` 必须调到 20。** howdy-next 给比对子进程设的 CPU 预算是
   `timeout + 5s`（软）/ `timeout + 10s`（硬），下限 15s。默认 4s 只给 9 秒 CPU，
   IR 帧的 SFace 推理一打满就被 `SIGXCPU` 杀掉，表现成
   `Face verification timed out` **且没有任何输出**。改成 20 后通过率 1/6 → 8/8。
4. 注册 **3–5 个**模型。单个模型得分在 0.60–0.70 徘徊（阈值 0.6942），勉强；4 个模型后
   0.67–0.94，稳过。
5. `howdy test` 是**交互预览窗口**，会挂到超时才退出，不能用于脚本验证。要读取得分必须
   开 `end_report` 后直接跑 `/usr/lib/howdy/howdy-compare <user>`。
6. **1Password 的验证走 polkit，不是它自己的 PAM。** 想让 1Password 优先人脸，
   改 `/etc/pam.d/polkit-1`，改 1Password 设置没有任何用。
7. **别把 `/dev/v4l/by-id/...-video-index0` 当成稳定路径。** 名字里的 `indexN` 是 sysfs
   `index` 的值，不是节点号；这颗摄像头彩色和 IR 两个传感器都报 `index=0`，所以重启后
   这个链接会从 IR 节点漂到彩色节点，人脸直接 `cannot open configured camera`。
   **本机真人踩过这个坑。** 必须按 sysfs `name` + `index` 认设备，并开机重新 pin（§1）。

---

## 1. 识别硬件：那个被 `lsusb` 藏起来的 IR 节点

第一轮排查时我差点得出「这台机器没有 IR，只能上可见光」的结论：

```bash
$ lsusb
Bus 003 Device 004: ID 04f2:b703 Chicony Electronics Co., Ltd FJ Camera
```

一个摄像头，没有第二个红外设备。看起来就是普通 RGB 摄像头。

**但这个结论是错的。** 同一个 UVC 设备会注册多个 video 节点（采集、元数据、
以及**独立的 IR 传感器**）。必须用 `v4l2-ctl` 看每个节点的 `Card type`：

```bash
$ for d in /dev/video*; do
    printf '%-12s %s\n' "$d" "$(v4l2-ctl -d "$d" --info 2>/dev/null | grep 'Card type')"
  done
```

```
/dev/video0  Card type        : FJ Camera: FJ Camera
/dev/video1  Card type        : FJ Camera: FJ Camera
/dev/video2  Card type        : FJ Camera: IR Camera      ← 这个
/dev/video3  Card type        : FJ Camera: IR Camera
```

再看格式，区别一眼就能看出来：

```bash
$ v4l2-ctl -d /dev/video2 --list-formats-ext
[0]: 'GREY' (8-bit Greyscale)
        Size: Discrete 640x360
            Interval: Discrete 0.033s (30.000 fps)
```

**只有 8-bit 灰度、只有 640×360 一个档位、没有 MJPG/YUYV** —— 这就是红外通道。
彩色节点那边则是 `MJPG` 1280×720 / `YUYV` 640×480。

抓一帧确认（`</dev/null` 必须加，否则 ffmpeg 会等 stdin 直到超时）：

```bash
ffmpeg -f v4l2 -video_size 640x360 -input_format gray \
       -i /dev/video2 -frames:v 1 -update 1 -y /tmp/ir.jpg </dev/null
```

**为什么必须是 IR：** 照片和 LCD 屏幕不发射红外。可见光人脸识别本质上是在比纹理，
一张打印照片、甚至手机屏幕上的一张照片都可能通过。IR 图像只反映主动补光下的反射率，
照片在那个波段是黑的。这是 Windows Hello 用 IR 的原因，也是这里唯一的正确选择。

### 别用 `by-id`，也别硬编码 `/dev/videoN`

这一节是本篇里**最重要的纠正**。第一版文档推荐了 `/dev/v4l/by-id/`，那是错的，
而且错得很隐蔽——它会工作，直到某次重启。

`by-id` 的链接名长这样：

```bash
$ ls -la /dev/v4l/by-id/
usb-SunplusIT_Inc_FJ_Camera_01.00.00-video-index0 -> ../../video2
usb-SunplusIT_Inc_FJ_Camera_01.00.00-video-index1 -> ../../video3
```

看起来 `index0` 就是「第 0 个采集节点」，稳定可靠。**但名字里的 `indexN` 不是节点号，
而是 sysfs 里 `index` 文件的值**：

```bash
$ for f in /sys/class/video4linux/video*/index; do echo "$f = $(cat $f)"; done
/sys/class/video4linux/video0/index = 0     # 彩色采集
/sys/class/video4linux/video1/index = 1     # 彩色元数据
/sys/class/video4linux/video2/index = 0     # IR 采集   ← 和 video0 撞了
/sys/class/video4linux/video3/index = 1     # IR 元数据
```

**这颗摄像头有两个传感器（彩色 + IR），两个都报 `index=0`。** 于是
`...-video-index0` 到底指向谁是枚举顺序说了算。本机实测：

| | `...-video-index0` 指向 | 结果 |
|---|---|---|
| 装完当天 | `video2`（IR） | 正常，8/8 通过 |
| **重启一次后** | **`video0`（彩色）** | `Failed to open camera device` |

第一次重启后人脸就废了，日志是：

```
pam_howdy(sudo:auth): Face verification failed: cannot open configured camera
```

更糟的情况是：如果彩色节点恰好能打开，人脸会**静默地改用彩色摄像头**——功能看起来
正常，但已经失去了 IR 防照片的性质，而这正是当初选 IR 的全部理由。

### 正确做法：按 sysfs 的 name + index 认设备，并且开机重新认一次

```bash
for d in /sys/class/video4linux/video*; do
  [[ $(cat "$d/name") == *"IR Camera"* && $(cat "$d/index") == 0 ]] \
    && echo "/dev/$(basename "$d")"
done
# → /dev/video2
```

`name` 是驱动上报的字符串，`index` 区分采集口和元数据口，两者组合唯一且不随枚举顺序变。
但 `/dev/videoN` 这个**编号**本身还是会变，所以不能写死——要开机重新写一遍 config。
`scripts/u9311-face-unlock-setup.sh --pin` 会安装一个 systemd oneshot + 一条 udev 规则来做这件事：

```bash
# 核心逻辑，装成 /usr/local/bin/u9311-ir-camera-pin
ir=""
for d in /sys/class/video4linux/video*; do
  [[ $(cat "$d/name") == *"IR Camera"* ]] || continue
  [[ $(cat "$d/index") == 0 ]] || continue
  ir="/dev/$(basename "$d")"; break
done
[[ $(sed -n 's/^device_path = //p' /etc/howdy/config.ini) == "$ir" ]] || howdy set device_path "$ir"
```

udev 规则让摄像头在 resume / 重新枚举时也触发一次：

```
ACTION=="add", SUBSYSTEM=="video4linux", ATTR{name}=="*IR Camera*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="u9311-ir-camera-pin.service"
```

> 顺带一个观察：厂商字符串是 **SunplusIT**（`lsusb` 报的是 Chicony，两者都对，
> 一个是 USB 描述符里的 `iManufacturer`，一个是 `idVendor` 的厂商库名）。

---

## 2. 为什么不用老 howdy

老 `howdy`（boltgolt/howdy）走 python + `dlib`：要编译 dlib（半小时起，还经常在
CUDA/AVX 上翻车）、要 `pam-python`（Python 2 时代的产物）、特征模型是 dlib 的
`shape_predictor_68_face_landmarks` + ResNet。

`howdy-next` 是同一个作者的思路的 C++ 重写：

| | howdy (原版) | howdy-next |
|---|---|---|
| 语言 | Python | C++ |
| 人脸检测 | dlib HOG/CNN | OpenCV **YuNet**（ONNX） |
| 人脸特征 | dlib ResNet | OpenCV **SFace**（ONNX） |
| 依赖 | `python-dlib`、`pam-python` | `opencv`、`pam`、`libinih`、`yyjson` |
| 编译时间 | 30–60 分钟 | ~10 分钟 |
| PAM 模块 | `pam_python.so` 回调 Python | 原生 `pam_howdy.so` |

```bash
yay -S howdy-next
sudo howdy download-models     # 下 YuNet + SFace 到 /usr/share/howdy/models
```

装完包里会打印一份 SETUP 提示，照着走即可。

> 另有一个 `visagate`（RGB+IR for Logitech webcams），只支持罗技摄像头，不适用。

---

## 3. 配置

`howdy set` 只接受**裸键名**，不接受 `video.device_path` 这种带 section 的写法：

```bash
sudo howdy set device_path video.device_path       # ✗ Could not find a "video.device_path" config option
sudo howdy set device_path /dev/video2             # ✓
```

负数要写成 `-- -1`，否则被当成选项：

```bash
sudo howdy set frame_width -1          # ✗ error: unexpected argument '-1' found
sudo howdy set frame_width -- -1       # ✓
```

最终配置（`/etc/howdy/config.ini`）：

```ini
[core]
abort_if_lid_closed = false    # 合盖外接屏也要能解锁
disabled = false

[video]
device_path = /dev/video2        # 由 pin 服务维护，别硬编码 —— 见 §1
                                 # (en) maintained by the pin service
timeout = 20                   # ← 关键，见 §4
max_height = 320               # 降分辨率换速度，320 已足够 YuNet
frame_width = 640
frame_height = 360
dark_threshold = 85            # IR 近距离容易过曝，80 以下会误判「太暗」
clahe_enabled = true           # 低对比度 IR 帧的对比度增强，有用
exposure = -1                  # 自动曝光
rotate = 0

[face]
yunet_score_threshold = 0.6    # 默认 0.8845 太严，过曝帧会被丢掉
sface_threshold = 0.60         # 单模型期临时放宽；多模型后可回 0.6942
```

---

## 4. 最坑的一个：`Face verification timed out` 其实是 CPU 超限

这是整件事里最贵的两小时。

现象：PAM 认证失败，日志只有一行

```
pam_howdy(howdy-test:auth): Face verification timed out
```

而直接跑比对进程，**什么输出都没有**，退出码 11（`kTimeoutReached`）：

```bash
$ sudo /usr/lib/howdy/howdy-compare murgo
[ WARN:0@0.010] global net_impl_backend.cpp:345 setPreferableTarget Targets are not supported...
[ WARN:0@0.043] ...
$ echo $?
11
```

但同样的命令，偶尔又能成功，还打印出漂亮的报告：

```
Total time: 3758ms
Frames searched: 38
Black frames ignored: 19
Winning score: 0.739385
```

一会儿成功一会儿超时，看起来像是「摄像头时好时坏」或者「IR 补光灯闪烁」。
**都不是。**

### 根因

读 `howdy/src/compare/sandbox.cpp`：compare 子进程在降权前会给自己设一组 rlimit，
其中 CPU 时间是这样算的：

```cpp
constexpr rlim_t kCpuSoftMargin = 5;
constexpr rlim_t kCpuHardMargin = 10;
constexpr rlim_t kCpuSoftFloor  = 15;

preferred_cpu_soft = max(timeout_seconds + kCpuSoftMargin, kCpuSoftFloor);
preferred_cpu_hard = max(timeout_seconds + kCpuHardMargin, kCpuHardFloor);
```

默认 `timeout = 4`，于是软限 **9 秒**、硬限 **14 秒**。

而 IR 帧的处理链是「多帧采集 → YuNet 检测 → 逐张脸 SFace 编码 → 余弦比对」，
在 640×360 上每帧都不便宜。一旦 CPU 时间烧到软限，内核发 `SIGXCPU`，进程当场死掉
——**没有任何输出，退出码 152（128+24）**。

关键就是：**失败时它根本走不到「超时」那个分支，是被信号杀的。** 而 PAM 层看到的是
子进程异常退出，映射成了 `kTimeoutReached` 的文案。所以日志在撒谎。

这也解释了「时好时坏」：机器负载低、帧少的时候刚好卡在 9 秒内就成功；多跑几帧就越线。

### 实测数据

同一位置、同一光照，只改 `timeout`，每次间隔 2 秒：

| `timeout` | CPU 软限 | 通过率 | 备注 |
|---|---|---|---|
| 4（默认） | 9 s | **1 / 6** | 失败全部是静默退出 |
| 8 | 13 s | 3 / 5 | |
| 12 | 17 s | 5 / 6 | 1 次 `code=152`，`CPU 时间超出限制` |
| **20** | **25 s** | **8 / 8** | |

`timeout = 12` 那次失败的 bash 报错直接暴露了真相：

```
/usr/bin/bash: 第 1 行：959159 CPU 时间超出限制     sudo /usr/lib/howdy/howdy-compare murgo
```

> **怎么判断你踩的是这个坑：** 直接跑 `howdy-compare`，看退出码。
> `0` 成功 / `11` 真超时 / `152` 被 `SIGXCPU` 杀掉 / `13` 太暗 / `14` 设备打不开 /
> `10` 没有注册模型。**「11」在默认配置下九成九其实是 152 的误报。**

---

## 5. 注册人脸：多录几个

```bash
sudo howdy add --plain -y     # 重复 3–5 次，中间换距离和角度
sudo howdy list
```

```
0   2026-11-12 22:24:47  Model #0
1   2026-11-12 22:42:46  Model #1
2   2026-11-12 22:42:51  Model #2
3   2026-11-12 22:42:57  Model #3
```

SFace 的匹配是「与所有已注册特征逐一比对，取最高分」，所以多录几个不同姿态的样本
直接抬高上限：

| 模型数 | 得分区间 | 相对阈值 0.6942 |
|---|---|---|
| 1 | 0.60 – 0.70 | 边缘，时过时不过 |
| 4 | 0.67 – 0.94 | 稳过 |

**录制时的距离很关键。** IR 补光灯在近距离（< 20 cm）会把脸打成一片白：

| 距离 | 画面 | 能否识别 |
|---|---|---|
| 贴脸 | 全白，只剩眼镜反光点 | 勉强能（靠轮廓+镜框），但很丑 |
| **40–60 cm** | 五官清晰，眼镜镜片是黑的（IR 穿不透玻璃） | **最佳** |
| > 1 m | 脸占比太小，YuNet 漏检 | 不行 |

---

## 6. 验证：`howdy test` 骗过很多人

`howdy test` 会开一个 OpenCV HighGUI 预览窗口（Qt/Wayland），**一直挂着直到你关掉或超时**。
在非交互 shell 里它什么都不打印，于是很容易误判成「卡住了」：

```bash
$ timeout 25 sudo howdy test -U murgo
qt.qpa.wayland.textinput: ... Trying to disable 0x55c411284c00 but 0x0 is focused
$ echo $?
124        # 被 timeout 杀掉的，不是程序自己退出
```

**正确做法**是直接调比对入口，并打开 `end_report`：

```bash
sudo howdy set end_report true

for i in 1 2 3; do
  sudo /usr/lib/howdy/howdy-compare murgo
  echo "exit=$?"
  sleep 2
done

sudo howdy set end_report false     # 调试完记得关掉
```

成功时：

```
Total time: 1364ms
Frames searched: 2
Black frames ignored: 1
Dark frames ignored: 0
Winning score: 0.93688
Winning model: 0 ("Model #0")
```

`Frames searched` 只有 2、`Total time` 1.3 秒，说明它**不需要**等满 `timeout`
—— 前几帧找到匹配就立刻返回。`timeout = 20` 只在「完全看不到脸」时才耗尽。

### PAM 层：`pamtester` 必须加 `-v`

```bash
yay -S pamtester
pamtester -v <service> murgo authenticate </dev/null
```

**不加 `-v` 时成功也只打印 `pamtester: successfully authenticated`**，
失败则什么相关的都不说，极容易误判。加上 `-v` 才能看到 `Face matched user murgo` 这一行。

模拟锁屏那种「无 TTY」环境再测一遍：

```bash
setsid pamtester -v <service> murgo authenticate </dev/null
```

---

## 7. 接 PAM：四处入口

原则一致：**`sufficient` + 密码永远兜底**。人脸失败不应该比没有这个人脸功能更糟。

> **动手前先开一个 root shell**（`sudo -i`，或者另一个 TTY 里登录 root）。
> PAM 写错了会让你既进不了 `sudo` 也登不了桌面，那时候只能靠 root shell 或 live USB 救。
> 这不是危言耸听——本仓库的 `scripts/` 每个改动都带 `.bak.<时间戳>` 备份，就是为了这一刻。

### 7.1 `sudo`

本机 `sudo` 已经配了指纹（`pam_fprintd.so`）。人脸放在它**前面**，指纹退居兜底：

```bash
# /etc/pam.d/sudo
auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_howdy.so
auth      sufficient pam_fprintd.so
#%PAM-1.0
auth      include    system-auth
account   include    system-auth
session   include    system-auth
session   optional   pam_systemd.so class=none
```

**`success=1` 要改成 `success=2`。** 这行的语义是「合盖时返回成功，跳过后面 N 个模块直落密码」，
现在前面有两个生物识别模块，N 就得是 2。写错的话合盖时只跳过一个，正好停在指纹上，
表现成「一合盖又回去按指纹」。

**人脸优先的代价要清楚：** 摄像头每次都会先开，扫描最长 `timeout`（20 秒）。坐在屏幕前是
1.3–2 秒，没问题；但如果你锁了 `sudo` 凭据又背对屏幕去干别的，它会先等满 20 秒才轮到指纹。

如果你更想「指纹优先、人脸兜底」，把这两行换回来，`success` 改回 1 即可——两种都合法，
取决于你更常做哪个动作。本机选人脸优先是因为绝大多数 `sudo` 都发生在屏幕前。

> 原文件里 `#%PAM-1.0` 在第三行，是被上游插进去的；保持原样即可，PAM 不要求它必须在首行。

### 7.2 锁屏

新建一个专用服务，和 `omarchy-lock-fingerprint` 并列：

```bash
# /etc/pam.d/omarchy-lock-face
#%PAM-1.0
auth       sufficient                  pam_howdy.so
account    include                     system-local-login
```

### 7.3 SDDM 登录

```bash
# /etc/pam.d/sddm
auth        sufficient  pam_howdy.so
auth        include     system-login
```

### 7.4 polkit —— 1Password 就在这里

这是这篇文档里第二个「反直觉」的点。**1Password 的「用系统认证解锁」不走它自己的 PAM，
走 polkit。** 证据在 1Password 自己的日志里：

```
$ journalctl -b | grep -A2 "1password"
1password[1281]: [1P:app/op-app/src/app/backend/auth_prompt.rs:147] invoked system auth unlock in locked state
polkit-agent-helper-1[1042829]: pam_exec(polkit-1:auth): /usr/bin/omarchy-hw-laptop-closed failed: exit code 1
1password[1281]: [1P:iam/op-iam-observability/src/lib.rs:151] event=system_auth outcome=success
```

`polkit-agent-helper-1` 在跑 `/etc/pam.d/polkit-1`。所以「让 1Password 优先人脸」
= 改 `/etc/pam.d/polkit-1`，在 1Password 的设置里翻多久都没用。

```
# /etc/pam.d/polkit-1
auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_howdy.so
auth      sufficient pam_fprintd.so
auth      include system-auth
```

**`success=1` 必须改成 `success=2`。** 这行的语义是「如果检测到合盖就返回成功，
跳过后面 N 个模块直落密码」。原来只跳过 `pam_fprintd`，现在前面多插了 `pam_howdy`，
所以 N 要跟着 +1。**改错会得到一个诡异的现象：不合盖时人脸正常，一合盖反而又去等指纹。**

> **副作用：** `polkit-1` 是全局的。改完之后所有桌面授权（挂载磁盘、改系统设置、
> 装包提权）都会先开一次摄像头。查过 7 天日志，本机 polkit 认证总共 18 次、
> 基本全是 1Password 触发的，骚扰成本很低。如果哪天嫌烦，直接把 `pam_howdy.so` 那行删掉即可。

**验证整条弹窗链路**（`pkexec` 也用 `polkit-1` 这个服务名）：

```bash
time pkexec true
# 应该弹 polkit 对话框 → 摄像头指示灯亮 → 1.5 秒左右通过
```

---

## 8. Omarchy 锁屏：给 Quickshell 插件加一条并行的人脸通道

本机的锁屏不是 `hyprlock`，是 Omarchy 自己的 Quickshell 插件：
`~/.config/omarchy/plugins/murgo.lock/`。它原本只处理密码和指纹。

**关键设计决定：人脸必须是独立的一条 `PamContext`，不能复用指纹那条。**

原因：一次人脸扫描要 1–20 秒（`timeout`），而指纹是「按一下、1 秒内出结果」。
如果两者共用一个 PAM 上下文，人脸扫描期间用户按指纹会被挡住——指纹那条路就废了。

### 加的东西

`Service.qml`：

```qml
// 1. 属性（QML 属性名不能以大写字母开头，见下面的坑）
property bool faceAuthenticating: false
property bool faceConfigured: false
property int faceFailStreak: 0
property bool facePaused: false

readonly property int faceRetryMs: 1500       // 两次扫描之间的间隔
readonly property int faceBackoffMs: 8000     // 连续失败后的退避
readonly property int faceUnavailableStreak: 4

// 2. 独立的 PAM 上下文
PamContext {
  id: facePam
  config: "omarchy-lock-face"
  user: root.userName
  onCompleted: function(result) { root.handleFaceFinished(result) }
  onError: function(error) { root.settleFaceAttempt() }
}

// 3. 串行重试，一次只跑一个扫描
Timer {
  id: faceRetryTimer
  interval: root.faceRetryMs
  repeat: false
  onTriggered: root.startFace()
}
```

### 挂到锁屏的生命周期

| 钩子 | 动作 | 为什么 |
|---|---|---|
| `onSecureStateChanged` (secure=true) | `startFace()` | 锁屏真正就位后再开摄像头 |
| `runWake()` | `resumeFace()` | 用户动一下鼠标/键盘就恢复扫描 |
| `runBlank()` | `pauseFace()` | 屏幕熄灭时不能一直占着摄像头 |
| `submitPassword()` | `facePam.abort()` | 用户开始打字了，别再抢 |
| `handlePasswordFailure()` | 重启 `faceRetryTimer` | 密码错了，人脸再来一轮 |

**`submitPassword()` 里 `abort()` 必须放在 `runWake()` 之后**：

```qml
function submitPassword(value) {
  ...
  runWake()                    // 里面会调 resumeFace()，把 timer 启动
  if (facePam.active) facePam.abort()   // 所以 abort 必须在这之后
  faceAuthenticating = false
  faceRetryTimer.stop()
  ...
}
```

顺序反过来的话，`runWake()` 会把刚停掉的 timer 又启动起来，`abort()` 白做。

### 可用性探测

不要只检查文件存在，还要确认 howdy 真的注册了模型，否则图标会撒谎：

```qml
Process {
  id: faceStatusCheckProc
  command: ["bash", "-c",
    "if [[ -f /etc/pam.d/omarchy-lock-face ]] && command -v howdy >/dev/null 2>&1; then " +
    "howdy list 2>/dev/null | grep -q . ; else exit 1; fi"]
  onExited: function(exitCode) { root.applyFaceProbe(exitCode) }
}
```

锁屏 UI 上在密码框**左侧**放了个状态图标（右侧是指纹，左右对称）：
扫描中 `󰈈`、空闲 `󰈉`、摄像头不可用 `󰚃`（红色）。

### 实测结果

```
omarchy lock 2026-11-12T14:49:11.022Z lock-requested
omarchy lock 2026-11-12T14:49:11.185Z face-configured
omarchy lock 2026-11-12T14:49:11.631Z face-scan-start
omarchy lock 2026-11-12T14:49:13.169Z face-matched
omarchy lock 2026-11-12T14:49:13.170Z unlocked
```

从锁屏到解锁 **1.5–2.1 秒**，两轮独立测试都成功。

---

## 9. 坑：QML 属性名不能以大写字母开头，而 `qmllint` 不报

第一版我照 C 的惯例写了：

```qml
readonly property int FACE_RETRY_MS: 1500
```

`qmllint` **完全沉默**（退出码 0，只有一堆无害的 `var in block scope` 警告）。
但 Quickshell 加载插件时直接拒绝：

```
WARN qml: service plugin load failed for murgo.lock:
  Service.qml:85:25: Property names cannot begin with an upper case letter
```

**锁屏功能整个消失**——不是人脸失效，是整个锁屏插件不加载。而且这个错误只在
`journalctl` 里，界面上没有任何提示。

改成 `faceRetryMs` / `faceBackoffMs` / `faceUnavailableStreak` 后正常。

> **教训：** 改 Quickshell 插件后，`omarchy-restart-shell` 之后**必须**查一遍
> `journalctl --user | grep "plugin load failed"`。`qmllint` 通过不等于能加载。

另外：改完 QML 要 `omarchy-restart-shell`。只保存文件不会生效
（虽然日志里会出现 `Local plugin changed, reloading`，但插件热重载对失败的插件不可靠）。

---

## 10. 排障对照表

| 现象 | 根因 | 处理 |
|---|---|---|
| `Face verification timed out` 且无输出 | **CPU 超限被 `SIGXCPU` 杀**（退出码 152） | `sudo howdy set timeout 20` |
| 画面全白一片 | IR 补光灯近距离过曝 | 拉开到 40–60 cm；或调 `exposure` |
| 画面全黑 | IR 灯未亮 / 未稳定 | 等 1–2 秒；`howdy snapshot` 复核 |
| `Configured camera device does not exist` | `/dev/videoN` 编号变了 | 装 pin 服务（`--pin`），别用 by-id |
| 得分在 0.60 上下徘徊 | 只注册了 1 个模型 | 再录 3–4 个 |
| `howdy test` 挂着不动、无输出 | 它是交互预览窗口 | 改用 `howdy-compare` + `end_report` |
| `pamtester` 说成功但看不到提示 | 忘了 `-v` | 加 `-v` |
| 1Password 还在验指纹 | 改错服务了，它走 `polkit-1` | 改 `/etc/pam.d/polkit-1` |
| **重启后人脸失效**，`cannot open configured camera` | `by-id` 的 `indexN` 指向了彩色节点 | 跑 `--pin` 装 pin 服务，别用 by-id |
| 人脸"能用"但照片也能过 | 同上，静默跑在彩色摄像头上 | 看 `device_path` 是否真的是 IR 节点 |
| 合盖后反而等指纹 | lid 那行 `success=N` 与模块数不匹配 | 插了 N 个模块就把 N 改成对应值 |
| 锁屏整个消失了 | QML 属性名大写 / 加载失败 | `journalctl --user \| grep "plugin load failed"` |

### 降级行为验证（很重要）

改完 PAM 之后必须确认「人脸坏掉时不会把人锁在门外」：

```bash
# 摄像头消失
sudo howdy set device_path /dev/video99
pamtester -v omarchy-lock-face murgo authenticate </dev/null
# → Configured camera device does not exist: /dev/video99
# → pamtester: Permission denied           ← 立即返回，不阻塞

# howdy 被禁用
sudo howdy set disabled true
pamtester -v omarchy-lock-face murgo authenticate </dev/null
# → pamtester: Permission denied           ← 立即返回
```

**关键：两种情况都是立刻返回拒绝，不是卡住等超时。** 锁屏的密码框、SDDM 的密码框、
`sudo` 的密码提示都照常可用。

---

## 11. 维护清单

```bash
# 1. IR 节点是哪个，以及 howdy 是否指对了（这才是重启后的第一嫌疑）
for d in /sys/class/video4linux/video*; do
  [[ $(cat $d/name) == *"IR Camera"* && $(cat $d/index) == 0 ]] && echo "IR capture: /dev/$(basename $d)"
done
sudo sed -n 's/^device_path = //p' /etc/howdy/config.ini
systemctl is-enabled u9311-ir-camera-pin.service

# 2. howdy 还能跑吗（最可靠的单一检查，看退出码）
sudo /usr/lib/howdy/howdy-compare murgo; echo "exit=$?"

# 3. 模型还在吗
sudo howdy list

# 4. 四处 PAM 都挂上了吗
grep -l pam_howdy /etc/pam.d/{sudo,polkit-1,sddm,omarchy-lock-face}

# 5. 锁屏插件加载正常吗
journalctl --user --since "5 min ago" | grep -i "plugin load failed"
```

### 升级 / 重装后需要重做的事

| 场景 | 要做什么 |
|---|---|
| `howdy-next` 升级 | 一般不用管；`/etc/howdy/config.ini` 会被保留 |
| **内核升级** | 不用管（howdy 是用户态，和 ACPI 那个修复不同） |
| `omarchy` 升级 | 检查 `~/.config/omarchy/plugins/murgo.lock/` 是否被覆盖 |
| 重装系统 | 重跑本流程；注意 `config.ini` 的 `device_path` 要重新确认 |

> 指纹那篇里有「内核升级必须重建 UKI」的坑，**人脸这边没有**——howdy 完全在用户态，
> 不碰 initramfs、不碰 ACPI。

---

## 12. 回滚

| 范围 | 怎么退 |
|---|---|
| 只退 polkit（1Password） | 从 `/etc/pam.d/polkit-1` 删掉 `pam_howdy.so` 那行 |
| 只退 sudo | 同上，改 `/etc/pam.d/sudo` |
| 退锁屏 | 删 `omarchy-lock-face` 里的 howdy 行，或整个文件 |
| 全部退 | 恢复备份：`/etc/pam.d/{sudo,polkit-1,sddm}.bak.*` |
| 彻底卸载 | `sudo pacman -Rns howdy-next` + 恢复 PAM 备份 |

本机备份：

```
/etc/pam.d/sudo.bak.20261118223550     # 改成人脸优先之前
/etc/pam.d/sddm.bak.202611122247xx
/etc/pam.d/polkit-1.bak.20261113004837
~/.config/omarchy/plugins/murgo.lock/Service.qml.bak.20261112224622
```

---

## 13. 安全说明

- **IR 不是万能的。** 它防照片和屏幕，但防不住高仿真的 3D 面具或专门的 IR 发光道具。
  真要严防，得用带结构光/ToF 的方案（消费级笔记本里极少见）。
- **永远保留密码。** 本仓库所有 PAM 配置都是 `sufficient`，不是在替代密码，是在加一条路。
- `abort_if_ssh` 只是便利功能：它靠 `SSH_CONNECTION` 等环境变量判断，
  用户能自己 unset 掉。**不要把它当安全边界。**
- `/etc/howdy/config.ini` 和模型目录必须 root 所有、普通用户不可写。
  本例中锁屏走的是 root 的 `polkit-agent-helper`，不存在放宽权限的需求。

---

## References

- Howdy Next（本方案所用实现）: <https://github.com/nathawatc/howdy-next>
- 原版 Howdy: <https://github.com/boltgolt/howdy>
- OpenCV Zoo — YuNet / SFace 模型: <https://github.com/opencv/opencv_zoo>
- ArchWiki — Howdy: <https://wiki.archlinux.org/title/Howdy>
- Linux 内核 — `SIGXCPU` / `RLIMIT_CPU`: `man 2 setrlimit`, `man 7 signal`
- Quickshell `PamContext`: <https://quickshell.org/docs/v0.2.0/types/Quickshell.Services.Pam/PamContext/>
