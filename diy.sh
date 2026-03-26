#!/bin/bash

# 1. 修复 Kconfig 循环依赖 (针对 fwupd 报错)
rm -rf feeds/packages/utils/fwupd

# 2. 拉取 TurboAcc 依赖库与插件
[ ! -d "package/turboacc-libs" ] && git clone https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
fi

# 3. 拉取 Airoha NPU 状态插件
[ ! -d "package/luci-app-airoha-npu" ] && git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu

# 4. 强制开启 devmem 全部三项 (解决第二项显示 n 的问题)
# 必须先开启 BUSYBOX_CUSTOM 才能让 DEFAULT_DEVMEM 生效
echo "CONFIG_BUSYBOX_CUSTOM=y" >> .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
echo "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y" >> .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 5. 选中插件
echo "CONFIG_PACKAGE_luci-app-turboacc=y" >> .config
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config

echo "✅ DIY 脚本执行完成 (已移除 SSH 授权注入)"
