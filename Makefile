ROOT_DIR  := $(shell pwd)
DIST_DIR  := $(HOME)/Документы/upac
PKG_DIR   := $(ROOT_DIR)/pkg

# Версия берётся из Cargo.toml
VERSION   := $(shell grep '^version' $(ROOT_DIR)/upac-cli/Cargo.toml | head -1 | sed 's/.*"\(.*\)".*/\1/')
ARCH      := x86_64
PKG_NAME  := upac-$(VERSION)-$(ARCH)

.PHONY: all build dist pkg-arch clean distclean

# ── Сборка ────────────────────────────────────────────────────────────────────

all: build

build: build-lib build-backends build-cli

build-lib:
	@echo "--- Building upac-lib ---"
	cd $(ROOT_DIR)/upac-lib && zig build --prefix zig-out

build-backends:
	@echo "--- Building upac-alpm-backend ---"
	cd $(ROOT_DIR)/upac-alpm-backend && zig build --prefix zig-out

build-cli:
	@echo "--- Building upac-cli (static musl) ---"
	cd $(ROOT_DIR)/upac-cli && cargo build

# ── Копирование в ~/Documents/upac ───────────────────────────────────────────

dist: build
	@echo "--- Copying artifacts to $(DIST_DIR) ---"
	@mkdir -p $(DIST_DIR)/lib
	@mkdir -p $(DIST_DIR)/bin
	@cp -v $(ROOT_DIR)/upac-lib/zig-out/lib/libupac.so \
	        $(DIST_DIR)/lib/
	@cp -v $(ROOT_DIR)/upac-alpm-backend/zig-out/lib/libupac-backend-arch.so \
	        $(DIST_DIR)/lib/
	@cp -v $(ROOT_DIR)/upac-cli/target/debug/upac \
	        $(DIST_DIR)/bin/
	@echo "--- Done: $(DIST_DIR) ---"
	@ls -lh $(DIST_DIR)/lib/ $(DIST_DIR)/bin/

# ── Arch пакет ────────────────────────────────────────────────────────────────

pkg-arch: build
	@# Проверяем что мы на Arch Linux
	@if [ ! -f /etc/arch-release ]; then \
		echo "error: pkg-arch requires Arch Linux"; \
		exit 1; \
	fi
	@echo "--- Building Arch package v$(VERSION) ---"
	@mkdir -p $(PKG_DIR)/arch/root/usr/bin
	@mkdir -p $(PKG_DIR)/arch/root/usr/lib
	@mkdir -p $(PKG_DIR)/arch/root/etc/upac
	@cp $(ROOT_DIR)/upac-cli/target/debug/upac \
	    $(PKG_DIR)/arch/root/usr/bin/
	@cp $(ROOT_DIR)/upac-lib/zig-out/lib/libupac.so \
	    $(PKG_DIR)/arch/root/usr/lib/
	@cp $(ROOT_DIR)/upac-alpm-backend/zig-out/lib/libupac-backend-arch.so \
	    $(PKG_DIR)/arch/root/usr/lib/
	@cp $(ROOT_DIR)/config.toml.example \
	    $(PKG_DIR)/arch/root/etc/upac/
	@cp $(ROOT_DIR)/PKGBUILD $(PKG_DIR)/arch/
	@cd $(PKG_DIR)/arch && makepkg --nodeps --noconfirm
	@echo "--- Package built: $(PKG_DIR)/arch/$(PKG_NAME).pkg.tar.zst ---"

# ── Очистка ───────────────────────────────────────────────────────────────────

clean:
	@echo "--- Cleaning build artifacts ---"
	rm -rf $(ROOT_DIR)/upac-lib/zig-out
	rm -rf $(ROOT_DIR)/upac-lib/.zig-cache
	rm -rf $(ROOT_DIR)/upac-alpm-backend/zig-out
	rm -rf $(ROOT_DIR)/upac-alpm-backend/.zig-cache
	cd $(ROOT_DIR)/upac-cli && cargo clean

distclean: clean
	@echo "--- Cleaning dist and packages ---"
	rm -rf $(DIST_DIR)
	rm -rf $(PKG_DIR)
