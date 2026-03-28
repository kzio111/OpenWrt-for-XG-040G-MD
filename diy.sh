#!/bin/bash
set -e

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
YELLOW='\033[33m'
NC='\033[0m'

# =========================================================
# 辅助函数：智能配置注入 (处理 y/n/m 逻辑)
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    local val=$(echo "$1" | cut -d'=' -f2)
    # 如果没传值(即没有=号)，默认设为 y
    if [ "$key" == "$val" ]; then
        val="y"
    fi
    
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$key=$val" >> .config
}

# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并清理冲突包...${NC}"
./scripts/feeds update -a

# 彻底剔除 fwupd，解决包依赖冲突
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除冲突包 fwupd${NC}"

./scripts/feeds install -a

# =========================================================
# 2. 从你的仓库拉取 NPU 插件
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo

# 智能搜索 NPU 插件位置并移动
npu_src=$(find package/temp_repo -type d -name "luci-app-airoha-npu" -print -quit)
if [ -n "$npu_src" ]; then
    mv "$npu_src" package/
    echo -e "${GREEN}✅ NPU 插件拉取成功${NC}"
else
    echo -e "${RED}❌ NPU 插件拉取失败，请检查仓库目录结构${NC}"
    exit 1
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取必备插件 (TurboAcc, Aurora)
# =========================================================
echo -e "${BLUE}拉取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora && echo -e "${GREEN}✅ Aurora 主题就绪${NC}"

echo -e "${BLUE}集成 TurboAcc...${NC}"
# 清理旧冲突
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true

# 定义 tarball 下载函数
download_tarball() {
    local pkg=$1
    local target_dir="package/$pkg"
    local tar_url="https://github.com/kiddin9/openwrt-packages/archive/master.tar.gz"
    mkdir -p "$target_dir"
    cd "$target_dir"
    echo "尝试从 kiddin9 仓库 tarball 下载 $pkg ..."
    if curl -fsSL --connect-timeout 10 --retry 5 -L "$tar_url" -o master.tar.gz; then
        tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/$pkg" 2>/dev/null || { rm -f master.tar.gz; cd - >/dev/null; return 1; }
        rm -f master.tar.gz
        cd - >/dev/null
        return 0
    fi
    cd - >/dev/null
    return 1
}

# 优先 tarball 下载 TurboAcc
if download_tarball "luci-app-turboacc"; then
    echo -e "${GREEN}✅ luci-app-turboacc 通过 tarball 下载成功${NC}"
    # 移除 SFE 依赖，因为 AN7581 用 NPU，不需要软加速
    if [ -f package/luci-app-turboacc/Makefile ]; then
        sed -i '/kmod-fast-classifier/d' package/luci-app-turboacc/Makefile
        sed -i '/kmod-shortcut-fe/d' package/luci-app-turboacc/Makefile
    fi
else
    echo -e "${YELLOW}⚠️ tarball 下载失败，执行备选脚本...${NC}"
    curl -fsSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    [ -f add_turboacc.sh ] && bash add_turboacc.sh --no-sfe && rm -f add_turboacc.sh
fi

# 处理 kmod-nft-fullcone (移动到 kernel 目录以获得更好兼容性)
if download_tarball "nft-fullcone"; then
    mkdir -p package/kernel
    rm -rf package/kernel/nft-fullcone
    mv package/nft-fullcone package/kernel/nft-fullcone
    echo -e "${GREEN}✅ kmod-nft-fullcone 已就绪${NC}"
fi

# =========================================================
# 4. 修复 Linux 6.12 补丁目录 (关键修复)
# =========================================================
if [ -d target/linux/generic/patches ]; then
    echo -e "${BLUE}检测到旧补丁目录，正在适配 6.12 内核规范...${NC}"
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 补丁目录迁移完成${NC}"
fi

# =========================================================
# 5. 同步你的 sysctl 配置
# =========================================================
echo -e "${BLUE}同步你的 sysctl-nf-conntrack.conf...${NC}"
mkdir -p files/etc/sysctl.d
if curl -fsSL --connect-timeout 10 --retry 3 "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf; then
    echo -e "${GREEN}✅ 已同步你的 sysctl 配置${NC}"
else
    echo -e "${RED}⚠️  sysctl 下载失败，请确认分支名为 main${NC}"
fi

# =========================================================
# 6. 注入 CPUFreq 调频内核配置 (修复 N/A 频率)
# =========================================================
echo -e "${BLUE}注入 Airoha CPUFreq 内核支持...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-*" | head -1)
if [ -n "$CFG_FILE" ]; then
    # 清理旧冲突项
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    # 追加新配置
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ CPUFreq 内核驱动注入成功: $CFG_FILE${NC}"
else
    echo -e "${RED}⚠️  未找到内核配置文件，频率显示可能为 N/A${NC}"
fi

# =========================================================
# 7. 锁定编译选项 (.config)
# =========================================================
make defconfig

# 锁定 NPU 核心依赖
add_config "CONFIG_PACKAGE_busybox=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"

# 剔除不需要的软加速模块 (AN7581 用 NPU 硬件转发)
add_config "CONFIG_PACKAGE_kmod-fast-classifier=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-cm=n"

# 勾选必备插件与语言
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone=y"

# =========================================================
# 8. 运行时初始化与最终锁定
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

./scripts/feeds update -i
./scripts/feeds install -a
make oldconfig

echo -e "${GREEN}🎉 [ALL SUCCESS] 嘉欣，你的 XG-040G-MD 固件已准备好编译！${NC}"
