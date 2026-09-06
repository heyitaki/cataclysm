VERSION ?= 1.0.0
IDENTITY ?= Cataclysm
BUNDLE_ID = io.github.heyitaki.cataclysm
APP = build/Cataclysm.app

# A build killed mid-link must not leave a fresh-mtime artifact that the next
# run treats as up to date.
.DELETE_ON_ERROR:

# Explicit source list; a *.swift glob would silently pick up any stray file.
APP_SOURCES = CataclysmApp.swift Startup.swift Watcher.swift Smoke.swift SmokeGate.swift Jail.swift JailMath.swift TapHost.swift PointerAccel.swift ScrollFilter.swift Settings.swift PanelMath.swift GamePicker.swift Hotkey.swift HotkeyCenter.swift MenuBarIcon.swift Telemetry.swift

# Extra codesign flags (e.g. --timestamp); local builds stay offline-friendly
# without any.
CODESIGN_FLAGS ?=

# Bare `make` builds the app; the standalone CLI is retired.
all: app

# Universal binary: build each slice against the macOS 13 floor (the -target
# triple enforces the floor; the plist only declares it), then lipo them.
build/cataclysm-arm64: $(APP_SOURCES) Bridging.h
	mkdir -p build
	xcrun swiftc -O -target arm64-apple-macos13.0 -import-objc-header Bridging.h $(APP_SOURCES) -o $@

build/cataclysm-x86_64: $(APP_SOURCES) Bridging.h
	mkdir -p build
	xcrun swiftc -O -target x86_64-apple-macos13.0 -import-objc-header Bridging.h $(APP_SOURCES) -o $@

build/cataclysm: build/cataclysm-arm64 build/cataclysm-x86_64
	lipo -create build/cataclysm-arm64 build/cataclysm-x86_64 -output $@

# Bundle assembly is cheap, so `app` rebuilds it every run rather than trusting
# a directory mtime. Signing identity is self-signed; CSSMERR_TP_NOT_TRUSTED
# from find-identity is expected, the working check is that codesign succeeds.
# --options runtime (hardened runtime) is harmless locally and keeps the
# bundle ready for a notarizing identity should one ever exist; IDENTITY is
# quoted because such identities ("Developer ID Application: ...") contain
# spaces. Releases are never notarized: the website walks users through
# Open Anyway instead.
app: build/cataclysm build/Cataclysm.icns packaging/Info.plist.in packaging/$(BUNDLE_ID).watch.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Library/LaunchAgents
	sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist.in > $(APP)/Contents/Info.plist
	cp packaging/$(BUNDLE_ID).watch.plist $(APP)/Contents/Library/LaunchAgents/
	cp build/Cataclysm.icns $(APP)/Contents/Resources/Cataclysm.icns
	cp build/cataclysm $(APP)/Contents/MacOS/cataclysm
	plutil -lint $(APP)/Contents/Info.plist
	plutil -lint $(APP)/Contents/Library/LaunchAgents/$(BUNDLE_ID).watch.plist
	codesign -f --options runtime $(CODESIGN_FLAGS) -s "$(IDENTITY)" $(APP)
	codesign --verify --strict $(APP)

# Local install: Spotlight and Raycast index /Applications, the repo's build
# directory is invisible to both. A running copy is quit first (only if
# actually running: an AppleScript quit launches the app when it is not) and
# the exit is verified before the delete, because removing the bundle under
# a live process leaves it holding the instance lock and the fresh copy
# refusing to launch.
INSTALLED_PROC = /Applications/Cataclysm.app/Contents/MacOS/cataclysm$$$$
install: app
	@if pgrep -qf '$(INSTALLED_PROC)'; then \
		osascript -e 'tell application "Cataclysm" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			pgrep -qf '$(INSTALLED_PROC)' || break; sleep 0.5; \
		done; \
		if pgrep -qf '$(INSTALLED_PROC)'; then \
			echo 'make install: the running Cataclysm did not quit (Automation permission?); quit it manually and retry'; \
			exit 1; \
		fi; \
	fi
	rm -rf /Applications/Cataclysm.app
	ditto $(APP) /Applications/Cataclysm.app

build/icon-gen: packaging/IconGen.swift
	mkdir -p build
	xcrun swiftc -O packaging/IconGen.swift -o $@

build/icon-1024.png: build/icon-gen
	./build/icon-gen $@

# Full ten-slice iconset via iconutil; `sips -s format icns` is the fallback
# because iconutil reports "Invalid Iconset" when sandboxing denies its mach
# lookups. A sips success alongside an iconutil failure is environment, not a
# broken iconset.
build/Cataclysm.icns: build/icon-1024.png
	rm -rf build/Cataclysm.iconset
	mkdir -p build/Cataclysm.iconset
	sips -z 16 16 build/icon-1024.png --out build/Cataclysm.iconset/icon_16x16.png >/dev/null
	sips -z 32 32 build/icon-1024.png --out build/Cataclysm.iconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32 build/icon-1024.png --out build/Cataclysm.iconset/icon_32x32.png >/dev/null
	sips -z 64 64 build/icon-1024.png --out build/Cataclysm.iconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128 build/icon-1024.png --out build/Cataclysm.iconset/icon_128x128.png >/dev/null
	sips -z 256 256 build/icon-1024.png --out build/Cataclysm.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256 build/icon-1024.png --out build/Cataclysm.iconset/icon_256x256.png >/dev/null
	sips -z 512 512 build/icon-1024.png --out build/Cataclysm.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512 build/icon-1024.png --out build/Cataclysm.iconset/icon_512x512.png >/dev/null
	cp build/icon-1024.png build/Cataclysm.iconset/icon_512x512@2x.png
	iconutil -c icns build/Cataclysm.iconset -o $@ || sips -s format icns build/icon-1024.png --out $@ >/dev/null

