# NEXT Biometrics NB-2033-U 指纹模块在 Linux 上的完整落地记录

让 **Fujitsu LIFEBOOK U9311** 的指纹模块在 Arch / Omarchy 上从「系统里根本看不到」到
「能解锁 sudo、polkit 和锁屏」的全过程：驱动编译、驱动调优、fprintd、PAM 接入，以及
Omarchy 锁屏在识别失败瞬间黑屏的定时器竞态问题。

以下所有内容都在同一台真机上执行并实测，数据来自真实测试而非估算；失败过的方案也写进去了
——那些才是最贵的经验。

**测试环境：** Fujitsu LIFEBOOK U9311 (i7-1165G7)、Arch Linux、kernel 6.x、
Omarchy 4.x、`fprintd 1.94.5`、`libfprint 1.94.100`。

> 英文完整版：[fingerprint-nb2033u.md](fingerprint-nb2033u.md)

---

## TL;DR

1. 传感器是 USB `298d:2033` —— **NEXT Biometrics NB-2033-U**，*热敏式*按压传感器，
   256×180 px，508 dpi。`libfprint` 1.94.100 和 Arch 上钉住的 `libfprint-git` 都**没有**它的驱动。
2. 驱动只存在于一个**未合并的 merge request**（libfprint MR !574）里。从该分支编译，
   装到 `/usr/local/lib`，并强制 `fprintd` 优先加载它。
3. 加一条 udev 规则，让当前用户能访问设备节点。
4. 上游驱动的匹配质量在这个传感器上很一般（单次按压约 40%）。四处驱动级改动后提升到约
   75%；剩下的差距来自热敏传感器的物理特性，应当提高 PAM `max-tries` 而不是继续死磕。
5. Omarchy 锁屏在锁定后 **5 秒**就熄屏——而这正好落在指纹验证过程中。克隆锁屏插件改定时器，
   然后**必须重启 shell**（只改 QML 不生效）。

---

## 1. 识别硬件

```bash
for d in /sys/bus/usb/devices/*/product; do
  v=$(dirname "$d"); printf '%s: %s [%s:%s]\n' "$v" "$(cat "$d")" \
    "$(cat "$v/idVendor" 2>/dev/null)" "$(cat "$v/idProduct" 2>/dev/null)"
done
```

```
/sys/bus/usb/devices/3-5: NB-2033-U [298d:2033]
```

| 属性 | 值 |
|---|---|
| VID / PID | `298d:2033`，NEXT Biometrics |
| 类型 | 热敏式，按压（非滑动） |
| 图像 | 256 × 180 px，8 位灰度 |
| 分辨率 | 508 dpi → **20 px/mm** |
| 传输 | bulk USB，180 行 × 256 字节 |

原生系统上的症状：`fprintd` 正常启动但报 **“No devices available”**；
`omarchy setup security fingerprint` 说 “No fingerprint sensor detected” —— 因为
`omarchy-hw-fingerprint` 只白名单了几个厂商 ID（`27c6 138a 06cb 08ff 1c7a 147e`）和产品名关键字。

## 2. 为什么开箱即用不行

```bash
strings /usr/lib/libfprint-2.so.2.0.0 | grep -ci nb2033    # → 0
```

两个独立原因：

* **上游没有驱动。** `libfprint` MR !574（“nb2033: Add support for NB-2033-U
  fingerprint reader”，LGPL-2.1+）仍处于 **open** 状态，任何 release 都不含它。
* **Arch/Omarchy 装的是 `libfprint-git`** —— 一个*钉住的快照*（`1:1.94.100.r10`），
  不是 git master。所谓“git 包”也没有这个驱动，而且 `pacman -Syu` 会把你塞进 `/usr/lib` 的东西覆盖掉。

## 3. 从 MR 分支编译驱动

标准 meson 构建；坑全在*宿主机依赖*上。

```bash
git init libfprint && cd libfprint
git remote add origin https://gitlab.freedesktop.org/libfprint/libfprint.git
git fetch --depth 1 origin merge-requests/574/head
git checkout FETCH_HEAD          # 此刻会出现 libfprint/drivers/nb2033.c
```

### 坑 1 —— `glib-mkenums` 不在 `.pc` 文件所说的地方

当前 Arch 把 `glib-mkenums`、`g-ir-scanner` 拆进了 `glib2-devel`，普通桌面安装没有。
meson 只会报一句没用的 *“This is a distributor issue”*。免 root 的解法：

