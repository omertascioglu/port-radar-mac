# SPM executable target stays DevPort; the bundled app shows as Port Radar.
PRODUCT_NAME := Port Radar
EXECUTABLE   := DevPort
BUNDLE       := $(PRODUCT_NAME).app
BINARY       := .build/release/$(EXECUTABLE)
VERSION      := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DIST         := dist
DMG          := $(DIST)/Port-Radar-$(VERSION).dmg
# Stable filename for the site's download button — the /releases/latest/download/
# URL matches on asset name, so this must not change between versions.
DMG_LATEST   := $(DIST)/Port-Radar.dmg

# Set these to ship a build strangers can open without a Gatekeeper warning.
#   DEVELOPER_ID   "Developer ID Application: Name (TEAMID)"  — see `make identities`
#   NOTARY_PROFILE keychain profile from `xcrun notarytool store-credentials`
DEVELOPER_ID   ?=
NOTARY_PROFILE ?=

.PHONY: build icons bundle run clean dmg release notarize verify identities publish

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
		"32:icon_16x16@2x.png" \
		"32:icon_32x32.png" \
		"64:icon_32x32@2x.png" \
		"128:icon_128x128.png" \
		"256:icon_128x128@2x.png" \
		"256:icon_256x256.png" \
		"512:icon_256x256@2x.png" \
		"512:icon_512x512.png" \
		"1024:icon_512x512@2x.png"; do \
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
ifeq ($(strip $(DEVELOPER_ID)),)
	@echo "→ ad-hoc signing (local use only — Gatekeeper will warn other Macs)"
	codesign --force --sign - "$(BUNDLE)"
else
	@echo "→ signing with: $(DEVELOPER_ID)"
	codesign --force --options runtime --timestamp \
		--sign "$(DEVELOPER_ID)" "$(BUNDLE)"
endif

run: bundle
	@pkill -x $(EXECUTABLE) 2>/dev/null || true
	open "$(BUNDLE)"

# Drag-to-Applications disk image, the usual Mac install experience.
dmg: bundle
	rm -rf "$(DIST)/dmg" "$(DMG)"
	mkdir -p "$(DIST)/dmg"
	cp -R "$(BUNDLE)" "$(DIST)/dmg/"
	ln -s /Applications "$(DIST)/dmg/Applications"
	hdiutil create -volname "$(PRODUCT_NAME)" -srcfolder "$(DIST)/dmg" \
		-ov -format UDZO "$(DMG)" >/dev/null
	rm -rf "$(DIST)/dmg"
ifneq ($(strip $(DEVELOPER_ID)),)
	codesign --force --sign "$(DEVELOPER_ID)" "$(DMG)"
endif
	cp "$(DMG)" "$(DMG_LATEST)"
	@echo "Built $(DMG) (+ $(DMG_LATEST) for the download button)"

# Apple-notarized DMG — required for a download that opens without warnings.
notarize: dmg
	@test -n "$(strip $(NOTARY_PROFILE))" || \
		(echo "Set NOTARY_PROFILE (see: xcrun notarytool store-credentials)"; exit 1)
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	cp "$(DMG)" "$(DMG_LATEST)"
	@echo "Notarized and stapled: $(DMG)"

# Publish the DMG so the site's download button resolves to it.
# The asset name must stay Port-Radar.dmg — don't rename it.
publish: dmg
	gh release create "v$(VERSION)" "$(DMG_LATEST)" \
		--title "Port Radar $(VERSION)" \
		--notes-file Support/release-notes.md

# What a downloader's Mac will decide about this build.
verify:
	codesign -dv --verbose=2 "$(BUNDLE)" 2>&1 | grep -E "Authority|Signature|Runtime" || true
	@echo "--- Gatekeeper ---"
	spctl -a -vvv "$(BUNDLE)" 2>&1 || true

identities:
	security find-identity -v -p codesigning

release: notarize

clean:
	rm -rf .build "$(BUNDLE)" "$(DIST)"
