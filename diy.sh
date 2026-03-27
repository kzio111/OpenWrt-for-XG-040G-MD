#!/bin/bash

# 辅助函数：强力替换/添加 .config 配置
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    # 删除已有的冲突项（包括被注释掉的项）
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$1" >> .config
}

# 1. 修复 Kconfig 循环依赖
rm -rf feeds/packages/utils/fwupd

# 2. 更新并安装 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 拉取 TurboAcc 及其依赖驱动
[ ! -d "package/turboacc-libs" ] && git clone --depth=1 https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
    rm -f add_turboacc.sh
fi

# 4. 拉取并修复 Airoha NPU 插件
if [ ! -d "package/luci-app-airoha-npu" ]; then
    git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
fi
if [ -f package/luci-app-airoha-npu/Makefile ]; then
    sed -i 's|\.\./\.\./luci\.mk|$(TOPDIR)/feeds/luci/luci.mk|g' package/luci-app-airoha-npu/Makefile
fi

# 5. 再次同步 feeds 以识别新拉取的 package
./scripts/feeds update -i
./scripts/feeds install -a

# 6. 生成基础配置（先做，避免后续被覆盖）
make defconfig

# 7. 强制勾选核心插件与依赖（现在添加不会被打乱）
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
add_config "CONFIG_KERNEL_DEVMEM=y"

# 8. 语言包与主题配置
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"   # 确认包名正确
add_config "CONFIG_PACKAGE_luci-theme-argon=y"

# 强制设置默认主题为 Argon
sed -i 's/^CONFIG_LUCI_THEME=.*/CONFIG_LUCI_THEME=argon/' .config || echo "CONFIG_LUCI_THEME=argon" >> .config
# 强制设置默认语言为中文
sed -i 's/^CONFIG_LUCI_LANG=.*/CONFIG_LUCI_LANG=zh-cn/' .config || echo "CONFIG_LUCI_LANG=zh-cn" >> .config

# 9. 创建运行时自动化配置 (uci-defaults)
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 默认开启 TurboAcc 硬件加速
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

# 设置默认时区为上海
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system

exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-settings

# 10. 更新配置，保留我们的修改
make oldconfig

echo "✅ [SUCCESS] 所有插件已集成并强制勾选，默认配置已生成。"