```bash
# 只解压 devel 包，不安装
curl -O https://geo.mirror.pkgbuild.com/core/os/x86_64/glib2-devel-2.90.1-1-x86_64.pkg.tar.zst
tar -xf glib2-devel-2.90.1-1-x86_64.pkg.tar.zst -C ./glib-devel

# glib-2.0.pc 里硬编码了 /usr/bin/glib-mkenums —— 用补丁版盖过去
mkdir -p pc
sed "s|^glib_mkenums=.*|glib_mkenums=$PWD/glib-devel/usr/bin/glib-mkenums|" \
    /usr/lib/pkgconfig/glib-2.0.pc > pc/glib-2.0.pc
```

```bash
export PKG_CONFIG_PATH=$PWD/pc:/usr/lib/pkgconfig:/usr/share/pkgconfig
export PATH=$PWD/glib-devel/usr/bin:$PATH
```

### 坑 2 —— meson 1.12 不接受对 dict 用单变量 `foreach`

`tests/meson.build` 用单个循环变量遍历 dict `drivers_tests`，新版 meson 直接报错
（仅在关闭 introspection 时才会走到这里）：

```diff
-    foreach driver_test: drivers_tests
-        test(driver_test,
+    foreach _k, driver_test: drivers_tests
+        test(_k,
```

### 配置与编译

```bash
meson setup build -Ddoc=false -Dintrospection=false   # introspection 需要 g-ir-scanner
ninja -C build
```

关掉 introspection 没有副作用：只有 Python 绑定需要它，`fprintd` 不需要。

### 装之前先验证

```bash
build/examples/enroll          # 应打印: claimed by nb2033 driver
```

驱动能 claim 到设备，剩下的都只是管线连接问题。

## 4. 让设备节点可用

```bash
# /etc/udev/rules.d/60-nb2033.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="298d", ATTRS{idProduct}=="2033", MODE="0666", TAG+="uaccess"
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/bus/usb/003/003    # → crw-rw-rw-+
```

没有这条规则会得到 `libusb couldn't open USB device … errno=13`，看起来像驱动 bug，其实是权限问题。

## 5. 安装方式要让包升级打不坏

`pacman` 拥有 `/usr/lib/libfprint-2.so.2.0.0`，每次 `libfprint-git` 升级都会还原掉你的驱动。
只装到 `/usr/local/lib` 也不行——Arch 的动态链接器搜索路径里**没有** `/usr/local/lib`。

可靠的组合是两者都做：`/usr/lib` 放一份副本（让 `fprintd` 立刻能链接到），**同时**用
systemd drop-in 把 `fprintd` 钉到 `/usr/local/lib`，后者才能扛住升级。

```bash
sudo cp build/libfprint/libfprint-2.so.2.0.0 /usr/local/lib/
sudo cp build/libfprint/libfprint-2.so.2.0.0 /usr/lib/
sudo ldconfig

sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=LD_LIBRARY_PATH=/usr/local/lib\n' |
  sudo tee /etc/systemd/system/fprintd.service.d/20-nb2033-lib.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
```

确认**运行中的守护进程**真的加载了你的构建（磁盘上的文件不算数）：

```bash
sudo grep -o '/[^ ]*libfprint[^ ]*' /proc/$(pgrep -x fprintd)/maps | sort -u
# → /usr/local/lib/libfprint-2.so.2.0.0
```

```bash
fprintd-list "$USER"
# → Fingerprints for user … on NextBiometrics NB-2033-U (press):
```

> **坑：** 一旦用 `sudo` 跑过 `meson`，构建目录会变成 root 所有，下次 `ninja` 直接
> exit code 13。`sudo chown -R you: build/` 修一下。

## 6. 驱动调优——真正起作用的是哪几处

MR 自带驱动把原始帧直接交给 bozorth3。在这个热敏传感器上，实测**5 次按压只有 2 次**能通过。
五处改动，按影响排序：

