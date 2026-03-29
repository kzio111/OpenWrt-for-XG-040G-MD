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
# 5. 注入 CPUFreq 内核驱动 (修复重点)
# =========================================================
echo -e "${BLUE}[5/7] 注入 CPUFreq 内核支持...${NC}"
# 针对 Airoha 6.12 内核，必须确保驱动被静态编译进内核或作为强制模块
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    # 先清理可能存在的旧配置防止冲突
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_CPU_FREQ_GOV_ONDEMAND=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_ARM_AIROHA_CPUFREQ=y
CONFIG_CPU_FREQ_DT=y
EOF
    echo -e "${GREEN}✅ 内核 CPUFreq 驱动配置已注入${NC}"
fi

# =========================================================
# 6. 锁定软件包配置
# =========================================================
echo -e "${BLUE}[6/7] 锁定软件配置 (CPUFreq/Devmem)...${NC}"
make defconfig

# 强制开启 Busybox 工具 (devmem)
for opt in CONFIG_BUSYBOX_CUSTOM CONFIG_BUSYBOX_CONFIG_DEVMEM CONFIG_KERNEL_DEVMEM; do
    sed -i "/$opt/d" .config
    echo "$opt=y" >> .config
done

# 勾选 CPU 调频工具和网页界面
for pkg in cpufrequtils luci-app-cpufreq; do
    sed -i "/CONFIG_PACKAGE_${pkg}/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 勾选其他插件
for pkg in luci-app-airoha-npu luci-app-turboacc kmod-nft-fullcone luci-theme-aurora CONFIG_LUCI_LANG_zh_Hans; do
    # 兼容处理带 CONFIG_ 开头的和不带的
    key=$(echo $pkg | sed 's/^CONFIG_//')
    sed -i "/CONFIG_PACKAGE_${key}/d" .config
    echo "CONFIG_PACKAGE_${key}=y" >> .config
done

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
