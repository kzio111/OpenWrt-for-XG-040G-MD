# This is free software, licensed under the Apache License, Version 2.0 .

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