| # | 改动 | 原因 |
|---|---|---|
| 1 | `img->ppmm = 20.0` | 驱动从未设置该值，NBIS 细节点提取以**尺度 0** 运行。脊线间距相关参数全部依赖它，这一条是“偶尔成功”与“通常成功”的分水岭。 |
| 2 | 逐行均值去除 + 局部对比度归一化 | 传感器输出带有很强的横向条纹和缓慢亮度梯度，见 §6.1——模糊半径才是关键。 |
| 3 | 检测到手指后停留 `NB2033_CAPTURE_DWELL` = 600 ms | 热敏图像的对比度在接触后仍在建立；在检测电平刚过阈值时立刻采集，得到的是发白的废图。 |
| 4 | 质量门控：方差 < 90 的帧丢弃重采（≤3 次） | 把空图交给匹配器比等待更糟：它消耗掉一次用户看不见的尝试机会。 |
| 5 | `bz3_threshold` 40 → 22 | MR 选了一个很严的阈值。实测 22 最好；18 无进一步提升且放大误识风险。 |

另外把 `NB2033_SETTLE_DELAY` 从 1500 ms 提到 2500 ms：打开设备后的第一次采集否则不可靠。

单次按压验证成功率实测（同一手指、同一会话）：

| 构建 | 结果 |
|---|---|
| MR 原版驱动 | ~2/5 |
| + `ppmm`、预处理、dwell、门控、阈值 22 | **6/8** |
| 阈值 18 | 5/8（无收益 → 回退） |
| 改用梯度做质量门控 | 2/6，其中三次直接超时（回退） |

剩余失败来自物理层面：接触面积、手指干湿，以及热敏传感器在手指静止后对比度会衰减。

### 6.1 模糊半径这个坑（值得单列）

归一化做的是「减去图像的模糊副本」：

```c
/* Radius must span several ridge periods (~10 px each at 20 px/mm);
 * a window near one period erases the ridges it is meant to keep. */
const int radius = 40;
```

第一版用了 `radius = 8`。20 px/mm 下脊线周期约 10 px，17 px 的窗口正好**跨着脊线做平均**
——所谓“增强”把指纹低通成了一片灰糊，匹配质量反而更差。背景估计窗口必须比要保留的特征
大一个数量级（数个脊线周期，这里 40 px ≈ 2 mm）。

条纹去除和背景相减都基于**积分图**，整张 256×180 的处理只需微秒级：

```c
data[y][x] = clamp(128 + (data[y][x] - local_box_mean) * gain);
```

## 7. 接入 PAM（走 Omarchy 自己的向导）

Omarchy 自带 `omarchy setup security fingerprint`：装 `fprintd`、写好 PAM 栈，并加一个
合盖门控（`pam_exec … omarchy-hw-laptop-closed`），合盖时跳过读卡器而不是卡住等待。
用它就对了——但它会因 `omarchy-hw-fingerprint` 的厂商白名单而拒绝运行。

该检查支持环境变量覆盖，所以一个临时目录就能绕过，无需改动任何系统文件：

```bash
mkdir -p /tmp/fpdev/nb2033
echo "Fingerprint Reader" > /tmp/fpdev/nb2033/product
OMARCHY_USB_DEVICES_PATH=/tmp/fpdev omarchy-setup-security-fingerprint
```

它会写入：

| 路径 | 内容 |
|---|---|
| `/etc/pam.d/sudo`、`/etc/pam.d/polkit-1` | `auth sufficient pam_fprintd.so` + 合盖门控 |
| `/etc/pam.d/omarchy-lock-fingerprint` | `auth required pam_fprintd.so` |
| `/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf` | 停止超时上限 |
| `~/.config/omarchy/hooks/post-update.d/setup-fingerprint.hook` | 更新后自动重放 |

**千万不要用 `omarchy remove security fingerprint` 去“临时停用”** —— 它会删掉 PAM 文件
*和*已录入的模板。想停用，注释掉 `pam_fprintd.so` 那几行即可。

## 8. 针对热敏传感器的 PAM 调优

`pam_fprintd` 默认每次验证允许 3 次按压，而 Omarchy 锁屏在两次尝试之间还会退避——体验上就是
“按一下、等一下、再按一下”。既然单次按压通过率约 75%，正确的杠杆是增加**一次验证内**的按压次数：

```pam
# /etc/pam.d/omarchy-lock-fingerprint
auth       required   pam_fprintd.so max-tries=6 timeout=30
```

p ≈ 0.75 时，6 次全失败的概率仅 0.25⁶ ≈ 0.02%。注意向导会把这个文件重置为默认值，
每次重跑后都要补回这一行。

## 9. 锁屏在你手指还没离开时就熄屏

症状：锁屏后按指纹，识别失败——面板立刻黑掉，要按一下键盘才回来。看起来像崩溃，其实是定时器竞态。

