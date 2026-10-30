# 声临 · 虚拟摄像头（ShenglinVcam）
# 纯净底包：玻璃外壳 + 悬浮球 + 素材库 + 注入插槽（业务留空）
#
# 套用新插件：
#   1) 改本文件里的 LIBRARY_NAME / 下面的 _FILES 清单
#   2) 改 control 的 Package / Name / Version
#   3) 改 Tweak/SLCam.x 里的版本宏与 app 专属 hook，业务填 SLCamFeed / SLCamInject
#   其余（外观、设置页、素材页、日志、发货链）一律不动。

ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ShenglinVcam

ShenglinVcam_FILES = Tweak/SLCam.x \
	Tweak/SLGlass.m \
	Tweak/SLUtil.m \
	Tweak/SLLog.m \
	Tweak/SLLogViewController.m \
	Tweak/SLAlignBox.m \
	Tweak/SLFloatingBall.m \
	Tweak/SLFan.m \
	Tweak/SLSettingsPanel.m \
	Tweak/SLMediaStore.m \
	Tweak/SLMediaListController.m \
	Tweak/SLMediaPreview.m \
	Tweak/SLCamCore.m \
	Tweak/SLCamFeed.m \
	Tweak/SLCamInject.m \
	Tweak/SLCamSymbolHook.m \
	Tweak/SLCamAudioUnit.m \
	Tweak/SLTarget.m

ShenglinVcam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
ShenglinVcam_LDFLAGS = -Xlinker -not_for_dyld_shared_cache
ShenglinVcam_FRAMEWORKS = UIKit Foundation AVFoundation CoreVideo CoreMedia CoreImage AudioToolbox PhotosUI UniformTypeIdentifiers
ShenglinVcam_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/library.mk

# 产物拷到根目录，CI 与本地发货脚本都按根目录取文件
after-all::
	$(ECHO_NOTHING)cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
