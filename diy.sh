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

# 1. 修复 Kconfig 循环依赖并更新 Feeds
rm -rf feeds/packages/utils/fwupd
./scripts/feeds update -a
./scripts/feeds install -a

# 2. 拉取 Airoha NPU 专项插件 (超频与 PPE 必备)
[ ! -d "package/luci-app-airoha-npu" ] && git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu

# 拉取核心插件 (TurboAcc, Aurora 主题)
[ ! -d "package/turboacc-libs" ] && git clone --depth=1 https://github.com/chenmozhijin/turboacc-libs package/turboacc-libs
if [ ! -d "package/luci-app-turboacc" ]; then
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    bash add_turboacc.sh --no-sfe
    rm -f add_turboacc.sh
fi
[ ! -d "package/luci-theme-aurora" ] && git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

./scripts/feeds update -i
./scripts/feeds install -a

# 3. 生成基础配置
make defconfig

# =========================================================
# 4. 【核心修复】解锁 Devmem 寄存器访问与 CPU 频率 (解决 N/A)
# =========================================================
# A. 强制 Busybox 内置，解决 [=m] 降级导致子项失效的问题
add_config "CONFIG_PACKAGE_busybox=y"
add_config "CONFIG_PACKAGE_busybox-selinux=y"
add_config "CONFIG_BUSYBOX_CUSTOM=y"

# B. 开启 Devmem 及其权限 (插件超频 PLL 寄存器访问必备: 0x1fa202b4)
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"

# C. 解除内核层面的内存访问限制 (关键：STRICT_DEVMEM=n)
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_IO_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"

# D. 开启内核调频与 PPE 调试需要的 Debugfs
add_config "CONFIG_KERNEL_DEBUG_FS=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-stats=y"

# E. 物理注入 Airoha 内核调频驱动 (无视菜单隐藏)
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ_STAT=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_ARM_AIROHA_CPUFREQ=y' {}

# =========================================================
# 5. 【彻底剔除 WiFi】去除所有无线相关驱动与支持
# =========================================================
add_config "CONFIG_PACKAGE_kmod-mt76=n"
add_config "CONFIG_PACKAGE_kmod-mt7915-firmware=n"
add_config "CONFIG_PACKAGE_wpad-basic-wolfssl=n"
add_config "CONFIG_PACKAGE_iw=n"
add_config "CONFIG_PACKAGE_wireless-tools=n"
# 同时也取消插件中关于 WiFi token_info 的可选依赖

# =========================================================
# 6. 【插件与功能锁定】勾选 NPU 与网络加速
# =========================================================
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_kmod-zram=y"
add_config "CONFIG_PACKAGE_zram-swap=y"

# 强制中文包与主题
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"

# =========================================================
# 7. 运行时初始化配置 (uci-defaults)
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
# 强制中文和主题
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
# 开启硬件加速 (HW NAT)
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
# 8. 最终锁定同步
# =========================================================
make oldconfig

echo "✅ [SUCCESS] 纯净无 WiFi 版 Airoha 编译环境已锁定，NPU 与超频权限已就绪。"
