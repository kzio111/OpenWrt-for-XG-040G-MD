#!/bin/bash

# 1. 拉取 TurboAcc (不含 SFE)
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh --no-sfe

# 2. 拉取 Airoha NPU 状态显示插件
git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu

# 3. 强制开启 devmem 相关的所有开关 (解决你截图中的 [=n] 问题)
sed -i 's/# CONFIG_BUSYBOX_CONFIG_DEVMEM is not set/CONFIG_BUSYBOX_CONFIG_DEVMEM=y/g' .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
echo "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y" >> .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 4. 确保新插件被选中编译 (可选)
echo "CONFIG_PACKAGE_luci-app-turboacc=y" >> .config
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config
