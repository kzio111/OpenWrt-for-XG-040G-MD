#!/bin/bash

# 1. 修复 Kconfig 循环依赖 (解决 fwupd 导致的编译中断)
rm -rf feeds/packages/utils/fwupd

# 2. 拉取 TurboAcc 及其依赖驱动 (解决 kmod 驱动缺失警告)
# 先拉取驱动库，再通过脚本添加 TurboAcc 插件
[ ! -d "package/turboacc-libs" ] && git clone https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
fi

# 3. 拉取并修复 NPU 插件
if [ ! -d "package/luci-app-airoha-npu" ]; then
    git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
fi

# 【核心修复】修正 NPU Makefile 的路径错误 (ERROR: please fix...)
if [ -f package/luci-app-airoha-npu/Makefile ]; then
    sed -i 's/\.\.\/\.\.\/luci\.mk/$(TOPDIR)\/feeds\/luci\/luci.mk/g' package/luci-app-airoha-npu/Makefile
fi

# 4. 强制开启内核与 Busybox 依赖 (解决 devmem 选项显示 n 的问题)
# 这一步能确保 NPU 插件能正常读取硬件数据
echo "CONFIG_BUSYBOX_CUSTOM=y" >> .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
echo "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y" >> .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 5. 自动选中插件 (省去在 menuconfig 里手动勾选的麻烦)
echo "CONFIG_PACKAGE_luci-app-turboacc=y" >> .config
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config

echo "✅ DIY 脚本整合完毕：TurboAcc 与 NPU 已就绪。"
