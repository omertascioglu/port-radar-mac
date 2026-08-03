APP_NAME := DevPort
BUNDLE   := $(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

run: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
