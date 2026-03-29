#!/bin/bash
set -e

# 颜色
GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
NC='\033[0m'

# 捕获错误
trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}[1/8] 更新 Feeds 并清理冲突...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a
echo -e "${GREEN}✅ [1/8] Feeds 更新与冲突清理完成${NC}"

# =========================================================
# 2. 从你的仓库提取 NPU 插件 (kzio111)
# =========================================================
echo -e "${BLUE}[2/8] 提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_npu/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ [2/8] Airoha NPU 插件提取完成${NC}"
else
    echo -e "${RED}❌ [2/8] 未找到 NPU 插件目录，跳过${NC}"
fi
rm -rf package/temp_npu

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/8] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ [3/8] Aurora 主题提取完成${NC}"

# =========================================================
# 4. TurboAcc 集成（精准破解脚本，遇到 6.18 直接跳过）
# =========================================================
echo -e "${BLUE}[4/8] 下载并运行 TurboAcc 官方集成脚本...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh

# 精准破解：找到"Unsupported kernel version"这一行，把它下一行的 exit 1 替换为 continue
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh

bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh
echo -e "${GREEN}✅ [4/8] TurboAcc 集成完成${NC}"

# =========================================================
# 5. 同步你的 sysctl 优化配置
# =========================================================
echo -e "${BLUE}[5/8] 同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf
echo -e "${GREEN}✅ [5/8] sysctl 配置同步完成${NC}"

# =========================================================
# 6. 注入 CPUFreq 驱动（修复频率显示，添加完整 cpufreq 支持）
# =========================================================
echo -e "${BLUE}[6/8] 注入 CPUFreq 驱动...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
# CPUFreq support
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_CPU_FREQ_GOV_USERSPACE=y
CONFIG_CPU_FREQ_GOV_ONDEMAND=y
CONFIG_CPU_FREQ_GOV_CONSERVATIVE=y
CONFIG_ARM_AIROHA_CPUFREQ=y
# 确保 cpufreq 驱动可加载
CONFIG_CPU_FREQ_DT=y
CONFIG_ARM_SCMI_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ [6/8] CPUFreq 驱动注入完成${NC}"
else
    echo -e "${RED}❌ [6/8] 未找到 config-6.12 文件，跳过 cpufreq 注入${NC}"
fi
# =========================================================
# 6b. 确保 cpufreq 用户空间工具和完整驱动
# =========================================================
echo -e "${BLUE}[6b/10] 启用 cpufreq 用户空间工具...${NC}"
# 添加 cpufrequtils 包
echo "CONFIG_PACKAGE_cpufrequtils=y" >> .config
# 确保 cpufreq 驱动选项完整（针对 airoha）
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
    # 追加驱动选项（如果之前未添加）
    grep -q "CONFIG_ARM_AIROHA_CPUFREQ" "$CFG_FILE" || echo "CONFIG_ARM_AIROHA_CPUFREQ=y" >> "$CFG_FILE"
    grep -q "CONFIG_CPU_FREQ_DT" "$CFG_FILE" || echo "CONFIG_CPU_FREQ_DT=y" >> "$CFG_FILE"
    echo -e "${GREEN}✅ [6b/10] cpufreq 驱动已强化${NC}"
else
    echo -e "${RED}❌ [6b/10] 未找到 config-6.12 文件，跳过 cpufreq 驱动强化${NC}"
fi
# =========================================================
# 7. 启用 devmem（超频所需）
# =========================================================
echo -e "${BLUE}[7/8] 启用 devmem 支持...${NC}"
if grep -q "CONFIG_BUSYBOX_CONFIG_DEVMEM" .config; then
    sed -i 's/^#\?CONFIG_BUSYBOX_CONFIG_DEVMEM.*/CONFIG_BUSYBOX_CONFIG_DEVMEM=y/' .config
else
    echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config
fi
echo -e "${GREEN}✅ [7/8] devmem 已启用${NC}"

# =========================================================
# 8. 添加首次启动 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[8/8] 添加首次启动 MAC 固定脚本...${NC}"
mkdir -p files/etc/init.d
cat > files/etc/init.d/fix-mac << 'EOF'
#!/bin/sh /etc/rc.common
START=99

boot() {
    [ -f /etc/.mac_fixed ] && return 0

    gen_mac() {
        local mac=$(dd if=/dev/urandom bs=1 count=6 2>/dev/null | hexdump -n 6 -e '6/1 "%02x:"' | sed 's/:$//')
        mac=$(printf "%02x:%s" $((0x${mac%%:*} | 0x02)) "${mac#*:}")
        echo "$mac"
    }

    . /lib/functions/uci-defaults.sh
    for iface in $(uci show network | grep '=interface' | cut -d. -f2 | cut -d= -f1); do
        if [ -z "$(uci get network.$iface.macaddr 2>/dev/null)" ]; then
            uci set network.$iface.macaddr="$(gen_mac)"
        fi
    done
    uci commit network
    /etc/init.d/network restart >/dev/null 2>&1 &
    touch /etc/.mac_fixed
}
EOF
chmod +x files/etc/init.d/fix-mac
echo -e "${GREEN}✅ [8/8] MAC 固定脚本已添加${NC}"

# =========================================================
# 9. 配置锁定与初始化（原第7步，现在作为第9步）
# =========================================================
echo -e "${BLUE}[9/9] 锁定配置与初始化...${NC}"
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

echo -e "${GREEN}✅ [9/9] 配置锁定与初始化完成${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
echo -e "${GREEN}🎉 [OK] 所有脚本步骤均已成功执行完毕！${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
