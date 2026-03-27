#!/bin/bash

# =========================================================
# 辅助函数：强力替换/添加 .config 配置 (物理注入)
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

# 3. 拉取核心插件 (TurboAcc, NPU, Aurora 主题, Natmap)
[ ! -d "package/turboacc-libs" ] && git clone --depth=1 https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
    rm -f add_turboacc.sh
fi
[ ! -d "package/luci-app-airoha-npu" ] && git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
[ -f package/luci-app-airoha-npu/Makefile ] && sed -i 's|\.\./\.\./luci\.mk|$(TOPDIR)/feeds/luci/luci.mk|g' package/luci-app-airoha-npu/Makefile
[ ! -d "package/luci-theme-aurora" ] && git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

./scripts/feeds update -i
./scripts/feeds install -a

# 4. 生成基础配置 (此时父依赖可能还未满足)
make defconfig

# =========================================================
# 5. 【暴力修复】解决 CPU 频率 N/A 的关键 (绕过 menuconfig)
# =========================================================
# A. 物理注入内核驱动开关 (直接改内核模板)
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ_STAT=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ_GOV_PERFORMANCE=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_ARM_AIROHA_CPUFREQ=y' {}

# B. 强制开启 Busybox 工具链与权限 (解决截图里选不上的问题)
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
add_config "CONFIG_PACKAGE_busybox-selinux=y"

# C. 解除内核安全锁 (没这个权限 devmem 读不到数)
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_IO_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"

# D. 补齐调频内核模块
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-stats=y"

# =========================================================
# 6. 【补齐功能】UPnP, Natmap, zRAM, 中文包
# =========================================================
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_natmap=y"
add_config "CONFIG_PACKAGE_kmod-zram=y"
add_config "CONFIG_PACKAGE_zram-swap=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"

# 强制中文包锁定
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-natmap-zh-cn=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"

# =========================================================
# 7. 运行时配置 (uci-defaults)
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
# 强制中文和主题
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
# 开启硬件分流
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc
# 开启 zRAM
[ -x "/etc/init.d/zram" ] && /etc/init.d/zram enable
# 设置时区
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# =========================================================
# 8. 最终锁定 (关键：再次执行以强制同步物理注入的选项)
# =========================================================
make oldconfig

echo "✅ [SUCCESS] N/A 修复、网络插件、中文包已全部物理锁定。"
