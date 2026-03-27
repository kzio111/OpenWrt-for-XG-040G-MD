#!/bin/bash

# =========================================================
# 辅助函数：强力替换/添加 .config 配置 (增加强制清除逻辑)
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$1" >> .config
}

# 1. 修复 Kconfig 循环依赖
rm -rf feeds/packages/utils/fwupd

# 2. 更新并安装 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 拉取 TurboAcc (适配 Airoha NPU)
[ ! -d "package/turboacc-libs" ] && git clone --depth=1 https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
    rm -f add_turboacc.sh
fi

# 4. 拉取 Airoha NPU 插件并修复
if [ ! -d "package/luci-app-airoha-npu" ]; then
    git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
fi
[ -f package/luci-app-airoha-npu/Makefile ] && sed -i 's|\.\./\.\./luci\.mk|$(TOPDIR)/feeds/luci/luci.mk|g' package/luci-app-airoha-npu/Makefile

# 5. 拉取 Aurora 主题
if [ ! -d "package/luci-theme-aurora" ]; then
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
    git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config.git package/luci-app-aurora-config
fi

# 6. 同步新包
./scripts/feeds update -i
./scripts/feeds install -a

# 7. 生成基础配置
make defconfig

# =========================================================
# 8. 【核心修复】解除内核限制，解决 N/A 问题
# =========================================================
# 必须关闭严格内存访问，否则 devmem 无法读取 PLL 寄存器
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_IO_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"

# 补全 Airoha 调频驱动依赖
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-stats=y"
add_config "CONFIG_ARM_AIROHA_CPUFREQ=y"

# 强制开启 Busybox 的 devmem 工具
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"

# =========================================================
# 9. 【核心修复】强制中文包及网络插件
# =========================================================
# 解决中文包丢失：必须勾选 Hans 定义
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-opkg-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-natmap-zh-cn=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"

# 网络插件补全
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_natmap=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"

# =========================================================
# 10. zRAM 与 主题配置
# =========================================================
add_config "CONFIG_PACKAGE_kmod-zram=y"
add_config "CONFIG_PACKAGE_zram-swap=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"
add_config "CONFIG_PACKAGE_luci-app-aurora-config=y"

# 强制覆盖全局主题/语言变量
sed -i 's/^CONFIG_LUCI_THEME=.*/CONFIG_LUCI_THEME=aurora/' .config || echo "CONFIG_LUCI_THEME=aurora" >> .config
sed -i 's/^CONFIG_LUCI_LANG=.*/CONFIG_LUCI_LANG=zh-cn/' .config || echo "CONFIG_LUCI_LANG=zh-cn" >> .config

# =========================================================
# 11. 运行时自动化配置
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 1. 强制切换中文
uci set luci.main.lang='zh_cn'
uci commit luci

# 2. 默认开启 TurboAcc 硬件分流
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc

# 3. 时区设置
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system

# 4. zRAM 启用
if [ -x "/etc/init.d/zram" ]; then
    /etc/init.d/zram enable
fi

exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# 12. 最终同步依赖
make oldconfig

echo "✅ [SUCCESS] N/A 权限已解锁，zRAM/UPnP/Natmap 已就绪，中文包已锁定。"
