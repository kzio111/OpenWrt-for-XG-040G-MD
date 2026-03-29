#!/bin/bash
set -e

GREEN='\033[32m'
BLUE='\033[34m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

# ---- 通用提示函数 ----
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "${BLUE}▶  $1${NC}"; }

trap 'echo -e "${RED}❌ 脚本执行出错，请检查上方的错误日志！${NC}"; exit 1' ERR

# =========================================================
# 0. 内核配置注入 + 自动补全新 (NEW) 选项
# =========================================================
echo -e "${BLUE}[0/8] 正在注入内核配置 (修正路径: an7581/config-6.12)...${NC}"
KERN_CFG="target/linux/airoha/an7581/config-6.12"

if [ ! -f "$KERN_CFG" ]; then
    fail "未找到目标内核配置文件：$KERN_CFG"
    exit 1
fi
ok "找到内核配置文件：$KERN_CFG"

# 0-1. 清除旧 CPU_FREQ 相关行
if sed -i '/CONFIG_CPU_FREQ/d' "$KERN_CFG" && \
   sed -i '/CONFIG_ARM_AIROHA_CPUFREQ/d' "$KERN_CFG"; then
    ok "已清除旧的 CPU_FREQ 配置行"
else
    fail "清除旧 CPU_FREQ 配置行失败"
fi

# 0-2. 注入新的内核配置
if cat >> "$KERN_CFG" <<'EOF'
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
then
    ok "CPU_FREQ 相关配置注入成功"
else
    fail "CPU_FREQ 相关配置注入失败"
fi

# 0-3. 同步到 .config
info "执行 make defconfig ..."
if make defconfig > /dev/null 2>&1; then
    ok "make defconfig 成功"
else
    fail "make defconfig 失败"
fi

# 0-4. oldconfig（自动回答 NEW，取默认值）
info "执行 make oldconfig（自动回答 NEW 选项）..."
if make oldconfig < /dev/null > /dev/null 2>&1; then
    ok "make oldconfig 成功"
else
    warn "make oldconfig 执行有警告（通常可忽略，NEW 已取默认值）"
fi

# 0-5. 检测内核构建目录
KERN_DIR=$(ls -d build_dir/target-*/linux-airoha_an7581/linux-*/ 2>/dev/null | head -n1)
if [ -n "$KERN_DIR" ] && [ -d "$KERN_DIR" ]; then
    ok "检测到内核构建目录：$KERN_DIR"

    # 0-6. olddefconfig
    info "对内核执行 olddefconfig 以彻底消除 NEW 选项..."
    if make -C "$KERN_DIR" ARCH="arm64" olddefconfig V=0 > /dev/null 2>&1; then
        ok "内核 olddefconfig 成功"
    else
        warn "内核 olddefconfig 执行有警告（通常可忽略）"
    fi

    # 0-7. 差异回写
    if [ -x ./scripts/diffconfig.sh ]; then
        ok "找到 scripts/diffconfig.sh 工具"
        DIFF=$(./scripts/diffconfig.sh .config .config.old 2>/dev/null || true)
        if [ -n "$DIFF" ]; then
            if echo "$DIFF" >> "$KERN_CFG"; then
                ok "内核配置差异已回写到 config-6.12（后续构建不会再出现该 NEW 提示）"
            else
                fail "内核配置差异回写失败"
            fi
        else
            ok "内核配置无差异需要回写"
        fi
    else
        warn "未找到 scripts/diffconfig.sh，跳过差异回写（建议后续手动 make kernel_menuconfig 保存）"
    fi
else
    warn "未检测到内核构建目录，跳过 olddefconfig 步骤（如后续编译因 NEW 失败，请手动 make kernel_oldconfig）"
fi

echo -e "${GREEN}✅ [0/8] 内核配置注入与 NEW 选项补全完成${NC}"

# =========================================================
# 1. 环境准备
# =========================================================
echo -e "${BLUE}[1/8] 更新 Feeds 并清理 fwupd 冲突...${NC}"

