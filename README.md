# Fix-touchpad

修复 HTIX5288 (0911:5288) 触摸板在 Linux 下双指快速滑动后抬指的"幽灵双指"bug。

## 问题

双指快速滑动滚动条 → 抬掉一根手指 → 剩余手指仍被识别为两指，指针/滚动冻结在抬指位置。

## 根因

hid-multitouch 内核驱动将 HTIX5288 错配为 `MT_CLS_NSMU`（仅带 `NOT_SEEN_MEANS_UP`），缺少 Win8 精准触摸板应有的 `MT_QUIRK_CONTACT_CNT_ACCURATE` 和 `MT_QUIRK_IGNORE_DUPLICATES`，导致抬指后的陈旧坐标污染剩余手指的 slot。

## 修复

一行改动：`MT_CLS_NSMU` → `MT_CLS_WIN_8_FORCE_MULTI_INPUT_NSMU`（0x000a → 0x0018）。详见 [FIX.md](FIX.md)。

2024 年 12 月的内核提交 [b5e65ae](https://github.com/torvalds/linux/commit/b5e65ae557da) 首次修复了同设备"抬指信号丢失"（NSMU），但遗漏了 `CONTACT_CNT_ACCURATE` 导致幽灵坐标污染。此补丁在其基础上补全。

## 受影响硬件

Chuwi Minibook, GPD Win Mini, T-bao Tbook Air, Cube Thinker, EZBook 3 Pro, Polaroid 1400, Mediacom FlexBook, 部分 Huawei 设备等。

## 安装

```bash
sudo ./install-patched-module.sh
```

或手动编译：

```bash
cd mt-fix
make -C /lib/modules/$(uname -r)/build M=$PWD modules
zstd -f -T0 -o hid-multitouch.ko.zst hid-multitouch.ko
sudo cp hid-multitouch.ko.zst /lib/modules/$(uname -r)/kernel/drivers/hid/
sudo depmod
sudo modprobe -r hid_multitouch && sudo modprobe hid_multitouch
```

## 恢复

```bash
sudo cp /lib/modules/$(uname -r)/kernel/drivers/hid/hid-multitouch.ko.zst{.backup,}
sudo depmod
sudo modprobe -r hid_multitouch && sudo modprobe hid_multitouch
```

## 环境

- Arch Linux, 内核 7.1.3-arch1-2
- KDE Plasma / Wayland
- HTIX5288:00 0911:5288 Touchpad (I2C HID, Goodix/Hantick)
