#!/bin/bash

# =========================================================
# 辅助函数：强力替换/添加 .config 配置
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    # 删除已有的冲突项（包括被注释掉的项）
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$1" >> .config
}

# =========================================================
# 1. 修复 Kconfig 循环依赖（fwupd 冲突）
# =========================================================
rm -rf feeds/packages/utils/fwupd

# =========================================================
# 2. 更新并安装 feeds（基础）
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# =========================================================
# 3. 拉取 TurboAcc 及其依赖驱动
# =========================================================
[ ! -d "package/turboacc-libs" ] && git clone --depth=1 https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
    rm -f add_turboacc.sh
fi

# =========================================================
# 4. 拉取 Airoha NPU 插件并修复 Makefile 路径
# =========================================================
if [ ! -d "package/luci-app-airoha-npu" ]; then
    git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
fi
if [ -f package/luci-app-airoha-npu/Makefile ]; then
    sed -i 's|\.\./\.\./luci\.mk|$(TOPDIR)/feeds/luci/luci.mk|g' package/luci-app-airoha-npu/Makefile
fi

# =========================================================
# 5. 拉取 Aurora 主题及其配置插件
# =========================================================
if [ ! -d "package/luci-theme-aurora" ]; then
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
fi
if [ ! -d "package/luci-app-aurora-config" ]; then
    git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config.git package/luci-app-aurora-config
fi

# =========================================================
# 6. 再次同步 feeds 以识别新拉取的包
# =========================================================
./scripts/feeds update -i
./scripts/feeds install -a

# =========================================================
# 7. 生成基础配置（先做，避免后续被覆盖）
# =========================================================
make defconfig

# =========================================================
# 8. 强制勾选核心插件与依赖（使用 add_config 避免重复）
# =========================================================
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
add_config "CONFIG_KERNEL_DEVMEM=y"

# =========================================================
# 9. CPU 频率调控支持（解决 CPU 频率显示 N/A 问题）
# =========================================================
add_config "CONFIG_PACKAGE_collectd=y"
add_config "CONFIG_PACKAGE_collectd-mod-cpufreq=y"
add_config "CONFIG_CPU_FREQ=y"
add_config "CONFIG_CPU_FREQ_GOV_COMMON=y"
add_config "CONFIG_CPU_FREQ_GOV_PERFORMANCE=y"
add_config "CONFIG_CPU_FREQ_GOV_POWERSAVE=y"
add_config "CONFIG_CPU_FREQ_GOV_USERSPACE=y"
add_config "CONFIG_CPU_FREQ_GOV_ONDEMAND=y"
add_config "CONFIG_CPU_FREQ_GOV_CONSERVATIVE=y"
add_config "CONFIG_ARM_AIROHA_CPUFREQ=y"

# =========================================================
# 10. 语言包与主题配置
# =========================================================
add_config "CONFIG_PACKAGE_luci-i18n-zh-cn=y"          # 中文语言包
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"        # Aurora 主题
add_config "CONFIG_PACKAGE_luci-app-aurora-config=y"   # 主题配置插件

# 设置默认主题为 Aurora
if grep -q "CONFIG_LUCI_THEME=" .config; then
    sed -i 's/^CONFIG_LUCI_THEME=.*/CONFIG_LUCI_THEME=aurora/' .config
else
    echo "CONFIG_LUCI_THEME=aurora" >> .config
fi

# 设置默认语言为中文
if grep -q "CONFIG_LUCI_LANG=" .config; then
    sed -i 's/^CONFIG_LUCI_LANG=.*/CONFIG_LUCI_LANG=zh-cn/' .config
else
    echo "CONFIG_LUCI_LANG=zh-cn" >> .config
fi

# =========================================================
# 11. 添加 Zram 和 Coremark
# =========================================================
add_config "CONFIG_PACKAGE_kmod-zram=y"                # zram 内核模块
add_config "CONFIG_PACKAGE_zram-swap=y"                # zram 管理工具
add_config "CONFIG_PACKAGE_coremark=y"                 # CPU 性能测试工具

# =========================================================
# 12. 创建运行时自动化配置（uci-defaults）
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# 默认开启 TurboAcc 硬件加速
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc

# 默认关闭 UPnP（安全考虑）
uci set upnpd.config.enabled='0'
uci commit upnpd

# 默认关闭 Natmap（按需手动开启）
if uci get natmap.config >/dev/null 2>&1; then
    uci set natmap.config.enabled='0'
    uci commit natmap
fi

# 设置默认时区为上海
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system

# 确保 Aurora 主题和中文语言生效
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.theme='aurora'
uci set luci.main.lang='zh_cn'
uci commit luci

# 重启 uhttpd 使主题生效
/etc/init.d/uhttpd restart

exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-settings

# =========================================================
# 13. 更新配置，保留我们的修改
# =========================================================
make oldconfig

echo "✅ [SUCCESS] 所有插件已集成并强制勾选，默认配置已生成。"
