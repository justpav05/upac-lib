ROOT_DIR  := $(shell pwd)
PKG_DIR   := $(ROOT_DIR)/pkg

MODE ?= debug
ARCH		:= x86_64
HOST_ARCH	:= $(shell uname -m)
VERSION		:= $(shell grep '^version' $(ROOT_DIR)/upac-cli/Cargo.toml | head -1 | sed 's/.*"\(.*\)".*/\1/')
PKG_NAME	:= upac-$(VERSION)-$(ARCH)

OUT_BUILD_DIR	:= $(ROOT_DIR)/build/$(MODE)

LIBC ?= gnu

RUSTFLAGS := -C prefer-dynamic=false
CARGO_TARGET ?= $(ARCH)-unknown-linux-$(LIBC)

.PHONY: all build prepare build-lib build-backends build-cli build-removing pkg-arch pkg-rpm pkg-deb clean clean-build clean-pkg

# ── Defining compilation flags ────────────────────────────────────────────────────────────────────
ifeq ($(MODE), release)
    ZIG_FLAGS   := -Doptimize=ReleaseSafe --verbose-link
    CARGO_FLAGS := --release
    RB_DIR      := release
else
    ZIG_FLAGS   :=
    CARGO_FLAGS :=
    RB_DIR      := debug
endif

ifeq ($(LIBC), musl)
    RUSTFLAGS += -C target-feature=+crt-static
endif

ifeq ($(ARCH), aarch64)
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = aarch64-linux-gnu-gcc
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER = aarch64-linux-gnu-gcc
endif

ifeq ($(ARCH), $(HOST_ARCH))
    ZIG_TARGET := native
else
    ZIG_TARGET := $(ARCH)-linux-$(LIBC)
endif

# ── Building ────────────────────────────────────────────────────────────────────
build: prepare build-lib build-backends build-cli build-removing

prepare:
	@echo "--- Preparing directories for building ($(MODE)) ---"
	@mkdir -p $(OUT_BUILD_DIR)/bin
	@mkdir -p $(OUT_BUILD_DIR)/lib

build-lib:
	@echo "--- Building upac-lib ($(MODE)) ---"
	cd $(ROOT_DIR)/upac-lib && zig build --prefix $(OUT_BUILD_DIR) -Dtarget=$(ZIG_TARGET) $(ZIG_FLAGS)

build-backends:
	@echo "--- Building upac-alpm ($(MODE)) ---"
	cd $(ROOT_DIR)/upac-alpm && zig build --prefix $(OUT_BUILD_DIR) -Dtarget=$(ZIG_TARGET) $(ZIG_FLAGS)
	@echo "--- Building upac-rpm ($(MODE)) ---"
	cd $(ROOT_DIR)/upac-rpm && zig build --prefix $(OUT_BUILD_DIR) -Dtarget=$(ZIG_TARGET) $(ZIG_FLAGS)
	@echo "--- Building upac-deb ($(MODE)) ---"
	cd $(ROOT_DIR)/upac-deb && zig build --prefix $(OUT_BUILD_DIR) -Dtarget=$(ZIG_TARGET) $(ZIG_FLAGS)

build-cli:
	@echo "--- Building upac-cli ($(MODE)) ($(CARGO_TARGET)) ---"
	cd $(ROOT_DIR)/upac-cli && RUSTFLAGS="$(RUSTFLAGS)" cargo build --target $(CARGO_TARGET) --target-dir $(OUT_BUILD_DIR) $(CARGO_FLAGS)
	cp $(OUT_BUILD_DIR)/$(CARGO_TARGET)/$(RB_DIR)/upac $(OUT_BUILD_DIR)/bin/

build-removing:
	@echo "--- Removing building temp directory ($(MODE)) ($(CARGO_TARGET)) ---"
	rm -rf $(OUT_BUILD_DIR)/$(CARGO_TARGET)
	rm -rf $(OUT_BUILD_DIR)/debug
	rm -rf $(OUT_BUILD_DIR)/.rustc_info.json