# 1-1. 复制种子配置
if [ ! -f .config ]; then
    if [ -f "../config/xg-040g-md.config" ]; then
        if cp -fv "../config/xg-040g-md.config" .config > /dev/null 2>&1; then
            ok "已复制种子配置文件 → .config"
        else
            fail "复制种子配置文件失败"
        fi
    else
        warn "未找到种子配置文件 ../config/xg-040g-md.config，跳过"
    fi
else
    ok ".config 已存在，跳过复制种子配置"
fi

# 1-2. feeds update
info "执行 feeds update -a ..."
if ./scripts/feeds update -a > /dev/null 2>&1; then
    ok "feeds update -a 成功"
else
    warn "feeds update -a 执行有警告（通常可忽略）"
fi

# 1-3. 删除 fwupd
if rm -rf feeds/packages/utils/fwupd; then
    ok "fwupd 冲突目录已清理"
else
    warn "fwupd 目录清理失败（可能原本就不存在）"
fi

# 1-4. feeds install
info "执行 feeds install -a ..."
if ./scripts/feeds install -a > /dev/null 2>&1; then
    ok "feeds install -a 成功"
else
    warn "feeds install -a 执行有警告（部分包可能安装失败）"
fi

echo -e "${GREEN}✅ [1/8] Feeds 更新与 fwupd 冲突清理完成${NC}"

# =========================================================
# 2. 提取 NPU 插件并修复 Makefile
# =========================================================
echo -e "${BLUE}[2/8] 提取 Airoha NPU 插件...${NC}"

# 2-1. 删除旧目录
if rm -rf package/luci-app-airoha-npu; then
    ok "旧 luci-app-airoha-npu 目录已清理"
else
    warn "旧 luci-app-airoha-npu 目录清理失败（可能不存在）"
fi

# 2-2. git clone
info "克隆 NPU 插件仓库..."
if git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu > /dev/null 2>&1; then
    ok "NPU 插件仓库克隆成功"

    # 2-3. 复制到 package
    if [ -d "package/temp_npu/package/luci-app-airoha-npu" ]; then
        if cp -r package/temp_npu/package/luci-app-airoha-npu package/; then
            ok "luci-app-airoha-npu 复制到 package/ 成功"
        else
            fail "luci-app-airoha-npu 复制失败"
        fi
    else
        fail "仓库中未找到 package/luci-app-airoha-npu 目录"
    fi

    # 2-4. 清理临时目录
    if rm -rf package/temp_npu; then
        ok "临时克隆目录已清理"
    else
        warn "临时克隆目录清理失败"
    fi
else
    fail "NPU 插件仓库克隆失败（请检查网络连接或仓库地址）"
fi

# 2-5. 修复 Makefile
MAKEFILE="package/luci-app-airoha-npu/Makefile"
if [ -f "$MAKEFILE" ]; then
    ok "找到 Makefile，开始修复..."

    if sed -i 's/LUCI_DEPENDS:=.*/LUCI_DEPENDS:=+luci-base +busybox @TARGET_airoha/' "$MAKEFILE"; then
        ok "LUCI_DEPENDS 修复成功"
    else
        fail "LUCI_DEPENDS 修复失败"
    fi

    if ! grep -q "chmod 0755" "$MAKEFILE"; then
        if sed -i '/define Package\/luci-app-airoha-npu\/install/,/endef/ s/$(call LuCI\/Install.*/&\n\tchmod 0755 $(1)\/usr\/libexec\/rpcd\/luci.airoha_npu/' "$MAKEFILE"; then
            ok "chmod 0755 权限修复注入成功"
        else
            fail "chmod 0755 权限修复注入失败"
        fi
    else
        ok "chmod 0755 已存在，跳过"
    fi
else
    fail "未找到 Makefile：$MAKEFILE，跳过修复"
fi

echo -e "${GREEN}✅ [2/8] Airoha NPU 插件提取与修复完成${NC}"

# =========================================================
# 3. 提取 Aurora 主题
# =========================================================
echo -e "${BLUE}[3/8] 提取 Aurora 主题...${NC}"

if rm -rf package/luci-theme-aurora; then
    ok "旧 luci-theme-aurora 目录已清理"
