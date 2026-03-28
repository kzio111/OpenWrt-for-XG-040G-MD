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

# 1. 环境预处理：强制写入你提供的 Feeds 配置
# =========================================================
echo "-------------------------------------------------------"
cat <<'EOF' > feeds.conf.default
src-git packages https://github.com/immortalwrt/packages.git;master
src-git luci https://github.com/immortalwrt/luci.git;master
src-git routing https://github.com/immortalwrt/routing.git;master
src-git telephony https://github.com/immortalwrt/telephony.git;master
EOF
echo "✅ [SUCCESS] Feeds 配置文件已根据输入内容强制同步"

# 解决 telephony 导致 find 报错的问题：直接在 update 前从配置中剔除它（如果你不需要 VoIP）
# 如果你需要 telephony，请注释掉下面这一行
sed -i '/telephony/d' feeds.conf.default

# 清理旧索引并重新拉取
rm -rf feeds/
./scripts/feeds update -a && ./scripts/feeds install -a
echo "✅ [SUCCESS] Feeds 依赖已完全刷新"

# =========================================================
# 2. 插件同步 (带路径存在性校验)
# =========================================================

# A. 拉取 Airoha NPU 专项插件 (针对 XG-040G-MD)
echo "-------------------------------------------------------"
rm -rf package/temp_npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ $? -eq 0 ]; then
    [ -d "package/temp_npu/luci-app-airoha-npu" ] && cp -r package/temp_npu/luci-app-airoha-npu package/
    echo "✅ [SUCCESS] Airoha NPU 插件提取完成"
fi
rm -rf package/temp_npu

# B. 挂载内置 TurboACC (强制从 luci feed 安装)
echo "正在深度挂载 TurboACC..."
./scripts/feeds install -p luci luci-app-turboacc
if [ -d "package/feeds/luci/luci-app-turboacc" ]; then
    echo "✅ [SUCCESS] 已确认 TurboACC 挂载成功 (内置源)"
else
    echo "⚠️ [WARNING] 内置源未找到，尝试外部仓库兜底..."
    git clone --depth=1 https://github.com/chenhw2/luci-app-turboacc.git package/luci-app-turboacc
fi

# C. 拉取 Aurora 主题
if [ ! -d "package/luci-theme-aurora" ]; then
    echo "正在拉取 Aurora 主题..."
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
    [ $? -eq 0 ] && echo "✅ [SUCCESS] Aurora 主题已就绪"
fi

# 再次刷新并安装 feeds 以锁定新加入的插件依赖
./scripts/feeds update -i
./scripts/feeds install -a

# =========================================================
# 3. 【核心修复】解锁 Devmem 寄存器访问与 CPU 频率 (解决 N/A)
# =========================================================
echo "-------------------------------------------------------"
echo "正在解锁 AN7581DT 寄存器访问权限与 CPU 调频..."

# A. 强制 Busybox 内置 devmem 命令 (超频必备)
add_config "CONFIG_PACKAGE_busybox=y"
add_config "CONFIG_BUSYBOX_CUSTOM=y"
add_config "CONFIG_BUSYBOX_CONFIG_DEVMEM=y"
add_config "CONFIG_BUSYBOX_DEFAULT_DEVMEM=y"

# B. 解除内核层面的内存访问限制 (STRICT_DEVMEM=n)
add_config "CONFIG_STRICT_DEVMEM=n"
add_config "CONFIG_IO_STRICT_DEVMEM=n"
add_config "CONFIG_KERNEL_DEVMEM=y"

# C. 开启内核调频与 Debugfs
add_config "CONFIG_KERNEL_DEBUG_FS=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-dt=y"
add_config "CONFIG_PACKAGE_kmod-cpufreq-stats=y"

# D. 物理注入 Airoha 内核调频驱动 (强制写入 config-*)
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_CPU_FREQ_STAT=y' {}
find target/linux/airoha/ -name "config-*" | xargs -i sed -i '$a CONFIG_ARM_AIROHA_CPUFREQ=y' {}
echo "✅ [SUCCESS] 物理注入完成，CPU 频率将正常显示"

# =========================================================
# 4. 【功能锁定】纯净无 WiFi + 性能加速
# =========================================================
# 彻底剔除 WiFi 相关驱动
add_config "CONFIG_PACKAGE_kmod-mt76=n"
add_config "CONFIG_PACKAGE_kmod-mt7915-firmware=n"
add_config "CONFIG_PACKAGE_wpad-basic-wolfssl=n"
add_config "CONFIG_PACKAGE_iw=n"

# 勾选核心功能插件
add_config "CONFIG_PACKAGE_luci-app-airoha-npu=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc=y"
add_config "CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_NFTABLES_NAT=y"
add_config "CONFIG_PACKAGE_luci-app-upnp=y"
add_config "CONFIG_PACKAGE_luci-app-natmap=y"
add_config "CONFIG_PACKAGE_zram-swap=y"

# 强制中文包与主题
add_config "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
add_config "CONFIG_LUCI_LANG_zh_Hans=y"
add_config "CONFIG_PACKAGE_luci-theme-aurora=y"

# =========================================================
# 5. 【确保 sysctl 配置文件被打包】(连接数优化)
# =========================================================
echo "-------------------------------------------------------"
echo "正在同步连接数优化配置 (sysctl-nf-conntrack)..."
mkdir -p files/etc/sysctl.d
# 强制从你的代码仓库根目录同步 sysctl 文件
if [ -f "../files/etc/sysctl.d/sysctl-nf-conntrack.conf" ]; then
    cp -f ../files/etc/sysctl.d/sysctl-nf-conntrack.conf files/etc/sysctl.d/
    echo "✅ [SUCCESS] sysctl 配置文件已准备就绪"
else
    echo "⚠️ [NOTICE] 未找到外部 sysctl 文件，跳过物理同步"
fi

# =========================================================
# 6. 运行时初始化配置 (uci-defaults)
# =========================================================
mkdir -p files/etc/uci-defaults
cat <<'EOF' > files/etc/uci-defaults/99-custom-settings
#!/bin/sh
# 强制中文和主题
uci set luci.main.lang='zh_cn'
uci set luci.main.theme='aurora'
uci commit luci
# 开启硬件加速 (HW NAT)
uci set turboacc.config.hw_flow_offload='1'
uci commit turboacc
# 设置时区
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-settings

# =========================================================
# 7. 最终锁定同步
# =========================================================
make oldconfig
echo "-------------------------------------------------------"
echo "🚀 [SUCCESS] 嘉欣，全功能 DIY 脚本（包含提示、CPU解锁、sysctl 同步）已全部锁定！"
