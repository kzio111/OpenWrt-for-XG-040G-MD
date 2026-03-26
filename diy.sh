#!/bin/bash

# 1. 修复 Kconfig 循环依赖 (防止进入菜单报错)
rm -rf feeds/packages/utils/fwupd

# 2. 拉取 TurboAcc 和 NPU 插件
[ ! -d "package/turboacc-libs" ] && git clone https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
fi
[ ! -d "package/luci-app-airoha-npu" ] && git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu

# 3. 【核心修复】强制修改 Busybox 默认值源文件
# 这一步是为了让 BUSYBOX_DEFAULT_DEVMEM 从源码级别就变成 y
# 从而满足 NPU 插件的依赖检查
if [ -f package/utils/busybox/Config-defaults.in ]; then
    sed -i 's/default n/default y/g' package/utils/busybox/Config-defaults.in
fi

# 4. 在 .config 中强行写入，确保三项全开
echo "CONFIG_BUSYBOX_CUSTOM=y" >> .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
echo "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y" >> .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 5. 显式选中插件
echo "CONFIG_PACKAGE_luci-app-turboacc=y" >> .config
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config

echo "✅ 依赖已强制修正，NPU 插件现在应该可见了。"