根因在 Omarchy 的会话锁服务（`omarchy.lock`，Quickshell）：

```qml
Timer {
  id: idleBlankTimer
  interval: 5000            // ← 锁定或唤醒后 5 秒熄屏
  onTriggered: {
    ...
    if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
  }
}
```

它只拦**密码**验证，不拦指纹验证。而一次指纹验证（claim → detect → dwell → capture → match）
经常超过 5 秒，于是面板在验证过程中被关掉。`runBlank()` 还会 `pauseFingerprint()` 暂停读卡器，
这就是为什么之后必须按键盘才有反应。

改法：克隆插件，绝不直接改 `/usr/share/omarchy`：

```bash
omarchy plugin clone omarchy.lock      # → ~/.config/omarchy/plugins/<user>.lock
```

```qml
Timer {
  id: idleBlankTimer
  interval: 30000          // 原 5000：失败的验证会和这个倒计时抢时间
  onTriggered: {
    if (Date.now() - armedAt > interval + 2000) { root.armBlankTimer(); return }
    if (root.lockRequested && root.fingerprintAuthenticating) {
      root.armBlankTimer(); return          // 验证中绝不熄屏；仅重排倒计时
    }
    if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
  }
}
```

> **坑（浪费了一小时）：** 锁屏服务是 `keepLoaded` 的。保存 QML（或执行
> `omarchy-shell shell rescanPlugins`）**不会**替换已经加载的实例——旧的 5 秒定时器继续跑，
> 看起来像“改了没生效”。必须 `omarchy restart shell`。

顺手加日志，因为“屏幕黑了”可能有多个嫌疑人（锁屏定时器、`hypridle` 的 DPMS 监听、亮度 shim）：

```qml
function runBlank() { logEvent("blank"); /* … */ }
```

```bash
grep "omarchy lock" "$(ls -td /run/user/$UID/quickshell/by-id/*/ | head -1)/log.log"
```

`blank` 行带时间戳；如果屏幕变黑却没有 `blank` 行，凶手在锁屏插件之外（去查 `hypridle` 的 `dpms` 监听）。

## 10. 误删之后的恢复

`omarchy remove security fingerprint` 会删掉 `fprintd`、PAM 文件与模板——但**不会**动
`/usr/local/lib` 和 `~/.config/omarchy/plugins`。所以重建只需：

```bash
sudo pacman -S --noconfirm libfprint-git fprintd
sudo cp /usr/local/lib/libfprint-2.so.2.0.0 /usr/lib/ && sudo ldconfig
sudo systemctl restart fprintd

mkdir -p /tmp/fpdev/nb2033 && echo "Fingerprint Reader" > /tmp/fpdev/nb2033/product
OMARCHY_USB_DEVICES_PATH=/tmp/fpdev omarchy-setup-security-fingerprint
# 然后补回 §8 的 PAM max-tries 调优
```

## 11. 维护清单

每次系统更新后：

```bash
# 1. 运行中的守护进程是否仍用我们的库？
sudo grep -o '/[^ ]*libfprint[^ ]*' /proc/$(pgrep -x fprintd)/maps | sort -u
# 2. 驱动是否仍认识设备？
fprintd-list "$USER"
# 3. 锁屏克隆插件是否仍启用？
grep -A2 disabledPlugins ~/.config/omarchy/shell.json
```

若某天 `libfprint` 上游真的合入了 nb2033，就撤掉 drop-in 和这两份副本——那时用发行版驱动才是对的。

## 12. 本仓库中的相关文件

| 路径 | 用途 |
|---|---|
| `patches/nb2033-u9311-tuning.patch` | §6 的四处驱动改动，相对 MR !574 的 diff |
| `scripts/u9311-fingerprint-setup.sh` | 编译 + 部署 + PAM 配置，一条龙 |

## 参考

* libfprint MR !574 —— `nb2033: Add support for NB-2033-U fingerprint reader`
  (<https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/574>)
* 该传感器的逆向记录：*NEXT Biometrics NB-2033-U: Reverse Engineering eines
  Fingerabdrucklesers für Linux*
  (<https://www.kernel-error.de/2026/03/17/next-biometrics-nb-2033-u-reverse-engineering-fingerabdruckleser-linux>)
* libfprint API：`FpImageDevice`、`bz3_threshold`、`img->ppmm`
* Omarchy 插件模型：`omarchy plugin clone`、`~/.config/omarchy/plugins/`
