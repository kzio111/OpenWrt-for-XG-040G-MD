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
# 1. 【核心：防锁死注入】必须在所有 make 命令之前执行
# =========================================================
echo -e "${BLUE}[1/9] 注入内核防锁死配置 (CPUFreq 路径修复)...${NC}"

# 自动探测正确的内核配置文件路径
if [ -f "target/linux/airoha/an7581/config-6.12" ]; then
    CFG_FILE="target/linux/airoha/an7581/config-6.12"
elif [ -f "target/linux/airoha/config-6.12" ]; then
    CFG_FILE="target/linux/airoha/config-6.12"
else
    CFG_FILE=""
fi

if [ -n "$CFG_FILE" ]; then
    # 彻底清理旧项，防止重复写入导致冲突
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    
    # 注入全量调度器参数，堵住内核的 choice[1-6?] 询问
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_CPU_FREQ_GOV_POWERSAVE=y
CONFIG_CPU_FREQ_GOV_USERSPACE=y
CONFIG_CPU_FREQ_GOV_ONDEMAND=y
CONFIG_CPU_FREQ_GOV_CONSERVATIVE=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_ARM_AIROHA_CPUFREQ=y
CONFIG_CPUFREQ_DT=y
CONFIG_ENERGY_MODEL=y
EOF
    echo -e "${GREEN}✅ 内核全量配置已注入: $CFG_FILE${NC}"
else
    echo -e "${RED}❌ 路径探测失败，请检查源码结构！${NC}"
fi

# =========================================================
# 2. 更新 Feeds
# =========================================================
echo -e "${BLUE}[2/9] 更新 Feeds...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd
./scripts/feeds install -a
echo -e "${GREEN}✅ Feeds 更新完成${NC}"

# =========================================================
# 3. 提取 NPU 插件并修复 Makefile
# =========================================================
echo -e "${BLUE}[3/9] 提取 Airoha NPU 插件并修复 Makefile...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_npu/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件提取完成${NC}"
fi
rm -rf package/temp_npu

MAKEFILE="package/luci-app-airoha-npu/Makefile"
if [ -f "$MAKEFILE" ]; then
    sed -i 's/LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+luci-base +busybox @TARGET_airoha/' "$MAKEFILE"
    if ! grep -q "chmod 0755" "$MAKEFILE"; then
        sed -i '/define Package\/luci-app-airoha-npu\/install/,/endef/ s/$(call LuCI\/Install.*/&\n\tchmod 0755 $(1)\/usr\/libexec\/rpcd\/luci.airoha_npu/' "$MAKEFILE"
    fi
fi

# =========================================================
# 4. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[4/9] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora

# =========================================================
# 5. 集成 TurboAcc
# =========================================================
echo -e "${BLUE}[5/9] 集成 TurboAcc...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh
bash add_turboacc.sh --no-sfe
rm -f add_turboacc.sh

# =========================================================
# 6. 同步 sysctl 优化配置
# =========================================================
echo -e "${BLUE}[6/9] 同步 sysctl 配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf

# =========================================================
# 7. 添加 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[7/9] 添加 MAC 固定脚本...${NC}"
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

# =========================================================
# 8. 配置锁定 (zRAM + Natmap + UPnP)
# =========================================================
echo -e "${BLUE}[8/9] 锁定 .config 配置 (zRAM/Natmap/UPnP)...${NC}"
make defconfig

# 强制开启 devmem
for opt in BUSYBOX_CUSTOM BUSYBOX_CONFIG_DEVMEM KERNEL_DEVMEM; do
    sed -i "/CONFIG_${opt}/d" .config
    echo "CONFIG_${opt}=y" >> .config
done

# 添加新增的软件包
PKGS="luci-app-airoha-npu luci-app-turboacc kmod-nft-fullcone luci-theme-aurora cpufrequtils \
      zram-config luci-app-zram \
      natmap luci-app-natmap \
      miniupnpd luci-app-upnp"

for pkg in $PKGS; do
    sed -i "/CONFIG_PACKAGE_${pkg}/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done

echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config

# 再次使用 yes "" 确保 oldconfig 也是非交互的
yes "" | make oldconfig

# =========================================================
# 9. 最终初始化
# =========================================================
echo -e "${BLUE}[9/9] 最终初始化...${NC}"
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
make defconfig

echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
echo -e "${GREEN}🎉 防锁死代码已前置！CPU 调频与新增功能集成完毕。${NC}"
echo -e "${GREEN}🎉 --------------------------------------------------${NC}"
