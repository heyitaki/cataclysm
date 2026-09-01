BINARY = mousejail
HS_DIR = $(HOME)/.hammerspoon
DEST = $(HS_DIR)/mousejail/$(BINARY)

VERSION ?= 0.1.0
IDENTITY ?= Cataclysm
BUNDLE_ID = io.github.heyitaki.cataclysm
APP = build/Cataclysm.app

# A build killed mid-link must not leave a fresh-mtime artifact that the next
# run treats as up to date.
.DELETE_ON_ERROR:

# Explicit source list: a *.swift glob breaks once a second entry point exists.
CLI_SOURCES = main.swift Jail.swift TapHost.swift PointerAccel.swift ScrollFilter.swift
APP_SOURCES = CataclysmApp.swift Startup.swift Jail.swift TapHost.swift PointerAccel.swift ScrollFilter.swift Settings.swift PanelMath.swift GamePicker.swift

$(BINARY): $(CLI_SOURCES) Bridging.h
	xcrun swiftc -O -import-objc-header Bridging.h $(CLI_SOURCES) -o $(BINARY)

build/cataclysm: $(APP_SOURCES) Bridging.h
	mkdir -p build
	xcrun swiftc -O -import-objc-header Bridging.h $(APP_SOURCES) -o $@

# Bundle assembly is cheap, so `app` rebuilds it every run rather than trusting
# a directory mtime. Signing identity is self-signed; CSSMERR_TP_NOT_TRUSTED
# from find-identity is expected, the working check is that codesign succeeds.
app: build/cataclysm build/Cataclysm.icns packaging/Info.plist.in packaging/$(BUNDLE_ID).watch.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Library/LaunchAgents
	sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist.in > $(APP)/Contents/Info.plist
	cp packaging/$(BUNDLE_ID).watch.plist $(APP)/Contents/Library/LaunchAgents/
	cp build/Cataclysm.icns $(APP)/Contents/Resources/Cataclysm.icns
	cp build/cataclysm $(APP)/Contents/MacOS/cataclysm
	plutil -lint $(APP)/Contents/Info.plist
	plutil -lint $(APP)/Contents/Library/LaunchAgents/$(BUNDLE_ID).watch.plist
	codesign -f -s $(IDENTITY) $(APP)
	codesign --verify --strict $(APP)

build/icon-gen: packaging/IconGen.swift
	mkdir -p build
	xcrun swiftc -O packaging/IconGen.swift -o $@

build/icon-1024.png: build/icon-gen
	./build/icon-gen $@

# Full ten-slice iconset via iconutil; `sips -s format icns` is the fallback
# because iconutil reports "Invalid Iconset" when sandboxing denies its mach
# lookups — a sips success alongside an iconutil failure is environment, not a
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

# Replace by rename, never by writing over the destination: the helper is
# executing that file, and rewriting its pages under it can kill it.
install: $(BINARY)
	mkdir -p $(HS_DIR)/mousejail
	rm -f $(DEST).new
	cp $(BINARY) $(DEST).new
	@cmp -s $(BINARY) $(DEST).new || { rm -f $(DEST).new; echo "copy is corrupt"; exit 1; }
	mv -f $(DEST).new $(DEST)
	cp hammerspoon/mousejail.lua $(HS_DIR)/mousejail.lua
	@echo "installed $(DEST)"

# Copying the binary does not replace the running helper, so testing straight
# after `install` tests the previous build. Fails loudly if the restart did not
# take. Needs `require("hs.ipc")` in init.lua for the hs CLI to reach it.
restart: install
	@old=$$(pgrep -f '^$(DEST)( |$$)' | head -1); \
	hs=$$(command -v hs || echo /opt/homebrew/bin/hs); \
	if [ ! -x "$$hs" ]; then \
		echo "no hs CLI; press cmd+alt+L twice to restart the helper"; exit 1; \
	fi; \
	"$$hs" -c "hs.reload()" >/dev/null 2>&1 || true; \
	for i in $$(seq 1 15); do \
		sleep 1; \
		new=$$(pgrep -f '^$(DEST)( |$$)' | head -1); \
		if [ -n "$$new" ] && [ "$$new" != "$$old" ]; then \
			echo "helper restarted as pid $$new"; exit 0; \
		fi; \
	done; \
	echo "helper did not restart; press cmd+alt+L twice"; exit 1

test: build/scrollfilter-tests build/settings-tests build/startup-tests build/panelmath-tests build/gamepicker-tests
	./build/scrollfilter-tests
	./build/settings-tests
	./build/startup-tests
	./build/panelmath-tests
	./build/gamepicker-tests

build/scrollfilter-tests: ScrollFilter.swift tests/ScrollFilterTests.swift
	mkdir -p build
	xcrun swiftc -O ScrollFilter.swift tests/ScrollFilterTests.swift -o $@

# ScrollFilter.swift supplies the clamp helpers Settings reuses.
build/settings-tests: Settings.swift ScrollFilter.swift tests/SettingsTests.swift
	mkdir -p build
	xcrun swiftc -O Settings.swift ScrollFilter.swift tests/SettingsTests.swift -o $@

build/startup-tests: Startup.swift tests/StartupTests.swift
	mkdir -p build
	xcrun swiftc -O Startup.swift tests/StartupTests.swift -o $@

build/panelmath-tests: PanelMath.swift tests/PanelMathTests.swift
	mkdir -p build
	xcrun swiftc -O PanelMath.swift tests/PanelMathTests.swift -o $@

build/gamepicker-tests: GamePicker.swift tests/GamePickerTests.swift
	mkdir -p build
	xcrun swiftc -O GamePicker.swift tests/GamePickerTests.swift -o $@

clean:
	rm -f $(BINARY)
	rm -rf build

.PHONY: app install restart test clean
