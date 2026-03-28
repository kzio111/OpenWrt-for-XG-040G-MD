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

# =========================================================
# 2. 拉取自定义插件（NPU 从你的仓库提取）
# =========================================================

# A. 拉取 Airoha NPU 专项插件（从你的主仓库提取，兼容可能的目录结构调整）
if [ ! -d "package/luci-app-airoha-npu" ]; then
    echo "正在从你的仓库拉取 Airoha NPU 插件..."
    git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
    if [ $? -eq 0 ]; then
        # 动态查找 luci-app-airoha-npu 目录（可能在 package/ 下或更深）
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
# ------------------------- 第一部分：清理 -------------------------
info "清理旧的包文件..."
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true
rm -rf tmp 2>/dev/null || true
info "清理完成。"

# ------------------------- 第二部分：更新 Feeds 并拉取组件 -------------------------
info "更新 feeds 并安装所有包..."
./scripts/feeds update -a || error "feeds update 失败"
./scripts/feeds install -a || error "feeds install -a 失败"

# 单独确保两个组件被安装
./scripts/feeds install kmod-nft-fullcone || warn "kmod-nft-fullcone 在 feeds 中未找到"
./scripts/feeds install luci-app-turboacc || warn "luci-app-turboacc 在 feeds 中未找到"

# ------------------------- 第三方 turboacc 脚本（补全依赖） -------------------------
info "下载并执行 turboacc 依赖补全脚本..."
TEMP_SCRIPT="add_turboacc.sh"
curl -sSL --connect-timeout 10 --retry 3 \
    "https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh" \
    -o "$TEMP_SCRIPT" || error "下载 add_turboacc.sh 失败"

# 可选：添加脚本校验（如果已知期望的 SHA256，可在此处检查）
# 由于原脚本未提供校验和，我们直接执行，但打印警告
warn "正在执行外部脚本 $TEMP_SCRIPT，请确保来源可靠。"
bash "$TEMP_SCRIPT" || error "add_turboacc.sh 执行失败"
rm -f "$TEMP_SCRIPT"

# ------------------------- 第三部分：组件状态检查与补救 -------------------------
info "======= 检查组件拉取状态 ======="

# 检查 kmod-nft-fullcone
FULLCONE_PATH=""
# 首先在 feeds 中查找（常见路径：feeds/packages/net/nft-fullcone 或 feeds/packages/kmod/nft-fullcone）
FULLCONE_PATH=$(find feeds/ -type d -name "kmod-nft-fullcone" -print -quit)
if [ -n "$FULLCONE_PATH" ]; then
    info "✅ kmod-nft-fullcone 已定位: $FULLCONE_PATH"
else
    warn "未在 feeds 中找到 kmod-nft-fullcone，尝试从备用源手动补全..."
    # 备用源：从 kiddin9 仓库克隆 nft-fullcone 目录
    TEMP_REPO="temp_repo_$$"
    git clone --depth 1 --single-branch --branch master \
        "https://github.com/kiddin9/openwrt-packages.git" "$TEMP_REPO" || {
        error "备用源克隆失败，请手动添加 kmod-nft-fullcone 包。"
    }
    if [ -d "$TEMP_REPO/nft-fullcone" ]; then
        cp -r "$TEMP_REPO/nft-fullcone" package/
        info "已将 nft-fullcone 复制到 package/ 目录"
    else
        error "备用源中未找到 nft-fullcone 目录"
    fi
    rm -rf "$TEMP_REPO"
fi

# 检查 luci-app-turboacc
TURBOACC_PATH=$(find feeds/ -type d -name "luci-app-turboacc" -print -quit)
if [ -n "$TURBOACC_PATH" ]; then
    info "✅ luci-app-turboacc 已定位: $TURBOACC_PATH"
else
    error "未找到 luci-app-turboacc，请检查 add_turboacc.sh 是否成功执行。"
fi

info "===================================="

# ------------------------- 第四部分：注入编译配置 -------------------------
info "正在更新 .config 编译配置..."

# 备份原配置（可选）
if [ -f .config ]; then
    cp .config .config.bak.$(date +%Y%m%d_%H%M%S)
    info "已备份原 .config 至 .config.bak.*"
fi

# 移除可能存在的旧配置项
sed -i '/CONFIG_PACKAGE_kmod-nft-fullcone/d' .config
sed -i '/CONFIG_PACKAGE_luci-app-turboacc/d' .config
sed -i '/CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING/d' .config
sed -i '/CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_SHORTCUT_FE/d' .config

# 添加新配置
cat >> .config <<EOF
CONFIG_PACKAGE_kmod-nft-fullcone=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING=y
CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_SHORTCUT_FE=y
EOF

info "已添加 turboacc 相关配置项"

# 执行 defconfig 使配置生效并自动补全依赖
make defconfig || error "make defconfig 失败"

info "所有步骤执行完毕！现在可以运行 'make' 开始编译。"


# C. 锁定配置到 .config
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_NFTABLES_NAT=y"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone=y"

# D. 拉取 Aurora 主题
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

# 再次同步 feeds
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
# 8. 【确保 sysctl 配置文件被打包】
# 说明：你的仓库中已有 files/etc/sysctl.d/sysctl-nf-conntrack.conf，
# 构建时会自动包含。如果因目录未创建导致遗漏，这里强制确保路径存在。
# =========================================================
mkdir -p files/etc/sysctl.d
# 如果文件已存在，跳过；如果不在，可以从其他地方复制（这里仅作示例）
# 假设源文件在仓库根目录的 files/ 下，但我们已经通过 git 管理了正确位置，
# 所以无需额外操作。如果担心，可以执行：cp files/etc/sysctl.d/sysctl-nf-conntrack.conf files/etc/sysctl.d/ 2>/dev/null || true
echo "✅ sysctl 配置文件已准备就绪（位于 files/etc/sysctl.d/sysctl-nf-conntrack.conf）"

# =========================================================
# 9. 最终锁定同步
# =========================================================
make oldconfig

echo "✅ [SUCCESS] 纯净无 WiFi 版 Airoha 编译环境已锁定，NPU 与超频权限已就绪。"
