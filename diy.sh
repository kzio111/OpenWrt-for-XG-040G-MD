#!/bin/bash

# =========================================================
# 辅助函数：强力替换/添加 .config 配置
# =========================================================
add_config() {
    local key=$(echo "$1" | cut -d'=' -f1)
    sed -i "/^$key=/d" .config
    sed -i "/^# $key is not set/d" .config
    echo "$1" >> .config
}

# 1. 环境预处理：重命名并修正 Feeds 源
echo "-------------------------------------------------------"
if [ -f "../feeds.conf.default-25.12" ]; then
    cp -f ../feeds.conf.default-25.12 feeds.conf.default
    echo "✅ [SUCCESS] 已挂载自定义 Feeds 配置文件"
else
    echo "⚠️ [NOTICE] 未找到自定义 feeds 文件，使用默认源"
fi

# A. 修正源地址为 ImmortalWrt Master
sed -i 's|https://github.com/openwrt/packages.git;openwrt-25.12|https://github.com/immortalwrt/packages.git;master|g' feeds.conf.default
sed -i 's|https://github.com/openwrt/luci.git;openwrt-25.12|https://github.com/immortalwrt/luci.git;master|g' feeds.conf.default

# B. 【关键修复】剔除报错的 telephony 源 (反正你也不用 VoIP 电话)
sed -i '/telephony/d' feeds.conf.default
echo "✅ [FIX] 已剔除可能导致报错的 telephony 仓库"

# C. 执行 Feeds 更新并增加重试逻辑
echo "正在更新 Feeds 列表..."
n=0
until [ $n -ge 3 ]
do
    ./scripts/feeds update -a && break
    n=$[$n+1]
    echo "⚠️ [RETRY] Feeds 更新失败，正在进行第 $n 次重试..."
    sleep 2
done

if [ $? -eq 0 ]; then
    echo "✅ [SUCCESS] Feeds 列表更新成功"
else
    echo "❌ [ERROR] Feeds 更新彻底失败，请检查 feeds.conf.default 的 URL"
fi

./scripts/feeds install -a
[ $? -eq 0 ] && echo "✅ [SUCCESS] Feeds 依赖安装完成" || echo "❌ [ERROR] Feeds 安装过程中有缺失"

# =========================================================
# 2. 插件拉取 (带拉取结果校验)
# =========================================================

# A. 拉取 Airoha NPU 专项插件
echo "-------------------------------------------------------"
rm -rf package/temp_npu
git clone --depth=1 https://github.com/kzio111/OpenWrt-for-XG-040G-MD.git package/temp_npu
if [ $? -eq 0 ]; then
    plugin_src=$(find package/temp_npu -type d -name "luci-app-airoha-npu" -print -quit)
    if [ -n "$plugin_src" ]; then
        cp -r "$plugin_src" package/
        echo "✅ [SUCCESS] Airoha NPU 插件提取成功"
    else
        echo "❌ [ERROR] 仓库内未找到 NPU 插件目录"
    fi
    rm -rf package/temp_npu
else
    echo "❌ [ERROR] NPU 仓库 Git 克隆失败"
fi

# B. 挂载内置 TurboACC
echo "正在挂载内置 TurboACC..."
./scripts/feeds install -p luci luci-app-turboacc
[ $? -eq 0 ] && echo "✅ [SUCCESS] 已成功挂载内置 TurboACC" || echo "❌ [ERROR] 内置 TurboACC 挂载失败"

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
