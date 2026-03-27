#!/bin/bash

# 1. 修复 Kconfig 循环依赖
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

# 4. 【强制勾选插件】直接写入 .config 确保编译包含
# 使用 tee -a 确保追加到末尾，覆盖之前的设置
cat <<EOF >> .config
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-airoha-npu=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-app-natmap=y
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_DEVMEM=y
CONFIG_BUSYBOX_DEFAULT_DEVMEM=y
CONFIG_KERNEL_DEVMEM=y
EOF

# 5. 【中文包配置】
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config
# 自动清除所有插件的英文包选中状态，改为选中中文包
sed -i 's/CONFIG_PACKAGE_luci-i18n-.*-en=y/# CONFIG_PACKAGE_luci-i18n-.*-en is not set/g' .config
cat <<EOF >> .config
CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
EOF

# 6. 锁定默认语言为中文
if [ -f feeds/luci/modules/luci-base/root/etc/config/luci ]; then
    sed -i 's/option lang auto/option lang zh_hans/g' feeds/luci/modules/luci-base/root/etc/config/luci
fi

# 7. 设置运行时默认开启/关闭逻辑
mkdir -p files/etc/uci-defaults
cat <<EOF > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 默认开启 TurboAcc 硬件加速 (适配 NPU)
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc

# 默认关闭 UPnP
uci set upnpd.config.enabled='0'
uci commit upnpd

# 默认关闭 Natmap
if uci get natmap.config >/dev/null 2>&1; then
    uci set natmap.config.enabled='0'
    uci commit natmap
fi

exit 0
EOF

echo "✅ DIY 脚本已更新：已强制勾选 TurboAcc 和 Airoha-NPU 插件。"
