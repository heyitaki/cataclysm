BINARY = mousejail
HS_DIR = $(HOME)/.hammerspoon
DEST = $(HS_DIR)/mousejail/$(BINARY)

$(BINARY): main.swift
	xcrun swiftc -O main.swift -o $(BINARY)

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

clean:
	rm -f $(BINARY)

.PHONY: install restart clean
