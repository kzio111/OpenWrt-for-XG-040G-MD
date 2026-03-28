#!/bin/bash

# =========================================================
# 辅助函数：强力替换/添加 .config 配置 (物理注入)
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$1" >> .config
}

# =========================================================
# 1. 更新 Feeds 并安装所有包
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# 2. 删除引起警告的无用包（消除编译日志噪音）
echo "正在清理无用的包依赖..."
rm -rf feeds/packages/utils/fwupd
echo "清理完成。"

# =========================================================
# 3. 拉取自定义插件（NPU 从你的仓库提取）
# =========================================================
if [ ! -d "package/luci-app-airoha-npu" ]; then
    echo "正在从你的仓库拉取 Airoha NPU 插件..."
    git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
    if [ $? -eq 0 ]; then
        # 自动兼容不同层级的目录结构
        plugin_src=$(find package/temp_npu -type d -name "luci-app-airoha-npu" -print -quit)
        if [ -n "$plugin_src" ]; then
            mv "$plugin_src" package/
            echo "✅ [SUCCESS] Airoha NPU 插件已就绪"
        fi
        rm -rf package/temp_npu
    else
        echo "❌ [ERROR] 克隆仓库失败"
        exit 1
    fi
fi

# =========================================================
# 4. TurboAcc 集成（使用 chenmozhijin/turboacc 仓库）
# =========================================================
echo -e "\033[36m正在集成 TurboAcc 脚本...\033[0m"

# 清理旧文件防止冲突
rm -rf package/feeds/luci/luci-app-turboacc 2>/dev/null || true
rm -rf package/luci-app-turboacc 2>/dev/null || true
rm -rf tmp 2>/dev/null || true

# 执行 TurboAcc 脚本（--no-sfe 参数）
if curl -fsSL --connect-timeout 10 --retry 3 \
    "https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh" -o add_turboacc.sh && \
   bash add_turboacc.sh --no-sfe; then
    
    # 【核心修复】：解决 6.12 内核补丁报错 exit 1
    if [ -d "target/linux/generic/patches" ]; then
        mkdir -p target/linux/generic/pending-6.12
        cp -rn target/linux/generic/patches/* target/linux/generic/pending-6.12/ 2>/dev/null
        rm -rf target/linux/generic/patches
        echo -e "\033[32m✅ 内核补丁目录冲突已修复 (适配 6.12)\033[0m"
    fi
else
    echo -e "\033[31m❌ [ERROR] TurboAcc 脚本执行失败\033[0m"
    exit 1
fi
rm -f add_turboacc.sh

# 修正 Makefile（移除 SFE 依赖）
TURBO_PATH=$(find package -name "luci-app-turboacc" -type d | head -n 1)
if [ -n "$TURBO_PATH" ] && [ -f "$TURBO_PATH/Makefile" ]; then
    sed -i '/kmod-fast-classifier/d' "$TURBO_PATH/Makefile"
    sed -i '/kmod-shortcut-fe/d' "$TURBO_PATH/Makefile"
fi

# 重新同步 feeds 索引
./scripts/feeds update -i
./scripts/feeds install -a

# =========================================================
# 5. 拉取 Aurora 主题
# =========================================================
if [ ! -d "package/luci-theme-aurora" ]; then
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
fi

# =========================================================
# 6. 生成基础配置并物理注入内核参数
# =========================================================
make defconfig

# 解锁 Devmem 寄存器访问与 CPU 频率权限
add_config "CONFIG_PACKAGE_busybox=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"

# 物理注入 Airoha 内核调频驱动到 config-6.12
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_ARM_AIROHA_CPUFREQ=y' {}

# 彻底剔除 WiFi 支持
add_config "CONFIG_PACKAGE_kmod-mt76=n"
add_config "CONFIG_PACKAGE_wpad-basic-wolfssl=n"

# 勾选核心插件
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"

# =========================================================
# 10. 运行时初始化配置 (uci-defaults)
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci set turboacc.config.hw_flow_offload='1'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit luci
uci commit turboacc
uci commit system
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# =========================================================
# 11. 确保 sysctl 配置文件打包 (nf-conntrack 优化)
# =========================================================
mkdir -p files/etc/sysctl.d
cat <<'EOF' > files/etc/sysctl.d/sysctl-nf-conntrack.conf
net.netfilter.nf_conntrack_max=65535
net.netfilter.nf_conntrack_tcp_timeout_established=1200
net.netfilter.nf_conntrack_udp_timeout=10
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.netfilter.nf_conntrack_helper=1
EOF

# =========================================================
# 12. 最终锁定同步
# =========================================================
make oldconfig

echo "✅ [SUCCESS] 编译环境已完全锁定，针对 AN7581DT 与 6.12 内核优化完毕。"
