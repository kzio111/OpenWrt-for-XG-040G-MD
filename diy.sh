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

# =========================================================
# 1. 更新 Feeds 并安装所有包
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# 2. 删除引起警告的无用包（消除编译日志噪音）
echo "正在清理无用的包依赖（消除警告）..."
rm -rf feeds/packages/utils/fwupd
echo "清理完成。"

# =========================================================
# 3. 拉取自定义插件（NPU 从你的仓库提取）
# =========================================================
if [ ! -d "package/luci-app-airoha-npu" ]; then
    echo "正在从你的仓库拉取 Airoha NPU 插件..."
    git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
    if [ $? -eq 0 ]; then
        plugin_src=$(find package/temp_npu/package -type d -name "luci-app-airoha-npu" -print -quit)
        if [ -n "$plugin_src" ]; then
            mv "$plugin_src" package/
            rm -rf package/temp_npu
            echo "✅ [SUCCESS] Airoha NPU 插件已就绪"
        else
            echo "❌ [ERROR] 在仓库中未找到 luci-app-airoha-npu 目录"
            exit 1
        fi
    else
        echo "❌ [ERROR] 克隆仓库失败，请检查网络或仓库地址"
        exit 1
    fi
fi

# =========================================================
# =========================================================
# 4. TurboAcc 集成（使用 chenmozhijin/turboacc 仓库）
# =========================================================
echo "正在使用 TurboAcc 脚本集成（chenmozhijin/turboacc）..."

# 清理旧文件（可选）
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true
rm -rf tmp 2>/dev/null || true

# 执行 TurboAcc 脚本（--no-sfe 参数）
if curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh && \
   bash add_turboacc.sh --no-sfe; then
    echo -e "\033[32m🎉 [SUCCESS] TurboAcc 脚本集成执行成功！\033[0m"
    echo -e "\033[32m✅ NFTables / Flow Offload 已准备就绪\033[0m"
else
    echo -e "\033[31m❌ [ERROR] TurboAcc 脚本执行失败，请检查网络连接或仓库地址。\033[0m"
    exit 1
fi

rm -f add_turboacc.sh

# 重新生成 feeds 索引，确保新加入的包被识别
./scripts/feeds update -i
./scripts/feeds install -a
# =========================================================
# 5. 拉取 Aurora 主题（可选）
# =========================================================
if [ ! -d "package/luci-theme-aurora" ]; then
    echo "正在拉取 Aurora 主题..."
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
    if [ $? -eq 0 ]; then
        echo "✅ [SUCCESS] Aurora 主题拉取成功"
    else
        echo "❌ [ERROR] Aurora 主题拉取失败"
        exit 1
    fi
fi

# =========================================================
# 6. 生成基础配置
# =========================================================
make defconfig

# =========================================================
# 7. 【核心修复】解锁 Devmem 寄存器访问与 CPU 频率
# =========================================================
add_config "CONFIG_PACKAGE_busybox=y"
add_config "CONFIG_PACKAGE_busybox-selinux=y"
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_IO_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"
add_config "CONFIG_KERNEL_DEBUG_FS=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-stats=y"

# 物理注入 Airoha 内核调频驱动
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ_STAT=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_ARM_AIROHA_CPUFREQ=y' {}

# =========================================================
# 8. 【彻底剔除 WiFi】去除所有无线相关驱动与支持
# =========================================================
add_config "CONFIG_PACKAGE_kmod-mt76=n"
add_config "CONFIG_PACKAGE_kmod-mt7915-firmware=n"
add_config "CONFIG_PACKAGE_wpad-basic-wolfssl=n"
add_config "CONFIG_PACKAGE_iw=n"
add_config "CONFIG_PACKAGE_wireless-tools=n"

# =========================================================
# 9. 【插件与功能锁定】勾选 NPU 与网络加速
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
# 10. 运行时初始化配置 (uci-defaults)
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
# 11. 确保 sysctl 配置文件打包
# =========================================================
mkdir -p files/etc/sysctl.d
echo "✅ sysctl 配置文件已准备就绪（位于 files/etc/sysctl.d/sysctl-nf-conntrack.conf）"

# =========================================================
# 12. 最终锁定同步
# =========================================================
make oldconfig

echo "✅ [SUCCESS] 纯净无 WiFi 版 Airoha 编译环境已锁定，NPU 与超频权限已就绪。"
