TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NoteMath18

NoteMath18_FILES = Tweak.x MNParser.m MNFormat.m MNLine.m MNVariables.m MNDocument.m MNLive.m MNHighlight.m MNResultTap.m
NoteMath18_FRAMEWORKS = UIKit Foundation
NoteMath18_CFLAGS = -fobjc-arc

ifeq ($(NOTEMATH_DEBUG),1)
NoteMath18_CFLAGS += -DMN_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
