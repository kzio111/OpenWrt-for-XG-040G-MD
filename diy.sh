#!/bin/bash
set -e

# 颜色
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
[ -d "package/temp_npu/package/luci-app-airoha-npu" ] && cp -r package/temp_npu/package/luci-app-airoha-npu package/
rm -rf package/temp_npu

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

# =========================================================
# 4. TurboAcc 集成 (直接使用官方脚本，不额外干预补丁目录)
# =========================================================
echo -e "${BLUE}下载并运行 TurboAcc 官方集成脚本...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# =========================================================
# 5. 同步你的 sysctl 优化配置
# =========================================================
echo -e "${BLUE}同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf

# =========================================================
# 6. 注入 CPUFreq 驱动 (修复频率显示)
# =========================================================
echo -e "${BLUE}注入 CPUFreq 驱动...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ 6.12 CPU频率驱动已注入${NC}"
fi

# =========================================================
# 7. 配置锁定与初始化
# =========================================================
echo -e "${BLUE}锁定配置与初始化...${NC}"
make defconfig

add_config() { sed -i "/^$1=/d" .config && echo "$1=y" >> .config; }

add_config "CONFIG_PACKAGE_luci-app-airoha-npu"
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"

# 强制默认主题为 Aurora 与中文环境
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

echo -e "${GREEN}🎉 [OK] 脚本全部执行完毕，配置已锁定。${NC}"
