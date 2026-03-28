#!/bin/bash
set -e

# 颜色定义
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
YELLOW='\033[33m'
NC='\033[0m'

# 辅助函数：配置注入
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    echo "$1=y" >> .config
}

# =========================================================
# 1. 环境准备与 Feed 清理
# =========================================================
echo -e "${BLUE}开始更新 Feeds 并清理冲突包...${NC}"
./scripts/feeds update -a
rm -rf feeds/packages/utils/fwupd && echo -e "${GREEN}✅ 已移除冲突包 fwupd${NC}"
./scripts/feeds install -a

# =========================================================
# 2. 拉取 NPU 插件（从你的仓库）
# =========================================================
echo -e "${BLUE}正在从你的仓库拉取 Airoha NPU 插件...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_repo
if [ -d "package/temp_repo/package/luci-app-airoha-npu" ]; then
    mv package/temp_repo/package/luci-app-airoha-npu package/
    echo -e "${GREEN}✅ NPU 插件拉取成功${NC}"
else
    npu_dir=$(find package/temp_repo -type d -name "luci-app-airoha-npu" -print -quit)
    if [ -n "$npu_dir" ]; then
        mv "$npu_dir" package/
        echo -e "${GREEN}✅ NPU 插件拉取成功 (从子目录)${NC}"
    else
        echo -e "${RED}❌ NPU 插件拉取失败，请检查仓库目录结构${NC}"
        exit 1
    fi
fi
rm -rf package/temp_repo

# =========================================================
# 3. 拉取 Aurora 主题
# =========================================================
echo -e "${BLUE}拉取 Aurora 主题...${NC}"
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora && echo -e "${GREEN}✅ Aurora 主题就绪${NC}"

# =========================================================
# 4. TurboAcc 组件：直接从 chenmozhijin/turboacc 仓库下载并提取
# =========================================================
echo -e "${BLUE}从 chenmozhijin/turboacc 仓库下载 TurboAcc 组件...${NC}"
rm -rf package/luci-app-turboacc package/kmod-nft-fullcone 2>/dev/null || true

# 下载仓库压缩包（luci 分支）
TURBO_REPO_URL="https://github.com/chenmozhijin/turboacc/archive/refs/heads/luci.tar.gz"
curl -fsSL --connect-timeout 10 --retry 3 -L "$TURBO_REPO_URL" -o turboacc.tar.gz || {
    echo -e "${RED}❌ 下载 TurboAcc 源码失败${NC}"
    exit 1
}

# 解压到临时目录
mkdir -p tmp_turboacc
tar -xzf turboacc.tar.gz -C tmp_turboacc
cd tmp_turboacc

# 提取 luci-app-turboacc 和 nft-fullcone
# 注意：仓库可能将包放在 package/ 目录下
if [ -d "package/luci-app-turboacc" ]; then
    cp -r package/luci-app-turboacc ../package/
fi
if [ -d "package/nft-fullcone" ]; then
    cp -r package/nft-fullcone ../package/
fi
# 也可能直接放在根目录
if [ -d "luci-app-turboacc" ]; then
    cp -r luci-app-turboacc ../package/
fi
if [ -d "nft-fullcone" ]; then
    cp -r nft-fullcone ../package/
fi

cd ..
rm -rf tmp_turboacc turboacc.tar.gz

# 重命名 nft-fullcone 为 kmod-nft-fullcone
if [ -d package/nft-fullcone ] && [ ! -d package/kmod-nft-fullcone ]; then
    mv package/nft-fullcone package/kmod-nft-fullcone
fi

# 删除 SFE 依赖
if [ -f package/luci-app-turboacc/Makefile ]; then
    sed -i '/kmod-fast-classifier/d' package/luci-app-turboacc/Makefile
    sed -i '/kmod-shortcut-fe/d' package/luci-app-turboacc/Makefile
fi

# 确保两个包都存在
[ -d package/luci-app-turboacc ] && [ -d package/kmod-nft-fullcone ] || {
    echo -e "${RED}❌ 无法获取 TurboAcc 组件，请检查仓库结构${NC}"
    exit 1
}
echo -e "${GREEN}✅ TurboAcc 组件下载成功${NC}"

# =========================================================
# 5. 修复补丁目录（避免 generic/patches 报错）
# =========================================================
if [ -d target/linux/generic/patches ]; then
    echo -e "${BLUE}检测到旧目录 target/linux/generic/patches，正在迁移...${NC}"
    mkdir -p target/linux/generic/pending-6.12
    cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null || true
    rm -rf target/linux/generic/patches
    echo -e "${GREEN}✅ 补丁目录修复完成${NC}"
fi

# =========================================================
# 6. 同步 sysctl 配置
# =========================================================
echo -e "${BLUE}同步你的 sysctl-nf-conntrack.conf...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL --connect-timeout 10 --retry 3 "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" -o files/etc/sysctl.d/sysctl-nf-conntrack.conf && echo -e "${GREEN}✅ 已同步你的 sysctl 配置${NC}" || echo -e "${RED}⚠️  sysctl 下载失败${NC}"

# =========================================================
# 7. 注入 CPUFreq 调频内核配置
# =========================================================
echo -e "${BLUE}注入 Airoha CPUFreq 调频内核配置...${NC}"
CFG_FILE=$(find target/linux/airoha/ -name "config-*" | head -1)
if [ -n "$CFG_FILE" ]; then
    echo "操作文件: $CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ/d' "$CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ_STAT/d' "$CFG_FILE"
    sed -i '/CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND/d' "$CFG_FILE"
    sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_ARM_AIROHA_CPUFREQ=y
EOF
    echo -e "${GREEN}✅ CPUFreq 内核驱动注入成功${NC}"
else
    echo -e "${RED}⚠️  未找到内核配置文件，注入失败${NC}"
fi

# =========================================================
# 8. 生成基础配置
# =========================================================
make defconfig

# =========================================================
# 9. 锁定编译选项
# =========================================================
add_config "CONFIG_PACKAGE_busybox"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM"
add_config "CONFIG_PACKAGE_luci-app-airoha-npu"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt"
add_config "CONFIG_PACKAGE_kmod-fast-classifier=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-cm=n"
add_config "CONFIG_PACKAGE_kmod-shortcut-fe-drv=n"
add_config "CONFIG_PACKAGE_luci-app-upnp"
add_config "CONFIG_PACKAGE_luci-app-natmap"
add_config "CONFIG_PACKAGE_luci-theme-aurora"
add_config "CONFIG_LUCI_LANG_zh_Hans"
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn"
add_config "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn"
add_config "CONFIG_PACKAGE_luci-app-turboacc"
add_config "CONFIG_PACKAGE_kmod-nft-fullcone"

# =========================================================
# 10. 运行时初始化
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

# =========================================================
# 11. 最终同步与配置固化
# =========================================================
./scripts/feeds update -i
./scripts/feeds install -a
make oldconfig

echo -e "${GREEN}🎉 [ALL SUCCESS] XG-040G-MD 编译环境已完美就绪！${NC}"
