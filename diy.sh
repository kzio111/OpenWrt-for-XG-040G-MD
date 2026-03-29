#!/bin/bash
set -e

GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}[1/10] 更新 Feeds 并清理冲突...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a
echo -e "${GREEN}✅ [1/10] Feeds 更新与冲突清理完成${NC}"

# =========================================================
# 2. 提取 NPU 插件
# =========================================================
echo -e "${BLUE}[2/10] 提取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_npu/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ [2/10] Airoha NPU 插件提取完成${NC}"
else
    echo -e "${RED}❌ [2/10] 未找到 NPU 插件目录，跳过${NC}"
fi
rm -rf package/temp_npu

# =========================================================
# 3. 修改 NPU 插件 Makefile
# =========================================================
echo -e "${BLUE}[3/10] 修改 luci-app-airoha-npu 的 Makefile...${NC}"
MAKEFILE="package/luci-app-airoha-npu/Makefile"
if [ -f "$MAKEFILE" ]; then
    cp "$MAKEFILE" "$MAKEFILE.bak"
    cat > "$MAKEFILE" << 'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-airoha-npu
PKG_VERSION:=1.0.2
PKG_RELEASE:=3

PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Airoha NPU Status
LUCI_DEPENDS:=+luci-base +busybox @TARGET_airoha

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-airoha-npu/install
    $(call LuCI/Install,$(1),luci-app-airoha-npu)
    chmod 0755 $(1)/usr/libexec/rpcd/luci.airoha_npu
endef

# call BuildPackage - OpenWrt buildroot signature
EOF
    echo -e "${GREEN}✅ [3/10] Makefile 修改完成（依赖 +busybox，安装时 chmod 0755）${NC}"
else
    echo -e "${RED}❌ [3/10] 未找到 Makefile，跳过${NC}"
fi

# =========================================================
# 4. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[4/10] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ [4/10] Aurora 主题提取完成${NC}"

# =========================================================
# 5. TurboAcc 集成
# =========================================================
echo -e "${BLUE}[5/10] 下载并运行 TurboAcc 官方集成脚本...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh
echo -e "${GREEN}✅ [5/10] TurboAcc 集成完成${NC}"

# =========================================================
# 6. 同步 sysctl 配置
# =========================================================
echo -e "${BLUE}[6/10] 同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf
echo -e "${GREEN}✅ [6/10] sysctl 配置同步完成${NC}"

# =========================================================
# 7. 注入 CPUFreq 驱动（内核配置）
# =========================================================
echo -e "${BLUE}[7/10] 注入 CPUFreq 驱动...${NC}"
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
CONFIG_CPU_FREQ_DT=y
CONFIG_ARM_SCMI_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ [7/10] CPUFreq 驱动注入完成${NC}"
else
    echo -e "${RED}❌ [7/10] 未找到 config-6.12 文件，跳过${NC}"
fi

# =========================================================
# 8. 添加首次启动 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[8/10] 添加首次启动 MAC 固定脚本...${NC}"
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
echo -e "${GREEN}✅ [8/10] MAC 固定脚本已添加${NC}"

# =========================================================
# 9. 配置锁定（安全模式：只启用必定存在的选项）
# =========================================================
echo -e "${BLUE}[9/10] 锁定关键配置...${NC}"
make defconfig

# 强制添加 busybox devmem（必定存在）
sed -i '/CONFIG_BUSYBOX_CONFIG_DEVMEM/d' .config
echo "CONFIG_BUSYBOX_CONFIG_DEVMEM=y" >> .config

# 添加 cpufrequtils 和 devmem2（如果源中没有，不会导致失败）
echo "CONFIG_PACKAGE_cpufrequtils=y" >> .config
echo "CONFIG_PACKAGE_devmem2=y" >> .config

# 添加 LuCI 相关包
for pkg in luci-app-airoha-npu luci-app-turboacc kmod-nft-fullcone luci-theme-aurora; do
    sed -i "/CONFIG_PACKAGE_${pkg}/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

# 中文语言
sed -i '/CONFIG_LUCI_LANG_zh_Hans/d' .config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config

make oldconfig

echo -e "${GREEN}✅ [9/10] 配置锁定完成（busybox devmem 已启用，cpufrequtils 和 devmem2 已尝试添加）${NC}"

# =========================================================
# 10. 最终确认
# =========================================================
echo -e "${BLUE}[10/10] 最终配置确认与初始化...${NC}"
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
make defconfig

echo -e "${GREEN}✅ [10/10] 所有步骤完成，配置已固化${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
echo -e "${GREEN}🎉 [OK] 固件编译准备就绪${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
