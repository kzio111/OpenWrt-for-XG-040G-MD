#!/bin/bash
set -e

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
YELLOW='\033[33m'
NC='\033[0m'

# =========================================================
# 辅助函数：配置注入
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    echo "$1=y" >> .config
}

# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并清理冲突包...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除冲突包 fwupd${NC}"
./scripts/feeds install -a

# =========================================================
# 2. 拉取 NPU 插件（从你的仓库）
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo

if [ -d "package/temp_repo/package/luci-app-airoha-npu" ]; then
    mv package/temp_repo/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件拉取成功${NC}"
else
    npu_dir=$(find package/temp_repo -type d -name "luci-app-airoha-npu" -print -quit)
    if [ -n "$npu_dir" ]; then
        mv "$npu_dir" package/
        echo -e "${GREEN}✅ NPU 插件拉取成功 (从子目录)${NC}"
    else
        echo -e "${RED}❌ NPU 插件拉取失败，请检查仓库目录结构${NC}"
        exit 1
    fi
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取必备插件 (TurboAcc, Aurora)
# =========================================================
echo -e "${BLUE}拉取 Aurora 主题...${NC}"
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora && echo -e "${GREEN}✅ Aurora 主题就绪${NC}"

# TurboAcc 集成（优先 tarball，失败则回退外部脚本，但先清理 6.18 干扰）
echo -e "${BLUE}集成 TurboAcc...${NC}"
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/feeds/packages/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf package/kmod-nft-fullcone 2>/dev/null || true
rm -rf package/turboacc-libs 2>/dev/null || true

# 定义 tarball 下载函数
download_tarball() {
    local pkg=$1
    local target_dir="package/$pkg"
    local tar_url="https://github.com/kiddin9/openwrt-packages/archive/refs/heads/master.tar.gz"
    mkdir -p "$target_dir"
    cd "$target_dir"
    echo "下载 $pkg 从 $tar_url ..."
    curl -fsSL --connect-timeout 10 --retry 5 --retry-delay 2 -L "$tar_url" -o master.tar.gz || return 1
    tar -xzf master.tar.gz --strip-components=2 -C . "openwrt-packages-master/$pkg" 2>/dev/null || { rm -f master.tar.gz; cd - >/dev/null; return 1; }
    rm -f master.tar.gz
    cd - >/dev/null
    return 0
}

# 优先尝试 tarball 下载
if download_tarball "luci-app-turboacc"; then
    echo -e "${GREEN}✅ luci-app-turboacc 通过 tarball 下载成功${NC}"
    if [ -f package/luci-app-turboacc/Makefile ]; then
        sed -i '/kmod-fast-classifier/d' package/luci-app-turboacc/Makefile
        sed -i '/kmod-shortcut-fe/d' package/luci-app-turboacc/Makefile
    fi
else
    echo -e "${YELLOW}⚠️ tarball 下载失败，回退到执行外部脚本...${NC}"
    # 在运行外部脚本前，删除可能导致版本误判的 6.18 补丁目录
    echo -e "${BLUE}清理可能引起 6.18 版本误判的目录...${NC}"
    rm -rf target/linux/generic/patches-6.18 2>/dev/null || true
    rm -rf target/linux/generic/pending-6.18 2>/dev/null || true
    # 如果还有别的 6.18 目录，可以继续添加
    echo -e "${GREEN}已清理 6.18 相关目录${NC}"
    
    curl -fsSL --connect-timeout 10 --retry 3 https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    if [ -f add_turboacc.sh ]; then
        bash add_turboacc.sh --no-sfe || echo -e "${RED}TurboAcc 脚本执行失败${NC}"
        rm -f add_turboacc.sh
    else
        echo -e "${RED}❌ 无法下载外部脚本，TurboAcc 集成失败${NC}"
        exit 1
    fi
fi

# 同样处理 kmod-nft-fullcone
if download_tarball "nft-fullcone"; then
    if [ -d package/nft-fullcone ] && [ ! -d package/kmod-nft-fullcone ]; then
        mv package/nft-fullcone package/kmod-nft-fullcone
    fi
    echo -e "${GREEN}✅ kmod-nft-fullcone 通过 tarball 下载成功${NC}"
else
    echo -e "${YELLOW}⚠️ kmod-nft-fullcone tarball 下载失败，尝试通过外部脚本处理...${NC}"
    # 同样先清理 6.18 目录
    rm -rf target/linux/generic/patches-6.18 2>/dev/null || true
    rm -rf target/linux/generic/pending-6.18 2>/dev/null || true
    curl -fsSL --connect-timeout 10 --retry 3 https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    if [ -f add_turboacc.sh ]; then
        bash add_turboacc.sh --no-sfe
        rm -f add_turboacc.sh
    else
        echo -e "${RED}❌ 无法下载外部脚本，kmod-nft-fullcone 可能缺失${NC}"
    fi
fi

# 确保 kmod-nft-fullcone 存在
if [ ! -d package/kmod-nft-fullcone ]; then
    echo -e "${RED}❌ 无法获取 kmod-nft-fullcone，编译可能失败${NC}"
    exit 1
fi

# =========================================================
# 4. 修复补丁目录（避免 generic/patches 报错）
# =========================================================
if [ -d target/linux/generic/patches ]; then
    echo -e "${BLUE}检测到旧目录 target/linux/generic/patches，正在迁移...${NC}"
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 补丁目录修复完成${NC}"
fi

# =========================================================
# 5. 同步 sysctl 配置
# =========================================================
echo -e "${BLUE}同步你的 sysctl-nf-conntrack.conf...${NC}"
mkdir -p files/etc/sysctl.d
if curl -fsSL --connect-timeout 10 --retry 3 "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf; then
    echo -e "${GREEN}✅ 已同步你的 sysctl 配置${NC}"
else
    echo -e "${RED}⚠️  sysctl 下载失败，请检查 raw 链接分支是否为 main${NC}"
fi

# =========================================================
# 6. 注入 CPUFreq 调频内核配置
# =========================================================
echo -e "${BLUE}注入 Airoha CPUFreq 调频内核配置...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-*" | head -1)
if [ -n "$CFG_FILE" ]; then
    echo "操作文件: $CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ_STAT/d' "$CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ CPUFreq 内核驱动注入成功${NC}"
else
    echo -e "${RED}⚠️  未找到内核配置文件，注入失败${NC}"
fi

# =========================================================
# 7. 生成基础配置
# =========================================================
make defconfig

# =========================================================
# 8. 锁定编译选项
# =========================================================
add_config "CONFIG_PACKAGE_busybox"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt"
add_config "CONFIG_PACKAGE_kmod-fast-classifier=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-cm=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-drv=n"
add_config "CONFIG_PACKAGE_luci-app-upnp"
add_config "CONFIG_PACKAGE_luci-app-natmap"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn"
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"

# =========================================================
# 9. 运行时初始化
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

# =========================================================
# 10. 最终同步与配置固化
# =========================================================
./scripts/feeds update -i
./scripts/feeds install -a
make oldconfig

echo -e "${GREEN}🎉 [ALL SUCCESS]XG-040G-MD 编译环境已完美就绪！${NC}"
