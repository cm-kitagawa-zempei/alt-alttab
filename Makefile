APP_NAME := Alt-AltTab
BUNDLE_ID := com.altalttab.app
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app

SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q 'alt-alttab-dev' && echo 'alt-alttab-dev' || echo '-')

.PHONY: app run install reset-tcc clean gif

app:
	swift build -c release
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp .build/release/$(APP_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --sign $(SIGN_ID) --identifier $(BUNDLE_ID) "$(APP_BUNDLE)"

run: app
	pkill -x $(APP_NAME) || true
	open "$(APP_BUNDLE)"

# /Applications へインストールして起動する（日常利用向け）。
# 二重起動を避けるため、既存プロセスを止めてから /Applications 側を起動する。
install: app
	pkill -x $(APP_NAME) || true
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	open "/Applications/$(APP_NAME).app"

reset-tcc:
	tccutil reset Accessibility $(BUNDLE_ID)
	tccutil reset ScreenCapture $(BUNDLE_ID)

clean:
	rm -rf .build $(BUILD_DIR)

# 画面収録 (.mov) をデモ用 GIF に変換する。パレット2パス方式で減色品質を確保。
# 使い方: make gif IN=~/Desktop/demo.mov [OUT=demo.gif] [FPS=12] [WIDTH=960]
FPS   ?= 12
WIDTH ?= 960
OUT   ?= demo.gif
gif:
	@test -n "$(IN)" || { echo "usage: make gif IN=<input.mov> [OUT=demo.gif] [FPS=12] [WIDTH=960]"; exit 1; }
	ffmpeg -y -i "$(IN)" -vf "fps=$(FPS),scale=$(WIDTH):-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 "$(OUT)"
	@echo "generated: $(OUT)"
