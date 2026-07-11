# HTIX5288 触摸板幽灵双指修复

## 问题

Linux (Wayland + KDE, Arch, 内核 7.1.3) 下，双指快速滑动滚动条后抬掉一根手指，剩余手指仍被识别为"两指"→ 指针冻结在抬指位置。Windows 下无此问题。

**触摸板**: `HTIX5288:00 0911:5288 Touchpad` (Goodix/Hantick, I2C HID)

## 诊断过程

### 1. 确认驱动栈

```
设备: HTIX5288 (0911:5288), I2C HID v1.00
协议: Win8 Precision Touchpad (type-B multitouch, 5 slots)
驱动: hid-multitouch (内核模块)
输入框架: libinput 1.31.3 (via KWin/Wayland)
```

### 2. 抓取内核原始事件

```bash
sudo evtest /dev/input/event15 > tp.log
# 复现: 双指快速滑动 → 抬掉一根指头 → 移动剩余手指
```

### 3. 数据分析

**正常两指帧** (抬指前):

```
SLOT=0, POSITION_X=900, POSITION_Y=202   # 手指1
SLOT=1, POSITION_X=779, POSITION_Y=427   # 手指2
SYN_REPORT
```

**抬指帧** (1625行): slot 0 释放

```
SLOT=0, TRACKING_ID=-1
BTN_TOOL_FINGER=1, BTN_TOOL_DOUBLETAP=0   # 正确: 降为单指
SYN_REPORT
```

**抬指后的帧** ← 问题出现:

```
POSITION_X=955, POSITION_Y=147    # slot 1 真实坐标 (移动中)
POSITION_X=932, POSITION_Y=185    # 幽灵! slot 0 冻结坐标, 无 SLOT 前缀
SYN_REPORT
```

**关键发现**: 7 帧中 7 帧都含幽灵坐标。因为 `ABS_MT_SLOT` 只发了一次(粘在 slot 1)，两组 `POSITION_X/Y` 都写入 slot 1 → 最后一个值 (932,185 = 幽灵) 胜出 → 剩余手指被"冻结"在抬指位置。

内核正确释放了 tracking_id 和 BTN_TOOL，幽灵坐标来自 hid-multitouch 驱动层。

### 4. 定位根因

hid-multitouch 源码 (v7.1.3, 第 2566-2574 行):

```c
/* Hantick */
{ .driver_data = MT_CLS_NSMU,    // ← 错误!
    HID_DEVICE(BUS_I2C, HID_GROUP_MULTITOUCH_WIN_8,
               I2C_VENDOR_ID_HANTICK, I2C_PRODUCT_ID_HANTICK_5288) },
```

`MT_CLS_NSMU` 仅包含 `MT_QUIRK_NOT_SEEN_MEANS_UP`。

而该设备声明为 Win8 精准触摸板 (`HID_GROUP_MULTITOUCH_WIN_8`)，正确分类应为 `MT_CLS_WIN_8`，它额外包含:

- `MT_QUIRK_CONTACT_CNT_ACCURATE` — 信任报告头中的接触计数，`num_received >= num_expected` 时**停止处理后续接触**。抬指后报告头声明"1 个接触"时，驱动不会处理残留在报告体中的已释放接触的陈旧坐标。
- `MT_QUIRK_IGNORE_DUPLICATES` — 同一帧内相同 slot 已使用时**跳过重复**。

NSMU 缺少这两个 quirk → 驱动完整处理了固件报告体中的陈旧接触数据 → 幽灵坐标污染剩余手指 slot。

### 5. 原始补丁 (不完整)

