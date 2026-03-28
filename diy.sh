#!/bin/bash
set -e
# =========================================================
# 1. 环境准备与【强制锁定 6.12】
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并强制清理 6.18 干扰项...${NC}"
./scripts/feeds update -a

# 彻底删除 6.18 的内核补丁目录，强制源码只看 6.12
rm -rf target/linux/generic/pending-6.18
rm -rf target/linux/generic/patches-6.18
rm -rf target/linux/airoha/config-6.18

# 移除冲突包
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除 6.18 干扰项及冲突包${NC}"
./scripts/feeds install -a

# =========================================================
# 2. 从你的仓库精准拉取 NPU 插件 (kzio111)
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo
if [ -d "package/temp_repo/package/luci-app-airoha-npu" ]; then
    cp -r package/temp_repo/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件提取成功${NC}"
else
    echo -e "${RED}❌ 仓库路径错误${NC}"
    exit 1
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取 Aurora 主题
# =========================================================
echo -e "${BLUE}正在拉取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
echo -e "${GREEN}✅ Aurora 主题拉取成功${NC}"

# =========================================================
# 4. 集成 TurboAcc (此时脚本只会看到 6.12)
# =========================================================
echo -e "${BLUE}执行 TurboAcc 集成脚本 (此时应检测为 6.12)...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
# 即使脚本支持 6.12，我们也加个判断，防止它万一还是报错
bash add_turboacc.sh --no-sfe || echo -e "${RED}脚本执行失败，请检查是否仍检测到多版本${NC}"
rm -f add_turboacc.sh

# 修正补丁路径至 pending-6.12
if [ -d "target/linux/generic/patches" ]; then
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 6.12 内核补丁迁移完成${NC}"
fi

# =========================================================
# 5. 同步你的 sysctl 配置文件
# =========================================================
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf

# =========================================================
# 6. 注入 CPUFreq 驱动 (锁定 6.12)
# =========================================================
CFG_FILE="target/linux/airoha/config-6.12"
if [ -f "$CFG_FILE" ]; then
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    echo "" >> "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ 6.12 CPUFreq 驱动注入成功${NC}"
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

echo -e "${GREEN}🎉 6.18 已被强制剔除，环境锁定为 6.12，开始编译吧！${NC}"
