#!/bin/bash
set -e

GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 0. 配置文件准备
# =========================================================
if [ ! -f .config ]; then
    if [ -f "../config/xg-040g-md.config" ]; then
        cp -fv "../config/xg-040g-md.config" .config
        echo -e "${GREEN}✅ 已复制种子配置文件${NC}"
    fi
fi

# =========================================================
# 1. 更新 Feeds
# =========================================================
echo -e "${BLUE}[1/7] 更新 Feeds...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a

# =========================================================
# 2. 提取 NPU 插件并修复 (保持原样)
# =========================================================
echo -e "${BLUE}[2/7] 提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
cp -r package/temp_npu/package/luci-app-airoha-npu package/
rm -rf package/temp_npu

sed -i 's/LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+luci-base +busybox @TARGET_airoha/' package/luci-app-airoha-npu/Makefile
if ! grep -q "chmod 0755" package/luci-app-airoha-npu/Makefile; then
    sed -i '/define Package\/luci-app-airoha-npu\/install/,/endef/ s/$(call LuCI\/Install.*/&\n\tchmod 0755 $(1)\/usr\/libexec\/rpcd\/luci.airoha_npu/' package/luci-app-airoha-npu/Makefile
fi

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/7] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

# =========================================================
# 4. 集成 TurboAcc
# =========================================================
echo -e "${BLUE}[4/7] 集成 TurboAcc...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# =========================================================
# 6. 锁定软件包配置 (整合 Devmem 与内核驱动)
# =========================================================
echo -e "${BLUE}[6/7] 正在锁定 Devmem、CPUFreq 及插件配置...${NC}"

# 1. 强制注入所有配置到 .config (包含 devmem 和 cpufreq)
cat >> .config <<EOF
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_DEVMEM=y
CONFIG_KERNEL_DEVMEM=y
CONFIG_PACKAGE_kmod-pwm-airoha=y
CONFIG_PACKAGE_kmod-cpufreq-dt=y
CONFIG_PACKAGE_kmod-cpufreq-ondemand=y
CONFIG_PACKAGE_kmod-cpufreq-performance=y
CONFIG_PACKAGE_cpufrequtils=y
CONFIG_PACKAGE_luci-app-airoha-npu=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_kmod-nft-fullcone=y
CONFIG_PACKAGE_luci-theme-aurora=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

# 2. 执行一次完整的依赖补全
make defconfig

# =========================================================
# 7. 最终初始化
# =========================================================
echo -e "${BLUE}[7/7] 最终初始化设置...${NC}"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings << 'EOF'
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

./scripts/feeds install -a
make oldconfig
echo -e "${GREEN}🎉 固件配置修复完成！${NC}"
