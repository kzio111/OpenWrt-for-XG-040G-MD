#!/bin/bash

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${RED}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
info "开始更新 Feeds 并清理冲突包..."
./scripts/feeds update -a || error "feeds update 失败"
# 删除 fwupd（避免循环依赖警告）
rm -rf feeds/packages/utils/fwupd && info "✅ 已移除冲突包 fwupd"
./scripts/feeds install -a || error "feeds install 失败"

# 同时删除其他可能引起警告的包（可选）
rm -rf feeds/packages/multimedia/gst1-plugins-base 2>/dev/null || true
rm -rf feeds/packages/net/fail2ban 2>/dev/null || true
rm -rf feeds/packages/net/onionshare-cli 2>/dev/null || true
rm -rf feeds/packages/utils/setools 2>/dev/null || true

# =========================================================
# 2. 从你的仓库拉取 NPU 插件
# =========================================================
info "正在从你的仓库拉取 Airoha NPU 插件..."
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo || error "克隆仓库失败"

if [ -d "package/temp_repo/package/luci-app-airoha-npu" ]; then
    mv package/temp_repo/package/luci-app-airoha-npu package/
    info "✅ NPU 插件拉取成功"
else
    npu_dir=$(find package/temp_repo -type d -name "luci-app-airoha-npu" -print -quit)
    if [ -n "$npu_dir" ]; then
        mv "$npu_dir" package/
        info "✅ NPU 插件拉取成功 (从子目录)"
    else
        error "❌ NPU 插件拉取失败，请检查仓库目录结构"
    fi
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取必备插件 (TurboAcc, Aurora, Upnp, Natmap)
# =========================================================
# 主题
info "拉取 Aurora 主题..."
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora || warn "Aurora 主题拉取失败，继续"

# TurboAcc 集成
info "集成 TurboAcc 并修复 6.12 补丁规范..."
# 清理旧文件
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true

# 手动下载 luci-app-turboacc（避免 git clone 认证问题）
if [ ! -d "package/luci-app-turboacc" ]; then
    info "手动下载 luci-app-turboacc..."
    mkdir -p package/luci-app-turboacc
    cd package/luci-app-turboacc
    curl -fsSL --connect-timeout 10 --retry 5 \
        "https://github.com/kiddin9/openwrt-packages/archive/refs/heads/master.tar.gz" -o master.tar.gz || error "下载失败"
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/luci-app-turboacc" 2>/dev/null
    rm -f master.tar.gz
    cd - >/dev/null
    # 清理 SFE 依赖
    if [ -f package/luci-app-turboacc/Makefile ]; then
        sed -i '/kmod-fast-classifier/d' package/luci-app-turboacc/Makefile
        sed -i '/kmod-shortcut-fe/d' package/luci-app-turboacc/Makefile
    fi
fi

# 执行第三方脚本
if curl -fsSL "https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh" -o add_turboacc.sh && \
   bash add_turboacc.sh --no-sfe; then
    info "✅ TurboAcc 脚本执行成功"
else
    error "❌ TurboAcc 集成失败"
fi
rm -f add_turboacc.sh

# 二次清理 SFE 依赖（确保无论脚本放置到哪里都被清理）
for mk in $(find package/ -name "Makefile" -path "*/luci-app-turboacc/Makefile" 2>/dev/null); do
    info "清理 $mk 中的 SFE 依赖"
    sed -i '/kmod-fast-classifier/d' "$mk"
    sed -i '/kmod-shortcut-fe/d' "$mk"
done

# 手动下载 kmod-nft-fullcone
if [ ! -d "package/kmod-nft-fullcone" ]; then
    info "手动下载 kmod-nft-fullcone..."
    mkdir -p package/kmod-nft-fullcone
    cd package/kmod-nft-fullcone
    curl -fsSL --connect-timeout 10 --retry 5 \
        "https://github.com/kiddin9/openwrt-packages/archive/refs/heads/master.tar.gz" -o master.tar.gz || error "下载失败"
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/nft-fullcone" 2>/dev/null || \
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/kmod-nft-fullcone" 2>/dev/null
    rm -f master.tar.gz
    cd - >/dev/null
    if [ -d package/nft-fullcone ] && [ ! -d package/kmod-nft-fullcone ]; then
        mv package/nft-fullcone package/kmod-nft-fullcone
    fi
    [ -f package/kmod-nft-fullcone/Makefile ] || error "kmod-nft-fullcone 放置失败"
fi

# 修复 generic/patches 目录问题
if [ -d "target/linux/generic/patches" ]; then
    info "修复 6.12 内核补丁目录..."
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null
    rm -rf target/linux/generic/patches
    info "✅ 补丁目录修复成功"
fi

# =========================================================
# 4. 同步你的 sysctl 配置文件
# =========================================================
info "同步你的 sysctl-nf-conntrack.conf..."
mkdir -p files/etc/sysctl.d
if curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf; then
    info "✅ 已同步你的 sysctl 配置"
else
    warn "⚠️ sysctl 下载失败，请检查 raw 链接分支是否为 main"
fi

# =========================================================
# 5. 【关键注入】CPUFreq 调频支持 (防止频率显示 N/A)
# =========================================================
info "注入 Airoha CPUFreq 调频内核配置..."
CFG_612=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_612" ]; then
    # 检查是否已存在，避免重复行
    grep -q "CONFIG_CPU_FREQ=y" "$CFG_612" || echo "CONFIG_CPU_FREQ=y" >> "$CFG_612"
    grep -q "CONFIG_CPU_FREQ_STAT=y" "$CFG_612" || echo "CONFIG_CPU_FREQ_STAT=y" >> "$CFG_612"
    grep -q "CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y" "$CFG_612" || echo "CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y" >> "$CFG_612"
    grep -q "CONFIG_ARM_AIROHA_CPUFREQ=y" "$CFG_612" || echo "CONFIG_ARM_AIROHA_CPUFREQ=y" >> "$CFG_612"
    info "✅ CPUFreq 内核驱动注入成功"
else
    warn "⚠️ 未找到 config-6.12 文件，注入失败"
fi

# =========================================================
# 6. 配置锁定与中文语言包
# =========================================================
# 辅助函数：安全添加配置
add_config() {
    sed -i "/^$1=/d" .config
    sed -i "/^# $1 is not set/d" .config
    echo "$1=y" >> .config
}

# 先执行一次 defconfig 生成基础配置
make defconfig

# 锁定 NPU 依赖 (devmem)
add_config "CONFIG_PACKAGE_busybox"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu"

# 调频支持勾选
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt"

# 网络加速包（确保选中）
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"
add_config "CONFIG_PACKAGE_luci-app-upnp"
add_config "CONFIG_PACKAGE_luci-app-natmap"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn"

# 禁用 SFE（避免依赖）
add_config "CONFIG_PACKAGE_kmod-fast-classifier=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-cm=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-drv=n"

# =========================================================
# 7. 运行时初始化与最后同步
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# 更新 feeds 索引并安装所有包
./scripts/feeds update -i
./scripts/feeds install -a

# 最终同步配置
make oldconfig

info "🎉 [ALL SUCCESS] 嘉欣，你的 XG-040G-MD 编译环境已完美就绪！"