2024 年 12 月提交 [b5e65ae557da](https://github.com/torvalds/linux/commit/b5e65ae557da9fd17b08482ee44ee108ba636182) 首次将 HTIX5288 加入 hid-multitouch 设备表：

> "This device sometimes doesn't send touch release signals when moving from >=2 fingers to <2 fingers. Using MT_QUIRK_NOT_SEEN_MEANS_UP instead of MT_QUIRK_ALWAYS_VALID makes sure that no touches become stuck."

作者用 `MT_CLS_NSMU`（仅 `NOT_SEEN_MEANS_UP`）解决了**抬指信号丢失**的问题。但未补上 `CONTACT_CNT_ACCURATE` 和 `IGNORE_DUPLICATES`，导致**抬指后陈旧坐标污染**——即本文档描述的幽灵双指 bug。

### 6. 受影响硬件

基于 GitHub issue 和内核提交的交叉搜索，以下设备确认使用 HTIX5288 (0911:5288)：

| 设备 | 来源 |
|------|------|
| Chuwi Minibook | fstanis/chuwi-minibook |
| GPD Win Mini | ShadowBlip/InputPlumber |
| T-bao Tbook Air | i2c-hid quirk 提交 |
| Cube Thinker | i2c-hid quirk 提交 |
| EZBook 3 Pro | i2c-hid quirk 提交 |
| Polaroid 1400 | sebanc/brunch |
| Mediacom FlexBook edge13 | sebanc/brunch |
| Huawei (未知型号) | arnoldthebat/chromiumos |
| Void Linux 用户 (未知硬件) | void-linux/void-packages |

此外 VoodooI2C (macOS Hackintosh) 为 0911:5288 维护了多个专用 workaround（睡眠唤醒复位跳过、CPU 负载问题等）。

## 修复

### 补丁 (一行)

```diff
--- a/drivers/hid/hid-multitouch.c
+++ b/drivers/hid/hid-multitouch.c
@@ -2570,7 +2570,7 @@ static const struct hid_device_id mt_devices[] = {
    /* Hantick */
-   { .driver_data = MT_CLS_NSMU,
+   { .driver_data = MT_CLS_WIN_8_FORCE_MULTI_INPUT_NSMU,
         HID_DEVICE(BUS_I2C, HID_GROUP_MULTITOUCH_WIN_8,
                    I2C_VENDOR_ID_HANTICK, I2C_PRODUCT_ID_HANTICK_5288) },
```

**为什么不是 MT_CLS_WIN_8？**
- `MT_CLS_WIN_8` 使用 `MT_QUIRK_ALWAYS_VALID`，会重新引入原始补丁修复的"抬指信号丢失"问题
- `MT_CLS_WIN_8_FORCE_MULTI_INPUT_NSMU` 同时保留 `NOT_SEEN_MEANS_UP`（处理抬指丢失）并添加 `CONTACT_CNT_ACCURATE` + `IGNORE_DUPLICATES`（处理陈旧坐标污染）

### 构建

```bash
# 下载源码
curl -o hid-multitouch.c "https://git.kernel.org/.../hid-multitouch.c?h=v7.1.3"
curl -o hid-ids.h       "https://git.kernel.org/.../hid-ids.h?h=v7.1.3"
curl -o hid-haptic.h    "https://git.kernel.org/.../hid-haptic.h?h=v7.1.3"

# 打补丁
sed -i '/Hantick/,/HANTICK_5288/s/MT_CLS_NSMU/MT_CLS_WIN_8/' hid-multitouch.c

# 编译 (需 linux-headers)
echo 'obj-m := hid-multitouch.o' > Kbuild
make -C /lib/modules/$(uname -r)/build M=$PWD modules
zstd -f -19 -T0 -o hid-multitouch.ko.zst hid-multitouch.ko
```

### 安装

```bash
sudo ~/CODE/workspace/Fix-touchpad/install-patched-module.sh
```

或手动:

```bash
sudo cp /lib/modules/$(uname -r)/kernel/drivers/hid/hid-multitouch.ko.zst{,.backup}
sudo cp hid-multitouch.ko.zst /lib/modules/$(uname -r)/kernel/drivers/hid/
sudo depmod
# 在线重加载 (或重启)
echo 0018:0911:5288.0008 | sudo tee /sys/bus/hid/drivers/hid-multitouch/unbind
sudo modprobe -r hid_multitouch
sudo modprobe hid_multitouch
echo 0018:0911:5288.0008 | sudo tee /sys/bus/hid/drivers/hid-multitouch/bind
```

### 恢复

```bash
sudo cp /lib/modules/$(uname -r)/kernel/drivers/hid/hid-multitouch.ko.zst{.backup,}
sudo depmod
sudo modprobe -r hid_multitouch && sudo modprobe hid_multitouch
```

## 文件结构

```
Fix-touchpad/
├── FIX.md                          # 本文档
├── install-patched-module.sh       # 安装脚本 (sudo)
└── mt-fix/
    ├── hid-multitouch.c            # 补丁后源码
    ├── hid-ids.h                   # 依赖头文件
    ├── hid-haptic.h                # 依赖头文件
    ├── Kbuild                      # 树外编译配置
    └── hid-multitouch.ko.zst       # 编译好的模块
```

## 上游

此修复适配于向 [linux-input@vger.kernel.org](mailto:linux-input@vger.kernel.org) 提交补丁。HTIX5288 出现在多款 Honor/Huawei/Medion 笔记本中，可能有大量用户受影响。

## 日期

2026-07-11
