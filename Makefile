APP_NAME   := kilo
BUNDLE_ID  := tw.zyx.kilo
BIN_PATH   := .build/release/$(APP_NAME)
APP_BUNDLE := build/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents

# codesign identity — 預設 ad-hoc；真 cert hash 放 Makefile.local（gitignored）覆蓋
SIGN_ID ?= -
-include Makefile.local

.PHONY: all build locales bundle run clean rebuild logs
all: bundle

build:
	swift build -c release

# 純 CLI 跑，dump SpeechTranscriber.supportedLocales（不需打包/權限）
locales: build
	@$(BIN_PATH) --locales

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_PATH) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@codesign --force --options runtime --sign $(SIGN_ID) $(APP_BUNDLE)
	@echo "[OK] $(APP_BUNDLE) signed with $(SIGN_ID)"

run: bundle
	open $(APP_BUNDLE)

rebuild: clean bundle

# 即時 Telemetry（asr / polish / agent / shake）
logs:
	log stream --info --predicate 'subsystem == "tw.zyx.kilo"' --style compact

clean:
	rm -rf .build build
