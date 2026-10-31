# Fujitsu LIFEBOOK U9311 合盖唤醒内屏黑屏 —— 修复方案

> English version: [README.md](README.md) · 详细技术分析: [docs/technical-analysis.md](docs/technical-analysis.md)

合盖挂起后开盖，**内屏背光全亮但没有画面**，系统其实还活着（SSH 能连、截图能拿到正常桌面）。
重启才能恢复。

**根因：BIOS 的 ACPI 表 `IgfxSsdt` 强行关断 eDP 面板的 VDD 电源，导致 i915 的
Panel Power Sequencing 状态错乱。** 挂起/恢复时表现为 wakeref 泄漏 + eDP 链路训练失败。

**修法**：对 `IgfxSsdt` 打 ACPI 补丁 —— OEM Revision 提到 `0x00003001`，删除两处
`If ((VDDE == One)) { VDDE = Zero; Sleep (0x01F4) }`，通过 initramfs 的 ACPI override 生效。

---

## 适用判断

复现黑屏后（系统仍能 SSH）：

```bash
sudo journalctl -b -k | grep -E "Failed to enable link training|raw-wakerefs|vdd_wakeref"
```

三条**同时出现**基本就是这个 bug：

```
i915 ... i915 raw-wakerefs=1 wakelocks=1 on cleanup
WARNING: ... intel_runtime_pm_driver_release ... i915_pm_suspend_late
i915 ... *ERROR* [...eDP-1][...DDI A/PHY A][DPRX] Failed to enable link training
```

再确认表存在：

```bash
sudo sh -c 'for f in /sys/firmware/acpi/tables/SSDT*; do
  grep -a -q "IgfxSsdt" "$f" && echo "$f"; done'
```

**已知机型**：U9311（Tiger Lake，Sharp LQ133M1JW42 面板）。U9312 / E5411 在 ArchWiki 上有同款补丁。

> 注意：如果 `hyprctl monitors` 显示 `dpmsStatus: 0`，那是另一个更简单的问题
> （合成器没把 DPMS 打开），不是本文说的这个。

## 快速步骤

1. **找到并核对表**：必须唯一命中一个 `SSDT*`，OEM Table ID 为 `IgfxSsdt`，
   OEM Revision 为 `0x00003000`，且两处目标代码块都在 `If ((PDRD () == Zero))` 内。
   **结构不匹配就停手** —— 这个补丁是表结构专属的，不能按机型照搬。
2. **打补丁**：改 revision → `0x00003001`；删两处 VDDE 块；`iasl -sa` 必须 0 错误。
3. **放进 initramfs**：
   - 标准 Arch：把 AML 放到 `/etc/initcpio/acpi_override/`，HOOKS 里加 `acpi_override`（在 `kms` 之前），`mkinitcpio -P`
   - 自定义 UKI（如 Limine + ukify）：不必重建 initramfs，用 [scripts/u9311-rebuild-uki.sh](scripts/u9311-rebuild-uki.sh)
     在现有 initrd 里插一条 AML 即可
4. **验证真的加载了**：

```bash
sudo journalctl -b -k | grep -iE "Table Upgrade|IgfxSsdt"
# 必须出现：ACPI: Table Upgrade: override [SSDT-INTEL -IgfxSsdt]
```

**AML 打进包里 ≠ 覆盖生效**，只认 `Table Upgrade: override` 这一行。

## 别浪费时间的方向（都实测过，全部无效）

| 尝试 | 结论 |
|---|---|
| `i915.enable_psr=0` / `enable_dc=0` / `enable_fbc=0` / `enable_guc=0` | 根因在 ACPI，不在驱动省电策略 |
| 换内核（linux / lts / zen） | 补丁在固件表里，不在内核里 |
| `mem_sleep=deep`（S3） | s2idle 和 S3 都一样失败 |
| debugfs `i915_dp_force_link_retrain` | 电源状态已乱，强制重训无用 |
| 强制降低链路速率/lane | 同样失败 |
| 用户态 eDP `disable → enable` | **偶尔有效**，正是这个 bug 最坑的地方 |
| `hibernate`（S4） | **确实有效**（从磁盘镜像恢复，i915 完全重新初始化），但唤醒要 2 分钟 |
| 只改 ACPI revision 不改逻辑 | 能启动，但挂起照样黑（这是关键的对照组） |

## 三个必踩的坑

1. **early CPIO 约 20 MB，不是 114 KB**。某些固件文件本身就是 `.zst`，所以在 114 KB 处
   也能搜到 zstd 魔数。按它切分会把 initrd 切坏，直接
   `Kernel panic: Unable to mount root fs on unknown-block(0,0)`。
   必须按 CPIO 结构逐条目解析到 `TRAILER!!!`。
2. **`objcopy --update-section` 会静默截断**。不调整 section 大小，只覆盖等长前缀，
   多的部分丢掉，**还返回 0**。实测写入 37,274,483 字节，只保留 37,261,443 字节。
   要用 `ukify build`，封装后必须提取回来 `cmp` 比对。
3. **mkinitcpio 复刻不出发行版的 UKI**。默认 27 MB、`-S autodetect` 230 MB、
   生产 37 MB，都不匹配。别试图重建，直接在现有 initrd 上最小修改。

## 内核更新后

- 用 mkinitcpio hook 方案：自动跟随，不用管
- 用独立 UKI 方案：每次内核更新后跑一次 `sudo u9311-rebuild-uki.sh`

## 回滚

同内核版本下，**未打补丁的原版 UKI 就是完整的回滚入口**（两者 `.linux` 段逐字节相同，
只差 initrd 里一条 AML），不需要额外装一个旧内核。

> 跨内核版本启动旧 UKI 不算回滚保障 —— 旧内核的模块目录可能已被包管理器清掉。

## 免责声明

ACPI 表覆盖写错可能导致无法开机。**必须先从自己机器 dump 表、核对结构、再编译**，
不要直接用别人仓库里的 AML 二进制。建议先做一版"只改 revision 不改逻辑"的对照测试，
确认你的部署链路能正常启动，再上正式补丁。

## 许可

MIT
