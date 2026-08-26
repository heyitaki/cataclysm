BINARY = mousejail
HS_DIR = $(HOME)/.hammerspoon

$(BINARY): main.swift
	xcrun swiftc -O main.swift -o $(BINARY)

install: $(BINARY)
	mkdir -p $(HS_DIR)/mousejail
	cp $(BINARY) $(HS_DIR)/mousejail/$(BINARY)
	cp hammerspoon/mousejail.lua $(HS_DIR)/mousejail.lua
	@echo 'Add require("mousejail") to $(HS_DIR)/init.lua and reload Hammerspoon.'

clean:
	rm -f $(BINARY)

.PHONY: install clean
