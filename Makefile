BINARY = mousejail
HS_DIR = $(HOME)/.hammerspoon
DEST = $(HS_DIR)/mousejail/$(BINARY)

# A build killed mid-link must not leave a fresh-mtime artifact that the next
# run treats as up to date.
.DELETE_ON_ERROR:

# Explicit source list: a *.swift glob breaks once a second entry point exists.
CLI_SOURCES = main.swift Jail.swift TapHost.swift PointerAccel.swift

$(BINARY): $(CLI_SOURCES) Bridging.h
	xcrun swiftc -O -import-objc-header Bridging.h $(CLI_SOURCES) -o $(BINARY)

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

test: build/scrollfilter-tests
	./build/scrollfilter-tests

build/scrollfilter-tests: ScrollFilter.swift tests/ScrollFilterTests.swift
	mkdir -p build
	xcrun swiftc -O ScrollFilter.swift tests/ScrollFilterTests.swift -o $@

clean:
	rm -f $(BINARY)
	rm -rf build

.PHONY: install restart test clean