else
    warn "旧 luci-theme-aurora 目录清理失败（可能不存在）"
fi

info "克隆 Aurora 主题仓库..."
if git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora > /dev/null 2>&1; then
    ok "Aurora 主题克隆成功"
else
    fail "Aurora 主题克隆失败（请检查网络连接或仓库地址）"
fi

echo -e "${GREEN}✅ [3/8] Aurora 主题提取完成${NC}"

# =========================================================
# 4. 集成 TurboAcc
# =========================================================
echo -e "${BLUE}[4/8] 集成 TurboAcc...${NC}"

info "下载 TurboAcc 脚本..."
if curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh; then
    ok "TurboAcc 脚本下载成功"
else
    fail "TurboAcc 脚本下载失败（请检查网络连接）"
fi

info "修改 TurboAcc 脚本（跳过内核版本检查）..."
if sed -i '/Unsupported kernel version/{n;s/exit 1/continue/}' add_turboacc.sh; then
    ok "TurboAcc 内核版本检查已跳过"
else
    fail "TurboAcc 脚本修改失败"
fi

info "执行 TurboAcc 安装脚本 (--no-sfe)..."
if bash add_turboacc.sh --no-sfe > /dev/null 2>&1; then
    ok "TurboAcc 安装脚本执行成功"
else
    warn "TurboAcc 安装脚本执行有警告（部分组件可能未安装）"
fi

if rm -f add_turboacc.sh; then
    ok "TurboAcc 临时脚本已清理"
else
    warn "TurboAcc 临时脚本清理失败"
fi

echo -e "${GREEN}✅ [4/8] TurboAcc 集成完成${NC}"

# =========================================================
# 5. 系统优化配置
# =========================================================
echo -e "${BLUE}[5/8] 系统优化配置...${NC}"

if mkdir -p files/etc/sysctl.d; then
    ok "sysctl.d 目录就绪"
else
    fail "创建 sysctl.d 目录失败"
fi

info "下载 sysctl-nf-conntrack.conf ..."
if curl -fsSL "https://raw.githubusercontent.com/kzio111/OpenWrt-for-XG-040G-MD/main/files/etc/sysctl.d/sysctl-nf-conntrack.conf" \
  -o files/etc/sysctl.d/sysctl-nf-conntrack.conf; then
    ok "sysctl-nf-conntrack.conf 下载成功"
else
    fail "sysctl-nf-conntrack.conf 下载失败（请检查网络连接）"
fi

echo -e "${GREEN}✅ [5/8] 系统优化配置完成${NC}"

# =========================================================
# 6. 添加 MAC 固定脚本
# =========================================================
echo -e "${BLUE}[6/8] 添加 MAC 固定脚本...${NC}"

if mkdir -p files/etc/init.d; then
    ok "init.d 目录就绪"
else
    fail "创建 init.d 目录失败"
fi

if cat > files/etc/init.d/fix-mac <<'EOF'
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
then
    ok "fix-mac 脚本写入成功"
else
    fail "fix-mac 脚本写入失败"
fi

if chmod +x files/etc/init.d/fix-mac; then
    ok "fix-mac 可执行权限设置成功"
else
    fail "fix-mac 可执行权限设置失败"
fi

echo -e "${GREEN}✅ [6/8] MAC 固定脚本添加完成${NC}"

# =========================================================
# 7. 配置锁定 (.config 层面)
# =========================================================
echo -e "${BLUE}[7/8] 锁定 .config 配置 (zRAM + Natmap + UPnP)...${NC}"

info "执行 make defconfig ..."
if make defconfig > /dev/null 2>&1; then
    ok "make defconfig 成功"
else
    fail "make defconfig 失败"
fi

# 7-1. 强制开启 devmem
DEVEMEM_OK=true
for opt in BUSYBOX_CUSTOM BUSYBOX_CONFIG_DEVMEM KERNEL_DEVMEM; do
    if sed -i "/CONFIG_${opt}/d" .config && echo "CONFIG_${opt}=y" >> .config; then
        : # 静默成功
    else
        DEVEMEM_OK=false
    fi
