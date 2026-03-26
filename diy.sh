#!/bin/bash

# 1. 修复 Kconfig 循环依赖 (防止 fwupd 导致的编译中断)
rm -rf feeds/packages/utils/fwupd

# 2. 拉取 TurboAcc 及其依赖驱动
[ ! -d "package/turboacc-libs" ] && git clone https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
fi

# 3. 拉取并修复 NPU 插件
if [ ! -d "package/luci-app-airoha-npu" ]; then
    git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
fi

# 【核心修复】修正 NPU Makefile 的路径错误
if [ -f package/luci-app-airoha-npu/Makefile ]; then
    sed -i 's/\.\.\/\.\.\/luci\.mk/$(TOPDIR)\/feeds\/luci\/luci.mk/g' package/luci-app-airoha-npu/Makefile
fi

# 4. 强制开启内核与硬件相关依赖 (针对 Airoha NPU)
echo "CONFIG_BUSYBOX_CUSTOM=y" >> .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
echo "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y" >> .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 5. 【新增】自动勾选 UPnP 和 Natmap 插件
echo "CONFIG_PACKAGE_luci-app-upnp=y" >> .config
echo "CONFIG_PACKAGE_luci-app-natmap=y" >> .config
# 强制添加中文语言包
echo 'CONFIG_LUCI_LANG_zh_Hans=y' >> .config

# 6. 【进阶】设置 UPnP 和 Natmap 默认开启逻辑 (修改默认配置文件)
# 创建默认开启的脚本，在固件第一次启动时生效
mkdir -p files/etc/uci-defaults
cat <<EOF > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 默认启用 UPnP
uci set upnpd.config.enabled='1'
uci commit upnpd

# 如果需要默认开启 TurboAcc 的 HWNAT (配合 NPU)
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc

exit 0
EOF

echo "✅ DIY 脚本整合完毕：TurboAcc、NPU、UPnP、Natmap 已全部就绪。"
