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
rm -rf feeds/packages/multimedia/gst1-plugins-base
rm -rf feeds/packages/net/fail2ban
rm -rf feeds/packages/net/onionshare-cli
rm -rf feeds/packages/utils/setools
# 若 bmx7、olsrd 等也不需要，可一并删除
rm -rf feeds/packages/net/bmx7*
rm -rf feeds/luci/applications/luci-app-bmx7
rm -rf feeds/packages/net/olsrd
rm -rf feeds/luci/applications/luci-app-olsr*
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
# 4. TurboAcc 优化（使用 tarball 避免 git 认证）
# =========================================================
echo "清理旧的 turboacc 相关文件..."
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true
rm -rf tmp 2>/dev/null || true

# 手动放置 luci-app-turboacc（避免 add_turboacc.sh 中的 git clone）
if [ ! -d "package/luci-app-turboacc" ]; then
    echo "⚠️ 未找到 luci-app-turboacc，尝试手动下载 tarball..."
    mkdir -p package/luci-app-turboacc
    cd package/luci-app-turboacc
    TARBALL_URL="https://github.com/kiddin9/openwrt-packages/archive/refs/heads/master.tar.gz"
    curl -fsSL --connect-timeout 10 --retry 5 --retry-delay 2 "$TARBALL_URL" -o master.tar.gz || {
        echo "❌ 下载压缩包失败，请检查网络或手动添加 luci-app-turboacc 包"
        exit 1
    }
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/luci-app-turboacc" 2>/dev/null
    rm -f master.tar.gz
    cd - >/dev/null
    if [ -f package/luci-app-turboacc/Makefile ]; then
        echo "✅ luci-app-turboacc 已手动放置到 package/luci-app-turboacc/"
    else
        echo "❌ 手动添加 luci-app-turboacc 失败"
        exit 1
    fi
fi

# 下载并执行第三方 turboacc 依赖补全脚本
echo "下载并执行 turboacc 依赖补全脚本..."
TEMP_SCRIPT="add_turboacc.sh"
curl -fsSL --connect-timeout 10 --retry 3 \
    "https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh" \
    -o "$TEMP_SCRIPT" || { echo "下载 add_turboacc.sh 失败"; exit 1; }

echo "正在执行外部脚本 $TEMP_SCRIPT（请确保来源可靠）..."
bash "$TEMP_SCRIPT" || { echo "add_turboacc.sh 执行失败"; exit 1; }
rm -f "$TEMP_SCRIPT"

# 手动放置 kmod-nft-fullcone
if [ ! -d "package/kmod-nft-fullcone" ]; then
    echo "⚠️ 未找到 kmod-nft-fullcone，尝试手动下载 tarball..."
    mkdir -p package/kmod-nft-fullcone
    cd package/kmod-nft-fullcone
    TARBALL_URL="https://github.com/kiddin9/openwrt-packages/archive/refs/heads/master.tar.gz"
    curl -fsSL --connect-timeout 10 --retry 5 --retry-delay 2 "$TARBALL_URL" -o master.tar.gz || {
        echo "❌ 下载压缩包失败，请检查网络或手动添加 kmod-nft-fullcone 包"
        exit 1
    }
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/nft-fullcone" 2>/dev/null || \
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/kmod-nft-fullcone" 2>/dev/null
    rm -f master.tar.gz
    cd - >/dev/null
    if [ -d package/nft-fullcone ] && [ ! -d package/kmod-nft-fullcone ]; then
        mv package/nft-fullcone package/kmod-nft-fullcone
    fi
    if [ -f package/kmod-nft-fullcone/Makefile ]; then
        echo "✅ kmod-nft-fullcone 已成功放置到 package/kmod-nft-fullcone/"
    else
        echo "❌ 手动添加 kmod-nft-fullcone 失败"
        exit 1
    fi
fi

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
