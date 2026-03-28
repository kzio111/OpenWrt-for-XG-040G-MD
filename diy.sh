#!/bin/bash
set -e
# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并清理冲突包...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除冲突包 fwupd${NC}"
./scripts/feeds install -a

# =========================================================
# 2. 拉取 NPU 插件 (从你的仓库 kzio111)
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo
find package/temp_repo -type d -name "luci-app-airoha-npu" -exec mv {} package/ \;
rm -rf package/temp_repo && echo -e "${GREEN}✅ NPU 插件拉取成功${NC}"

# =========================================================
# 3. 拉取 Aurora 主题 (补全部分)
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

# 补丁位置修正 (适配 6.12 内核)
if [ -d "target/linux/generic/patches" ]; then
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 内核补丁迁移完成${NC}"
fi

# =========================================================
# 5. 直接使用你仓库的 .conf 配置文件
# =========================================================
echo -e "${BLUE}同步你的 sysctl-nf-conntrack.conf...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf

# =========================================================
# 6. 注入 CPUFreq 内核支持 (修复频率 N/A)
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
add_config "CONFIG_PACKAGE_luci-theme-aurora"   # 锁定 Aurora 主题
add_config "CONFIG_LUCI_LANG_zh_Hans"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn"

# =========================================================
# 8. 运行时初始化与默认主题设置
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'   # 强制首次启动使用 aurora
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

./scripts/feeds update -i
./scripts/feeds install -a
make oldconfig

echo -e "${GREEN}🎉 [OK] Aurora 主题已添加，环境完美。${NC}"
