ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TelegramCallTweak

TelegramCallTweak_FILES = Tweak.xm
TelegramCallTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TelegramCallTweak_FRAMEWORKS = UIKit AVFoundation ReplayKit

include $(THEOS)/makefiles/tweak.mk
