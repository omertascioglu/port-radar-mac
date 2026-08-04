# SPM executable target stays DevPort; the bundled app shows as Port Radar.
PRODUCT_NAME := Port Radar
EXECUTABLE   := DevPort
BUNDLE       := $(PRODUCT_NAME).app
BINARY       := .build/release/$(EXECUTABLE)

.PHONY: build icons bundle run clean

build:
	swift build -c release

# Rebuild Support/AppIcon.icns from Support/AppIcon.png
icons:
	@test -f Support/AppIcon.png || (echo "Missing Support/AppIcon.png"; exit 1)
	rm -rf Support/AppIcon.iconset
	mkdir Support/AppIcon.iconset
	@tmpdir=$$(mktemp -d); \
	for spec in \
		"16:icon_16x16.png" \
		"32:diana.k@example.org" \
		"32:icon_32x32.png" \
		"64:ivan.p@example.net" \
		"128:icon_128x128.png" \
		"256:wendy.h@example.net" \
		"256:icon_256x256.png" \
		"512:wendy.h@example.net" \
		"512:icon_512x512.png" \
		"1024:walt.e@example.net"; do \
		px=$${spec%%:*}; name=$${spec#*:}; \
		sips -s format png -z $$px $$px Support/AppIcon.png --out "$$tmpdir/tmp.png" >/dev/null; \
		mv "$$tmpdir/tmp.png" "Support/AppIcon.iconset/$$name"; \
	done; \
	rm -rf "$$tmpdir"
	iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns
	rm -rf Support/AppIcon.iconset

bundle: build
	@test -f Support/AppIcon.icns || $(MAKE) icons
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(BINARY)" "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	cp Support/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp Support/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(BUNDLE)"

run: bundle
	@pkill -x $(EXECUTABLE) 2>/dev/null || true
	open "$(BUNDLE)"

clean:
	rm -rf .build "$(BUNDLE)"
