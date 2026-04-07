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
	@echo "--- Building upac-alpm ---"
	cd $(ROOT_DIR)/upac-alpm && zig build --prefix zig-out
	@echo "--- Building upac-rpm ---"
	cd $(ROOT_DIR)/upac-rpm && zig build --prefix zig-out
	@echo "--- Building upac-deb ---"
	cd $(ROOT_DIR)/upac-deb && zig build --prefix zig-out

build-cli:
	@echo "--- Building upac-cli ---"
	cd $(ROOT_DIR)/upac-cli && RUSTFLAGS="-C prefer-dynamic=false" cargo build --target x86_64-unknown-linux-gnu

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

	@cp $(ROOT_DIR)/pkg-specs/arch/PKGBUILD $(PKG_DIR)/arch/
	@echo "--- Copying cli v$(VERSION) ---"
	@cp $(ROOT_DIR)/upac-cli/target/x86_64-unknown-linux-gnu/debug/upac $(PKG_DIR)/arch/root/usr/bin/
	@echo "--- Copying core lib v$(VERSION) ---"
	@cp $(ROOT_DIR)/upac-lib/zig-out/lib/libupac.so $(PKG_DIR)/arch/root/usr/lib/
	@echo "--- Copying backends v$(VERSION) ---"
	@cp $(ROOT_DIR)/upac-alpm/zig-out/lib/libupac-arch.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(ROOT_DIR)/upac-rpm/zig-out/lib/libupac-rpm.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(ROOT_DIR)/upac-deb/zig-out/lib/libupac-deb.so $(PKG_DIR)/arch/root/usr/lib/
	@echo "--- Copying config example file v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/arch/root/etc/upac/
	@echo "--- Building Arch package v$(VERSION) ---"
	@cd $(PKG_DIR)/arch && makepkg --nodeps --noconfirm -f
	@echo "--- Package built: $(PKG_DIR)/arch/$(PKG_NAME).pkg.tar.zst ---"

# ── RPM пакет ─────────────────────────────────────────────────────────────────
pkg-rpm: build
	@# Проверяем что есть rpmbuild
	@if ! command -v rpmbuild &> /dev/null; then \
		echo "error: pkg-rpm requires rpmbuild (install rpm-build)"; \
		exit 1; \
	fi
	@echo "--- Building RPM package v$(VERSION) ---"
	@mkdir -p $(PKG_DIR)/rpm/BUILD
	@mkdir -p $(PKG_DIR)/rpm/RPMS
	@mkdir -p $(PKG_DIR)/rpm/SOURCES
	@mkdir -p $(PKG_DIR)/rpm/SPECS
	@mkdir -p $(PKG_DIR)/rpm/root/usr/bin
	@mkdir -p $(PKG_DIR)/rpm/root/usr/lib
	@mkdir -p $(PKG_DIR)/rpm/root/etc/upac
	@cp $(ROOT_DIR)/pkg-specs/rpm/upac.spec $(PKG_DIR)/rpm/SPECS/
	@cp $(ROOT_DIR)/upac-cli/target/x86_64-unknown-linux-gnu/debug/upac \
	    $(PKG_DIR)/rpm/root/usr/bin/
	@cp $(ROOT_DIR)/upac-lib/zig-out/lib/libupac.so \
	    $(PKG_DIR)/rpm/root/usr/lib/
	@cp $(ROOT_DIR)/upac-alpm-backend/zig-out/lib/libupac-backend-arch.so \
	    $(PKG_DIR)/rpm/root/usr/lib/
	@cp $(ROOT_DIR)/upac-rpm-backend/zig-out/lib/libupac-backend-rpm.so \
	    $(PKG_DIR)/rpm/root/usr/lib/
	@cp $(ROOT_DIR)/upac-deb-backend/zig-out/lib/libupac-backend-deb.so \
	    $(PKG_DIR)/rpm/root/usr/lib/
	@cp $(ROOT_DIR)/config.toml.example \
	    $(PKG_DIR)/rpm/root/etc/upac/
	@rpmbuild -bb \
		--define "_topdir $(PKG_DIR)/rpm" \
		--define "_rpmdir $(PKG_DIR)/rpm/RPMS" \
		--define "version $(VERSION)" \
		$(PKG_DIR)/rpm/SPECS/upac.spec
	@echo "--- Package built: $(PKG_DIR)/rpm/RPMS/x86_64/upac-$(VERSION)-1.x86_64.rpm ---"

# ── Очистка ───────────────────────────────────────────────────────────────────
clean:
	@echo "--- Cleaning build artifacts ---"
	@echo "--- Cleaning upac-lib build artifacts ---"
	rm -rf $(ROOT_DIR)/upac-lib/zig-out
	rm -rf $(ROOT_DIR)/upac-lib/.zig-cache
	@echo "--- Cleaning upac-alpm build artifacts ---"
	rm -rf $(ROOT_DIR)/upac-alpm/.zig-cache
	rm -rf $(ROOT_DIR)/upac-alpm/zig-out
	@echo "--- Cleaning upac-rpm build artifacts ---"
	rm -rf $(ROOT_DIR)/upac-rpm/.zig-cache
	rm -rf $(ROOT_DIR)/upac-rpm/zig-out
	@echo "--- Cleaning upac-deb build artifacts ---"
	rm -rf $(ROOT_DIR)/upac-deb/.zig-cache
	rm -rf $(ROOT_DIR)/upac-deb/zig-out
	@echo "--- Cleaning upac-cli build artifacts ---"
	cd $(ROOT_DIR)/upac-cli && cargo clean