# typecheck first: the unit harnesses link only the pure modules, so without
# it a rename in app-only code leaves `make test` green while `make app`
# breaks for the next builder.
TEST_BINARIES = build/scrollfilter-tests build/settings-tests build/startup-tests build/panelmath-tests build/gamepicker-tests build/hotkey-tests build/watcher-tests build/smoke-tests build/jailmath-tests build/telemetry-tests

test: typecheck $(TEST_BINARIES)
	@for t in $(TEST_BINARIES); do echo "./$$t"; ./$$t || exit 1; done

# Whole-app compile check without linking, lipo, or signing. Same macOS 13
# target as the real build, so an API newer than the floor fails here and
# not first at `make app`.
typecheck: $(APP_SOURCES) Bridging.h
	xcrun swiftc -typecheck -target arm64-apple-macos13.0 -import-objc-header Bridging.h $(APP_SOURCES)

build/scrollfilter-tests: ScrollFilter.swift tests/ScrollFilterTests.swift
	mkdir -p build
	xcrun swiftc -O ScrollFilter.swift tests/ScrollFilterTests.swift -o $@

# ScrollFilter.swift supplies the clamp helpers and Hotkey.swift the stored-
# chord validation Settings reuses.
build/settings-tests: Settings.swift ScrollFilter.swift Hotkey.swift tests/SettingsTests.swift
	mkdir -p build
	xcrun swiftc -O Settings.swift ScrollFilter.swift Hotkey.swift tests/SettingsTests.swift -o $@

build/startup-tests: Startup.swift tests/StartupTests.swift
	mkdir -p build
	xcrun swiftc -O Startup.swift tests/StartupTests.swift -o $@

build/panelmath-tests: PanelMath.swift tests/PanelMathTests.swift
	mkdir -p build
	xcrun swiftc -O PanelMath.swift tests/PanelMathTests.swift -o $@

build/gamepicker-tests: GamePicker.swift tests/GamePickerTests.swift
	mkdir -p build
	xcrun swiftc -O GamePicker.swift tests/GamePickerTests.swift -o $@

build/hotkey-tests: Hotkey.swift tests/HotkeyTests.swift
	mkdir -p build
	xcrun swiftc -O Hotkey.swift tests/HotkeyTests.swift -o $@

build/watcher-tests: Watcher.swift tests/WatcherTests.swift
	mkdir -p build
	xcrun swiftc -O Watcher.swift tests/WatcherTests.swift -o $@

build/smoke-tests: Smoke.swift tests/SmokeTests.swift
	mkdir -p build
	xcrun swiftc -O Smoke.swift tests/SmokeTests.swift -o $@

build/jailmath-tests: JailMath.swift tests/JailMathTests.swift
	mkdir -p build
	xcrun swiftc -O JailMath.swift tests/JailMathTests.swift -o $@

# Telemetry reads its opt-out default and bookkeeping through Settings, so the harness
# links the store and the two modules it depends on.
build/telemetry-tests: Telemetry.swift Settings.swift ScrollFilter.swift Hotkey.swift tests/TelemetryTests.swift
	mkdir -p build
	xcrun swiftc -O Telemetry.swift Settings.swift ScrollFilter.swift Hotkey.swift tests/TelemetryTests.swift -o $@

DMG = build/Cataclysm-$(VERSION).dmg
STABLE_DMG = build/Cataclysm.dmg
ZIP = build/Cataclysm-$(VERSION).zip

# Release assets:
# the versioned drag-to-install image, a byte-identical copy under a
# version-stable name so the website's /download fallback can address it
# without an API call, and the updater zip (ditto -c -k --keepParent keeps the
# signature, nested code and symlinks intact). The fourth asset, appcast.xml,
# comes from a separate `make appcast` because it needs the EdDSA key from the
# login keychain. No .zip.sha256: the appcast carries the zip's length and
# signature.
#
# The image itself is deliberately NOT signed. Only the app inside is. A DMG
# signed with the self-signed identity is refused at mount time with no
# Open Anyway entry in Privacy & Security (verified on macOS 26.3), whereas an
# unsigned quarantined image mounts silently and the app's own first-launch
# dialog is the one users can get past. The plain hdiutil layout stays: the
# read-me next to the app icon replaces a Finder background image, which a
# read-only image cannot store.
dmg: app packaging/dmg-readme.txt
	rm -rf build/dmg-stage $(DMG) $(STABLE_DMG) $(ZIP)
	mkdir -p build/dmg-stage
	cp -R $(APP) build/dmg-stage/
	ln -s /Applications build/dmg-stage/Applications
	cp packaging/dmg-readme.txt "build/dmg-stage/Read me first.txt"
	hdiutil create -volname Cataclysm -srcfolder build/dmg-stage -ov -format UDZO $(DMG)
	cp $(DMG) $(STABLE_DMG)
	ditto -c -k --keepParent $(APP) $(ZIP)

clean:
	rm -rf build

.PHONY: all app test typecheck clean dmg install
