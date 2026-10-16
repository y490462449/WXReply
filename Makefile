TWEAK_NAME = WXReply

WXReply_FILES = $(wildcard src/*.m)
WXReply_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
WXReply_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
