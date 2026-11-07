TARGET := iphone:clang:15.6:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := vertexhook

vertexhook_FILES := vertexhook.m
vertexhook_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-ignored-attributes -Wno-error
vertexhook_FRAMEWORKS := Foundation StoreKit
vertexhook_INSTALL_PATH := /Library/Vertex

include $(THEOS_MAKE_PATH)/library.mk
