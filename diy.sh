#!/bin/bash
set -e

GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 0. 复制种子配置（如果尚未复制）
# =========================================================
if [ ! -f .config ]; then
    if [ -f "../config/xg-040g-md.config" ]; then
        cp -fv "../config/xg-040g-md.config" .config
        echo -e "${GREEN}✅ 已复制种子配置文件${NC}"
    else
        echo -e "${YELLOW}⚠️ 未找到种子配置文件，请确保已准备就绪${NC}"
    fi
fi

# =========================================================
# 1. 更新 Feeds
# =========================================================
echo -e "${BLUE}[1/8] 更新 Feeds...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a
echo -e "${GREEN}✅ Feeds 更新完成${NC}"

# =========================================================
# 2. 提取 NPU 插件并修复 Makefile
# =========================================================
echo -e "${BLUE}[2/8] 提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_npu/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件提取完成${NC}"
else
    echo -e "${RED}❌ 未找到 NPU 插件目录，跳过${NC}"
    exit 1
fi
rm -rf package/temp_npu

echo -e "${BLUE}修复 Makefile（添加 busybox 依赖和安装权限）...${NC}"
MAKEFILE="package/luci-app-airoha-npu/Makefile"
if [ -f "$MAKEFILE" ]; then
    # 修改依赖行
    sed -i 's/LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+luci-base +busybox @TARGET_airoha/' "$MAKEFILE"
    # 确保 install 段包含 chmod
    if ! grep -q "chmod 0755" "$MAKEFILE"; then
        sed -i '/define Package\/luci-app-airoha-npu\/install/,/endef/ s/$(call LuCI\/Install.*/&\n\tchmod 0755 $(1)\/usr\/libexec\/rpcd\/luci.airoha_npu/' "$MAKEFILE"
    fi
    echo -e "${GREEN}✅ Makefile 已修复${NC}"
else
    echo -e "${RED}❌ Makefile 不存在，请检查插件结构${NC}"
    exit 1
fi

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/8] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ Aurora 主题提取完成${NC}"

# =========================================================
# 4. TurboAcc 集成（跳过内核版本不匹配）
# =========================================================
echo -e "${BLUE}[4/8] 集成 TurboAcc...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh
echo -e "${GREEN}✅ TurboAcc 集成完成${NC}"

# =========================================================
# 5. 同步 sysctl 优化配置
# =========================================================
echo -e "${BLUE}[5/8] 同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf
echo -e "${GREEN}✅ sysctl 配置同步完成${NC}"

# =========================================================
# 6. 注入 CPUFreq 驱动（内核配置）
# =========================================================
echo -e "${BLUE}[6/8] 注入 CPUFreq 驱动...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-6.12" | head -1)
if [ -n "$CFG_FILE" ]; then
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
CONFIG_CPU_FREQ_DT=y
CONFIG_ARM_SCMI_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ CPUFreq 驱动注入完成${NC}"
else
    echo -e "${YELLOW}⚠️ 未找到 config-6.12，跳过${NC}"
fi

# =========================================================
# 7. 添加首次启动 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[7/8] 添加 MAC 固定脚本...${NC}"
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
echo -e "${GREEN}✅ MAC 固定脚本已添加${NC}"

# =========================================================
# 8. 锁定配置（强制启用 devmem、cpufreq 等）
# =========================================================
echo -e "${BLUE}[8/8] 锁定关键配置...${NC}"
make defconfig

# 强制启用 busybox 自定义模式（devmem 的前提）
sed -i '/CONFIG_BUSYBOX_CUSTOM/d' .config
echo "CONFIG_BUSYBOX_CUSTOM=y" >> .config

# 启用 busybox devmem
sed -i '/CONFIG_BUSYBOX_CONFIG_DEVMEM/d' .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config

# 确保内核 /dev/mem 支持
sed -i '/CONFIG_KERNEL_DEVMEM/d' .config
echo "CONFIG_KERNEL_DEVMEM=y" >> .config

# 勾选 cpufrequtils 包（如果源中存在）
sed -i '/CONFIG_PACKAGE_cpufrequtils/d' .config
echo "CONFIG_PACKAGE_cpufrequtils=y" >> .config

# 勾选必须的 LuCI 包
for pkg in luci-app-airoha-npu luci-app-turboacc kmod-nft-fullcone luci-theme-aurora; do
    sed -i "/CONFIG_PACKAGE_${pkg}/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 中文语言
sed -i '/CONFIG_LUCI_LANG_zh_Hans/d' .config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config

# 重新生成配置（保留我们的设置）
make oldconfig

# 验证 devmem 是否成功启用
if grep -q "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" .config; then
    echo -e "${GREEN}✅ busybox devmem 已成功启用${NC}"
else
    echo -e "${RED}❌ busybox devmem 启用失败，请检查依赖${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 配置锁定完成${NC}"

# =========================================================
# 9. 最终初始化（默认主题/语言）
# =========================================================
echo -e "${BLUE}最终初始化...${NC}"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings << 'EOF'
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

./scripts/feeds update -i
./scripts/feeds install -a
make defconfig

echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
echo -e "${GREEN}🎉 所有步骤完成，固件已准备就绪！${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