# ── ARCH package ────────────────────────────────────────────────────────────────
pkg-arch: build
	@if [ ! -f /etc/arch-release ]; then \
		echo "error: pkg-arch requires Arch Linux"; \
		exit 1; \
	fi

	@echo "--- Building Arch package v$(VERSION) ---"
	@echo "--- Making temp directories ---"
	@mkdir -p $(PKG_DIR)/arch/root/usr/bin
	@mkdir -p $(PKG_DIR)/arch/root/usr/lib
	@mkdir -p $(PKG_DIR)/arch/root/etc/upac

	@echo "--- Copying PKGBUILD v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/arch/PKGBUILD $(PKG_DIR)/arch/

	@echo "--- Copying config example file v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/arch/root/etc/upac/

	@echo "--- Copying cli v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/bin/upac $(PKG_DIR)/arch/root/usr/bin/

	@echo "--- Copying core lib v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac.so $(PKG_DIR)/arch/root/usr/lib/

	@echo "--- Copying backends v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac-arch.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(OUT_BUILD_DIR)/lib/libupac-rpm.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(OUT_BUILD_DIR)/lib/libupac-deb.so $(PKG_DIR)/arch/root/usr/lib/

	@echo "--- Building Arch package v$(VERSION) ---"
	@cd $(PKG_DIR)/arch && makepkg --nodeps --noconfirm -f

	@echo "--- Package built: $(PKG_DIR)/arch/$(PKG_NAME).pkg.tar.zst ---"

# ── RPM package ─────────────────────────────────────────────────────────────────
pkg-rpm: build
	@# Проверяем что есть rpmbuild

	@if ! command -v rpmbuild &> /dev/null; then \
		echo "error: pkg-rpm requires rpmbuild (install rpm-build)"; \
		exit 1; \
	fi

	@echo "--- Building RPM package v$(VERSION) ---"
	@echo "--- Making temp directories ---"
	@mkdir -p $(PKG_DIR)/rpm/{BUILD,RPMS,SOURCES,SPECS}
	@mkdir -p $(PKG_DIR)/rpm/root/usr/{bin,lib}
	@mkdir -p $(PKG_DIR)/rpm/root/etc/upac

	@echo "--- Copying .spec v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/rpm/upac.spec $(PKG_DIR)/rpm/SPECS/

	@echo "--- Copying config example file v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/rpm/root/etc/upac/

	@echo "--- Copying cli v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/bin/upac $(PKG_DIR)/rpm/root/usr/bin/

	@echo "--- Copying libs to temp directories v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac*.so $(PKG_DIR)/rpm/root/usr/lib/

	@echo "--- Building RPM package ---"
	@rpmbuild -bb \
		--define "_topdir $(PKG_DIR)/rpm" \
		--define "_rpmdir $(PKG_DIR)/rpm/RPMS" \
		--define "version $(VERSION)" \
		$(PKG_DIR)/rpm/SPECS/upac.spec
	@echo "--- Package built: $(PKG_DIR)/rpm/RPMS/x86_64/upac-$(VERSION)-1.$(ARCH).rpm ---"

# ── DEB package ─────────────────────────────────────────────────────────────────
pkg-deb:
	@echo "--- Building DEB package v$(VERSION) ---"
	@echo "--- Making temp directories ---"
	@mkdir -p $(PKG_DIR)/deb/DEBIAN
	@mkdir -p $(PKG_DIR)/deb/usr/{bin,lib}
	@mkdir -p $(PKG_DIR)/deb/etc/upac

	@echo "--- Copying deb files v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/deb/control $(PKG_DIR)/deb/DEBIAN/control
	@cp $(ROOT_DIR)/pkg-specs/deb/install $(PKG_DIR)/deb/DEBIAN/install
	@cp $(ROOT_DIR)/pkg-specs/deb/changelog $(PKG_DIR)/deb/DEBIAN/changelog

	@echo "--- Copying config.toml v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/deb/etc/upac/

	@echo "--- Copying cli files v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/bin/upac $(PKG_DIR)/deb/usr/bin/

	@echo "--- Copying libs v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac*.so $(PKG_DIR)/deb/usr/lib/

	@echo "--- Making deb rules v$(VERSION) ---"
	@echo '#!/usr/bin/make -f' > $(PKG_DIR)/deb/DEBIAN/rules
	@echo '%:' >> $(PKG_DIR)/deb/DEBIAN/rules
	@echo '	dh $$@' >> $(PKG_DIR)/deb/DEBIAN/rules
	@chmod +x $(PKG_DIR)/deb/DEBIAN/rules

	@echo "--- Copying upac files v$(VERSION) ---"
	@cp -r $(ROOT_DIR)/upac-* $(PKG_DIR)/deb/
	@cp $(ROOT_DIR)/Makefile $(PKG_DIR)/deb/
	@cd $(PKG_DIR)/deb && dpkg-buildpackage -us -uc -b

# ── Cleaning ───────────────────────────────────────────────────────────────────
clean: clean-build clean-pkg

clean-build:
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

	@echo "--- Cleaning global .zig-cache ---"
	rm -rf $(ROOT_DIR)/.zig-cache

	@echo "--- Cleaning upac-cli build artifacts ---"
	cd $(ROOT_DIR)/upac-cli && cargo clean

clean-pkg:
	@echo "--- Cleaning package building artifacts ---"
	rm -rf $(PKG_DIR)
