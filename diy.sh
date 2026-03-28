#!/bin/bash
set -e

# 颜色定义
GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
NC='\033[0m'

# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并清理冲突包...${NC}"
./scripts/feeds update -a
# 彻底移除可能导致编译中断的 fwupd
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除冲突包 fwupd${NC}"
./scripts/feeds install -a

# =========================================================
# 2. 从你的仓库精准拉取 NPU 插件 (kzio111)
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
# 临时克隆仓库
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo

# 物理对应：提取你仓库里 package/ 下的插件目录
if [ -d "package/temp_repo/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_repo/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件提取成功${NC}"
else
    echo -e "${RED}❌ 仓库路径错误，未找到 package/luci-app-airoha-npu${NC}"
    ls -R package/temp_repo
    exit 1
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取 Aurora 主题
# =========================================================
echo -e "${BLUE}正在拉取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ Aurora 主题拉取成功${NC}"

# =========================================================
# 4. 集成 TurboAcc (支持 25.12)
# =========================================================
echo -e "${BLUE}执行 TurboAcc 集成脚本 (no-sfe)...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# 【核心修复】将 TurboAcc 生成的补丁迁移至 6.12 兼容目录
if [ -d "target/linux/generic/patches" ]; then
    echo -e "${BLUE}正在适配 6.12 内核补丁路径...${NC}"
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 补丁迁移完成${NC}"
fi

# =========================================================
# 5. 直接同步你仓库的 .conf 配置文件
# =========================================================
echo -e "${BLUE}同步你的 sysctl-nf-conntrack.conf...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf
echo -e "${GREEN}✅ 配置文件已就绪${NC}"

# =========================================================
# 6. 注入 CPUFreq 驱动 (修复频率显示 N/A)
# =========================================================
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ CPUFreq 驱动已注入: $CFG_FILE${NC}"
fi

# =========================================================
# 7. 配置锁定 (.config)
# =========================================================
make defconfig

add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    echo "$1=y" >> .config
}

add_config "CONFIG_PACKAGE_busybox"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu"
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn"

# =========================================================
# 8. 运行时初始化 (默认主题与语言强制生效)
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

echo -e "${GREEN}🎉 [SUCCESS] 脚本执行完毕。NPU、TurboAcc 和 Aurora 已全部锁定。${NC}"
