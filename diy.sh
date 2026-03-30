#!/bin/bash
set -e

GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "${BLUE}▶  $1${NC}"; }

trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 0. 内核配置注入
# =========================================================
echo -e "${BLUE}[0/6] 正在注入内核配置 (an7581/config-6.12)...${NC}"
KERN_CFG="target/linux/airoha/an7581/config-6.12"
if [ ! -f "$KERN_CFG" ]; then
    fail "未找到目标内核配置文件：$KERN_CFG"
    exit 1
fi
ok "找到内核配置文件：$KERN_CFG"

# 清除旧 CPU_FREQ 相关行
sed -i '/CONFIG_CPU_FREQ/d' "$KERN_CFG"
sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$KERN_CFG"
ok "已清除旧的 CPU_FREQ 配置行"

# 注入新的内核配置
cat >> "$KERN_CFG" <<'EOF'
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
ok "CPU_FREQ 相关配置注入成功"

# 显式添加 UCLAMP_TASK 配置（避免后续编译时交互式询问）
if ! grep -q "UCLAMP_TASK" "$KERN_CFG"; then
    echo "# CONFIG_UCLAMP_TASK is not set" >> "$KERN_CFG"
    ok "已添加 UCLAMP_TASK 配置"
fi

# 全局配置初始化（一次 defconfig + olddefconfig）
info "执行 make defconfig ..."
make defconfig > /dev/null 2>&1 || fail "make defconfig 失败"
info "执行 make olddefconfig（自动接受所有新选项默认值）..."
make olddefconfig > /dev/null 2>&1 || warn "make olddefconfig 有警告"
ok "[0/6] 内核配置注入完成"

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}[1/6] 更新 Feeds 并清理 fwupd 冲突...${NC}"
if [ ! -f .config ] && [ -f "../config/xg-040g-md.config" ]; then
    cp -fv "../config/xg-040g-md.config" .config > /dev/null 2>&1 && ok "已复制种子配置文件" || fail "复制种子配置失败"
fi
./scripts/feeds update -a > /dev/null 2>&1 || warn "feeds update 有警告"
rm -rf feeds/packages/utils/fwupd && ok "fwupd 冲突目录已清理" || warn "fwupd 清理失败"
./scripts/feeds install -a > /dev/null 2>&1 || warn "feeds install 有警告"
ok "[1/6] Feeds 更新与清理完成"

# =========================================================
# 2. 提取 NPU 插件并修复 Makefile（使用 rchen14b 仓库）
# =========================================================
echo -e "${BLUE}[2/6] 提取 Airoha NPU 插件 (rchen14b)...${NC}"
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu > /dev/null 2>&1 || fail "NPU 仓库克隆失败"

MAKEFILE="package/luci-app-airoha-npu/Makefile"
if [ -f "$MAKEFILE" ]; then
    # 修复包含路径：指向 feeds 中的 luci.mk
    sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' "$MAKEFILE"
    # 修复依赖语法：@TARGET_airoha -> +TARGET_airoha:
    sed -i 's/@TARGET_airoha/+TARGET_airoha:/' "$MAKEFILE"
    ok "Makefile 已修复（包含路径和依赖语法）"
else
    warn "未找到 Makefile，跳过修复"
fi
ok "[2/6] NPU 插件提取与修复完成"

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/6] 提取 Aurora 主题...${NC}"
rm -rf package/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora > /dev/null 2>&1 || fail "Aurora 主题克隆失败"
ok "[3/6] Aurora 主题提取完成"

# =========================================================
# 4. 集成 TurboAcc
# =========================================================
echo -e "${BLUE}[4/6] 集成 TurboAcc...${NC}"
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh || fail "TurboAcc 脚本下载失败"
sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh
bash add_turboacc.sh --no-sfe > /dev/null 2>&1 || warn "TurboAcc 安装有警告"
rm -f add_turboacc.sh
ok "[4/6] TurboAcc 集成完成"

# =========================================================
# 5. 系统优化配置
# =========================================================
echo -e "${BLUE}[5/6] 系统优化配置...${NC}"
mkdir -p files/etc/sysctl.d
curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf || fail "sysctl 配置下载失败"
ok "[5/6] 系统优化配置完成"

# =========================================================
# 6. 添加 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[6/6] 添加 MAC 固定脚本...${NC}"
mkdir -p files/etc/init.d
cat > files/etc/init.d/fix-mac <<'EOF'
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
ok "[6/6] MAC 固定脚本添加完成"

# =========================================================
# 7. 配置锁定与最终同步（仅一次 defconfig + olddefconfig）
# =========================================================
echo -e "${BLUE}[7/7] 锁定 .config 配置并最终同步...${NC}"

# 强制开启 devmem
for opt in BUSYBOX_CUSTOM BUSYBOX_CONFIG_DEVMEM KERNEL_DEVMEM; do
    sed -i "/CONFIG_${opt}/d" .config
    echo "CONFIG_${opt}=y" >> .config
done
ok "devmem 相关配置锁定"

# 核心软件包锁定
PKGS="luci-app-airoha-npu luci-app-turboacc luci-theme-aurora cpufrequtils \
      zram-config luci-app-zram \
      natmap luci-app-natmap \
      miniupnpd luci-app-upnp \
      kmod-nft-fullcone"
for pkg in $PKGS; do
    sed -i "/CONFIG_PACKAGE_${pkg}/d" .config
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
done
ok "核心软件包锁定"

# 锁定语言
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config
ok "中文语言包锁定"

# uci-defaults 脚本
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<'EOF'
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# 最终 feeds install
./scripts/feeds install -a > /dev/null 2>&1 || warn "最终 feeds install 有警告"

# 最终配置同步（唯一一次 defconfig + olddefconfig）
info "最终同步配置..."
make defconfig > /dev/null 2>&1 || fail "最终 defconfig 失败"
make olddefconfig > /dev/null 2>&1 || warn "最终 olddefconfig 有警告"

# 可选：内核目录 olddefconfig 确保万无一失
KERN_DIR=$(ls -d build_dir/target-*/linux-airoha_an7581/linux-*/ 2>/dev/null | head -n1)
if [ -n "$KERN_DIR" ]; then
    info "在内核目录执行 olddefconfig..."
    make -C "$KERN_DIR" ARCH="arm64" olddefconfig V=0 > /dev/null 2>&1 && ok "内核 olddefconfig 成功" || warn "内核 olddefconfig 有警告"
fi

echo -e "${GREEN}🎉 脚本执行完毕！所有配置已就绪，可以直接运行 make 编译。${NC}"
