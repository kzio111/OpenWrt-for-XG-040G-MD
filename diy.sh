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

# 4. 基础功能与内核依赖 (针对 Airoha 平台)
cat <<EOF >> .config
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_DEVMEM=y
CONFIG_BUSYBOX_DEFAULT_DEVMEM=y
CONFIG_KERNEL_DEVMEM=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-app-natmap=y
EOF

# 5. 中文语言包配置
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config
# 自动选中所有已选插件的中文语言包
sed -i 's/CONFIG_PACKAGE_luci-i18n-.*-en=y/# CONFIG_PACKAGE_luci-i18n-.*-en is not set/g' .config
cat <<EOF >> .config
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=y
EOF

# 6. 锁定默认语言为中文 (开机即中文)
if [ -f feeds/luci/modules/luci-base/root/etc/config/luci ]; then
    sed -i 's/option lang auto/option lang zh_hans/g' feeds/luci/modules/luci-base/root/etc/config/luci
fi

# 7. 设置默认启动/关闭逻辑 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat <<EOF > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 【默认开启】TurboAcc 硬件加速 (配合 NPU)
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc

# 【默认关闭】UPnP
uci set upnpd.config.enabled='0'
uci commit upnpd

# 【默认关闭】Natmap (确保配置项存在时关闭)
if uci get natmap.config >/dev/null 2>&1; then
    uci set natmap.config.enabled='0'
    uci commit natmap
fi

exit 0
EOF

echo "✅ DIY 脚本调整完毕：中文环境已锁定，TurboAcc 默认开启，UPnP/Natmap 默认关闭。"
