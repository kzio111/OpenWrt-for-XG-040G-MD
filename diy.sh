#!/bin/bash
set -e

# 颜色定义
GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
NC='\033[0m'

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}更新 Feeds 并清理冲突...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a

# =========================================================
# 2. 从你的仓库提取 NPU 插件 (kzio111)
# =========================================================
echo -e "${BLUE}提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
# 物理对应你的仓库路径：package/luci-app-airoha-npu
if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_npu/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件提取成功${NC}"
fi
rm -rf package/temp_npu

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

# =========================================================
# 4. 【核心】执行官方 TurboAcc 脚本 (带环境欺骗)
# =========================================================
echo -e "${BLUE}准备执行官方集成脚本...${NC}"

# 临时挪走 6.18 的干扰文件夹，防止脚本报 "Unsupported kernel version"
[ -d "target/linux/generic/pending-6.18" ] && mv target/linux/generic/pending-6.18 target/linux/generic/pending-6.18.bak
[ -d "target/linux/generic/patches-6.18" ] && mv target/linux/generic/patches-6.18 target/linux/generic/patches-6.18.bak

# 执行你指定的命令
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# 还原 6.18 文件夹（如果有的话）
[ -d "target/linux/generic/pending-6.18.bak" ] && mv target/linux/generic/pending-6.18.bak target/linux/generic/pending-6.18
[ -d "target/linux/generic/patches-6.18.bak" ] && mv target/linux/generic/patches-6.18.bak target/linux/generic/patches-6.18

# 【关键】脚本默认把 952 等补丁放在 patches/，在 6.12 下必须挪到 pending-6.12
if [ -d "target/linux/generic/patches" ]; then
    echo -e "${BLUE}同步脚本补丁至 6.12 目录...${NC}"
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 补丁路径适配完成${NC}"
fi

# =========================================================
# 5. 同步你的 sysctl 优化配置
# =========================================================
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf

# =========================================================
# 6. 注入 CPUFreq 驱动 (锁定 6.12)
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
fi

# =========================================================
# 7. 配置锁定
# =========================================================
make defconfig
add_config() { sed -i "/^$1=/d" .config && echo "$1=y" >> .config; }

add_config "CONFIG_PACKAGE_busybox"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu"
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"

# =========================================================
# 8. 运行时初始化
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

echo -e "${GREEN}🎉 脚本执行完毕，补丁已适配 6.12 环境。${NC}"
