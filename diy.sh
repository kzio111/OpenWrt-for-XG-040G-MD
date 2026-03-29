#!/bin/bash
set -e

# 颜色
GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
NC='\033[0m'

# 捕获错误：如果某步失败，打印红色提示并退出
trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}[1/7] 更新 Feeds 并清理冲突...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a
echo -e "${GREEN}✅ [1/7] Feeds 更新与冲突清理完成${NC}"

# =========================================================
# 2. 从你的仓库提取 NPU 插件 (kzio111)
# =========================================================
echo -e "${BLUE}[2/7] 提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
[ -d "package/temp_npu/package/luci-app-airoha-npu" ] && cp -r package/temp_npu/package/luci-app-airoha-npu package/
rm -rf package/temp_npu
echo -e "${GREEN}✅ [2/7] Airoha NPU 插件提取完成${NC}"

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/7] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ [3/7] Aurora 主题提取完成${NC}"

# =========================================================
# 4. TurboAcc 集成（只让脚本看到 6.12，避免 6.18 导致退出）
# =========================================================
echo -e "${BLUE}[4/7] 下载并运行 TurboAcc 官方集成脚本（仅针对 6.12）...${NC}"

# 临时屏蔽 6.18，让脚本只识别到 6.12
if [ -e target/linux/generic/kernel-6.18 ]; then
  mv target/linux/generic/kernel-6.18 target/linux/generic/kernel-6.18.bak
fi
if [ -e target/linux/generic/config-6.18 ]; then
  mv target/linux/generic/config-6.18 target/linux/generic/config-6.18.bak
fi

# 执行官方脚本（--no-sfe 避免引入 SFE）
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# 恢复 6.18 相关文件，不影响你以后的构建
if [ -e target/linux/generic/kernel-6.18.bak ]; then
  mv target/linux/generic/kernel-6.18.bak target/linux/generic/kernel-6.18
fi
if [ -e target/linux/generic/config-6.18.bak ]; then
  mv target/linux/generic/config-6.18.bak target/linux/generic/config-6.18
fi

echo -e "${GREEN}✅ [4/7] TurboAcc 集成完成（仅 6.12）${NC}"

# =========================================================
# 5. 同步你的 sysctl 优化配置
# =========================================================
echo -e "${BLUE}[5/7] 同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf
echo -e "${GREEN}✅ [5/7] sysctl 配置同步完成${NC}"

# =========================================================
# 6. 注入 CPUFreq 驱动 (修复频率显示)
# =========================================================
echo -e "${BLUE}[6/7] 注入 CPUFreq 驱动...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ [6/7] CPUFreq 驱动注入完成${NC}"
else
    echo -e "${RED}❌ [6/7] 未找到 config-6.12 文件，跳过注入${NC}"
fi

# =========================================================
# 7. 配置锁定与初始化
# =========================================================
echo -e "${BLUE}[7/7] 锁定配置与初始化...${NC}"
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

echo -e "${GREEN}✅ [7/7] 配置锁定与初始化完成${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
echo -e "${GREEN}🎉 [OK] 所有脚本步骤均已成功执行完毕！${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
