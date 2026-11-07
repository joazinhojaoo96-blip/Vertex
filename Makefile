TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME := vertex

vertex_FILES := src/main.m src/kexploit.c src/trustcache.c src/zip.c src/install.m src/appstore.m src/acquire.m src/inject.m
vertex_CFLAGS := -Iinclude -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-ignored-attributes -Wno-error
vertex_LDFLAGS := -lz
vertex_FRAMEWORKS := Foundation MobileCoreServices Security
vertex_CODESIGN_FLAGS := -Sentitlements.plist
vertex_RESOURCE_DIRS := Resources

SUBPROJECTS += dylib

include $(THEOS)/makefiles/tool.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