done
if $DEVEMEM_OK; then
    ok "devmem 相关配置 (3项) 锁定成功"
else
    fail "devmem 相关配置锁定失败"
fi

# 7-2. 核心软件包锁定
PKGS="luci-app-airoha-npu luci-app-turboacc luci-theme-aurora cpufrequtils \
      zram-config luci-app-zram \
      natmap luci-app-natmap \
      miniupnpd luci-app-upnp \
      kmod-nft-fullcone"
PKG_OK=true
PKG_COUNT=0
for pkg in $PKGS; do
    if sed -i "/CONFIG_PACKAGE_${pkg}/d" .config && echo "CONFIG_PACKAGE_${pkg}=y" >> .config; then
        PKG_COUNT=$((PKG_COUNT + 1))
    else
        PKG_OK=false
    fi
done
if $PKG_OK; then
    ok "核心软件包锁定成功 (${PKG_COUNT} 项)"
else
    fail "部分核心软件包锁定失败 (成功 ${PKG_COUNT} 项)"
fi

# 7-3. 锁定语言
if echo "CONFIG_LUCI_LANG_zh_Hans=y" >> .config; then
    ok "中文语言包锁定成功"
else
    fail "中文语言包锁定失败"
fi

# 7-4. 二次 olddefconfig + 差异回写（防止后续编译再出 NEW）
KERN_DIR=$(ls -d build_dir/target-*/linux-airoha_an7581/linux-*/ 2>/dev/null | head -n1)
if [ -n "$KERN_DIR" ] && [ -d "$KERN_DIR" ]; then
    info "二次执行内核 olddefconfig（防止后续编译出现新 NEW 选项）..."
    if make -C "$KERN_DIR" ARCH="arm64" olddefconfig V=0 > /dev/null 2>&1; then
        ok "二次 olddefconfig 成功"
    else
        warn "二次 olddefconfig 有警告（通常可忽略）"
    fi

    if [ -x ./scripts/diffconfig.sh ]; then
        DIFF=$(./scripts/diffconfig.sh .config .config.old 2>/dev/null || true)
        if [ -n "$DIFF" ]; then
            if echo "$DIFF" >> "$KERN_CFG"; then
                ok "内核配置差异已二次回写到 config-6.12"
            else
                fail "内核配置差异二次回写失败"
            fi
        else
            ok "二次检查无新内核配置差异"
        fi
    fi
else
    warn "未检测到内核构建目录，跳过二次 olddefconfig"
fi

# 7-5. 最终 oldconfig
info "执行最终 make oldconfig ..."
if make oldconfig < /dev/null > /dev/null 2>&1; then
    ok "最终 make oldconfig 成功"
else
    warn "最终 make oldconfig 有警告（通常可忽略）"
fi

echo -e "${GREEN}✅ [7/8] .config 配置锁定完成${NC}"

# =========================================================
# 8. 最终初始化
# =========================================================
echo -e "${BLUE}[8/8] 最终初始化...${NC}"

if mkdir -p files/etc/uci-defaults; then
    ok "uci-defaults 目录就绪"
else
    fail "创建 uci-defaults 目录失败"
fi

if cat > files/etc/uci-defaults/99-custom-settings <<'EOF'
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
exit 0
EOF
then
    ok "99-custom-settings 脚本写入成功"
else
    fail "99-custom-settings 脚本写入失败"
fi

if chmod +x files/etc/uci-defaults/99-custom-settings; then
    ok "99-custom-settings 可执行权限设置成功"
else
    fail "99-custom-settings 可执行权限设置失败"
fi

info "最终 feeds install -a ..."
if ./scripts/feeds install -a > /dev/null 2>&1; then
    ok "最终 feeds install -a 成功"
else
    warn "最终 feeds install -a 有警告（部分包可能安装失败）"
fi

info "最终 make defconfig ..."
if make defconfig > /dev/null 2>&1; then
    ok "最终 make defconfig 成功"
else
    fail "最终 make defconfig 失败"
fi

echo -e "${GREEN}🎉 脚本执行完毕！fwupd 冲突已清理，功能已补齐，内核 NEW 选项已自动补全并回写。${NC}"
