#!/bin/bash
# 安装打过补丁的 hid-multitouch.ko 驱动
# fix: HTIX5288 (0911:5288) 从 MT_CLS_NSMU -> MT_CLS_WIN_8
# 解决双指滚动后抬指幽灵坐标 bug
set -e

PATCHED_KOZST="$(dirname "$0")/mt-fix/hid-multitouch.ko.zst"
MODULE_PATH="/lib/modules/$(uname -r)/kernel/drivers/hid/hid-multitouch.ko.zst"
DEVICE="0018:0911:5288.0008"

if [ "$EUID" -ne 0 ]; then
    echo "请用 sudo 运行此脚本"
    exit 1
fi

if [ ! -f "$PATCHED_KOZST" ]; then
    echo "错误: 找不到补丁模块 $PATCHED_KOZST"
    exit 1
fi

echo "=== 1. 备份原始模块 ==="
cp "$MODULE_PATH" "${MODULE_PATH}.backup"
echo "  备份到 ${MODULE_PATH}.backup"

echo "=== 2. 安装补丁模块 ==="
cp "$PATCHED_KOZST" "$MODULE_PATH"

echo "=== 3. 更新模块依赖数据库 ==="
depmod

echo ""
echo "=== 4. 在线重加载模块 (免重启) ==="

echo "  解绑设备 $DEVICE ..."
echo "$DEVICE" > /sys/bus/hid/drivers/hid-multitouch/unbind 2>/dev/null || echo "  (设备可能已被解绑或正在使用)"

echo "  卸载旧模块..."
modprobe -r hid_multitouch 2>/dev/null || true

echo "  加载新模块..."
modprobe hid_multitouch || { echo "加载失败！正在恢复备份..."; cp "${MODULE_PATH}.backup" "$MODULE_PATH"; depmod; modprobe hid_multitouch; echo "已恢复原始模块。"; exit 1; }

echo "  重新绑定设备 $DEVICE ..."
echo "$DEVICE" > /sys/bus/hid/drivers/hid-multitouch/bind 2>/dev/null || echo "  (自动绑定中...)"

echo ""
echo "==========================================="
echo "安装完成! 请立即测试触摸板双指滚动后抬指。"
echo ""
echo "验证补丁生效:"
echo "  dmesg | grep 'HID multitouch'  # 新模块应有新 srcversion"
echo ""
echo "如有问题，恢复原始模块:"
echo "  sudo cp ${MODULE_PATH}.backup $MODULE_PATH"
echo "  sudo depmod"
echo "  sudo modprobe -r hid_multitouch && sudo modprobe hid_multitouch"
echo ""
echo "或直接重启即可用新驱动。"
echo "==========================================="
