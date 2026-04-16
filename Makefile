ROOT_DIR    := $(shell pwd)
PKG_DIR     := $(ROOT_DIR)/pkg
OUT_BUILD_DIR := $(ROOT_DIR)/build

VERSION     := $(shell grep '^version' $(ROOT_DIR)/upac-cli/Cargo.toml | head -1 | sed 's/.*"\(.*\)".*/\1/')
PKG_NAME    := upac-$(VERSION)-$(ARCH)

MODE        ?= debug
CPU         ?= native

CARGO_TARGET ?= $(shell rustc -Vv | grep host | cut -d ' ' -f 2)

OSTREE_REPO := https://github.com/ostreedev/ostree.git
OSTREE_DIR  := $(ROOT_DIR)/ostree

ARCH_PKG_FLAGS  ?= --nodeps --noconfirm -f
RPM_PKG_FLAGS   ?= -bb --define "_topdir $(PKG_DIR)/rpm" \
                       --define "_rpmdir $(PKG_DIR)/rpm/RPMS" \
                       --define "version $(VERSION)"
DEB_PKG_FLAGS   ?= --root-owner-group

.PHONY: all build prepare-dirs prepare-deps \
        build-lib build-backends build-cli build-removing \
        pkg-arch pkg-rpm pkg-deb \
        sync sync-build sync-pkg \
        clean clean-build clean-pkg

# ── Compilation flags ──────────────────────────────────────────────────────────
ifeq ($(strip $(MODE)), release)
    $(info --- INFO: Building in RELEASE mode ---)
    CARGO_BUILD_FLAG := --release
    RUST_BUILD_FLAGS  := -C lto=fat -C embed-bitcode=yes -C codegen-units=1 -C panic=abort -C prefer-dynamic=false -C target-cpu=$(subst _,-,$(strip $(CPU)))
    ZIG_BUILD_FLAGS  := -Doptimize=ReleaseSafe -Dstrip=true -Dstack-check=false
    OSTREE_BUILD_CFLAGS := -O3 -flto -march=$(subst _,-,$(strip $(CPU)))
else
    $(info --- INFO: Building in DEBUG mode ---)
    CARGO_BUILD_FLAG :=
    RUST_BUILD_FLAGS  := -C debuginfo=2 -C force-frame-pointers=yes -C target-cpu=$(subst _,-,$(strip $(CPU)))
    ZIG_BUILD_FLAGS  := -Doptimize=Debug -Dstrip=false -Dstack-check=true -Dcpu=$(strip $(CPU))
    OSTREE_BUILD_CFLAGS := -g -O0
endif

export PKG_CONFIG_ALLOW_CROSS = 1

# ── Prepare ───────────────────────────────────────────────────────────────────
prepare-dirs:
	@echo "--- Preparing directories ($(MODE) / cpu=$(CPU)) ---"
	@mkdir -p $(OUT_BUILD_DIR)/bin $(OUT_BUILD_DIR)/lib
	@mkdir -p $(ROOT_DIR)/ostree

prepare-ostree:
	@echo "--- Fetching and building static ostree in $(MODE) mode ---"
	@git clone --depth 1 $(OSTREE_REPO) $(OSTREE_DIR);
	@cd $(OSTREE_DIR) && \
		env NOCONFIGURE=1 ./autogen.sh && \
		./configure \
			--enable-static \
			--disable-shared \
			--disable-rofiles-fuse \
			--without-soup \
			--without-curl \
			--without-avahi \
			--disable-man \
			CFLAGS="$(OSTREE_BUILD_CFLAGS)" && \
		$(MAKE) -j$(shell nproc)

# ── Build ─────────────────────────────────────────────────────────────────────
build: prepare-dirs prepare-ostree build-lib build-backends build-cli build-removing

build-lib:
	@echo "--- Building upac-lib in $(MODE) mode ---"
	@cd $(ROOT_DIR)/upac-lib && zig build --prefix $(OUT_BUILD_DIR) $(ZIG_BUILD_FLAGS)

build-backends:
	@echo "--- Building upac-alpm in $(MODE) mode ---"
	@cd $(ROOT_DIR)/upac-alpm && zig build --prefix $(OUT_BUILD_DIR) $(ZIG_BUILD_FLAGS)

	@echo "--- Building upac-rpm in $(MODE) mode ---"
	@cd $(ROOT_DIR)/upac-rpm && zig build --prefix $(OUT_BUILD_DIR) $(ZIG_BUILD_FLAGS)

	@echo "--- Building upac-deb in $(MODE) mode ---"
	@cd $(ROOT_DIR)/upac-deb && zig build --prefix $(OUT_BUILD_DIR) $(ZIG_BUILD_FLAGS)

build-cli:
	@cd $(ROOT_DIR)/upac-cli && \
		RUSTFLAGS="$(RUSTFLAGS)" cargo-zigbuild build \
			$(CARGO_BUILD_FLAG) \
			--target $(CARGO_TARGET) \
			--target-dir $(OUT_BUILD_DIR) \
			$(CARGO_FLAGS)
	@mv $(OUT_BUILD_DIR)/$(CARGO_TARGET)/$(MODE)/upac $(OUT_BUILD_DIR)/bin/

build-removing:
	@echo "--- Cleaning cargo temp dirs ---"
	@rm -rf $(ROOT_DIR)/ostree

	@echo "--- Cleaning cargo temp dirs ---"
	@rm -rf $(OUT_BUILD_DIR)/$(CARGO_TARGET)
	@rm -rf $(OUT_BUILD_DIR)/$(MODE)
	@rm -rf $(OUT_BUILD_DIR)/.rustc_info.json

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

	@echo "--- Syncing version: v$(VERSION) ---"
	@sed -i "s/^pkgver=.*/pkgver=$(VERSION)/" $(PKG_DIR)/arch/PKGBUILD

	@echo "--- Copying config example file v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/arch/root/etc/upac/

	@echo "--- Copying cli v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/bin/upac $(PKG_DIR)/arch/root/usr/bin/

	@echo "--- Copying core lib v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac.so $(PKG_DIR)/arch/root/usr/lib/

	@echo "--- Copying backends v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac-alpm.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(OUT_BUILD_DIR)/lib/libupac-rpm.so $(PKG_DIR)/arch/root/usr/lib/
	@cp $(OUT_BUILD_DIR)/lib/libupac-deb.so $(PKG_DIR)/arch/root/usr/lib/

	@echo "--- Building ARCH package v$(VERSION) ---"
	@cd $(PKG_DIR)/arch && makepkg $(ARCH_PKG_FLAGS)
	@mv $(PKG_DIR)/arch/*.pkg.tar.zst $(PKG_DIR)/

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

	@echo "--- Building RPM package v$(VERSION) ---"
	@rpmbuild $(RPM_PKG_FLAGS) $(PKG_DIR)/rpm/SPECS/upac.spec
	@echo "--- Package built: $(PKG_DIR)/rpm/RPMS/$(ARCH)/upac-$(VERSION)-1.$(ARCH).rpm ---"

	@echo "--- RPM package moved to $(PKG_DIR)/ ---"
	find $(PKG_DIR)/rpm/RPMS -name "*.rpm" -exec mv {} $(PKG_DIR)/ \;

# ── DEB package ─────────────────────────────────────────────────────────────────
pkg-deb: build
	@echo "--- Building DEB package v$(VERSION) ---"
	@echo "--- Making temp directories ---"
	@mkdir -p $(PKG_DIR)/deb/DEBIAN
	@mkdir -p $(PKG_DIR)/deb/usr/{bin,lib}
	@mkdir -p $(PKG_DIR)/deb/etc/upac

	@echo "--- Copying DEB files v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/deb/control $(PKG_DIR)/deb/DEBIAN/control
	@cp $(ROOT_DIR)/pkg-specs/deb/install $(PKG_DIR)/deb/DEBIAN/install
	@cp $(ROOT_DIR)/pkg-specs/deb/changelog $(PKG_DIR)/deb/DEBIAN/changelog

	@echo "--- Syncing version: v$(VERSION) ---"
	@sed -i "s/^Version: .*/Version: $(VERSION)-1/" $(PKG_DIR)/deb/DEBIAN/control
	@sed -i -E "s/^upac \([0-9\.]+-1\)/upac ($(VERSION)-1)/" $(PKG_DIR)/deb/DEBIAN/changelog
	@sed -i -E "s/>  .*/>  $(shell date -R)/" $(PKG_DIR)/deb/DEBIAN/changelog

	@echo "--- Copying config.toml v$(VERSION) ---"
	@cp $(ROOT_DIR)/pkg-specs/config.toml $(PKG_DIR)/deb/etc/upac/

	@echo "--- Copying cli files v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/bin/upac $(PKG_DIR)/deb/usr/bin/

	@echo "--- Copying libs v$(VERSION) ---"
	@cp $(OUT_BUILD_DIR)/lib/libupac*.so $(PKG_DIR)/deb/usr/lib/

	@echo "--- Making DEB rules v$(VERSION) ---"
	@echo '#!/usr/bin/make -f' > $(PKG_DIR)/deb/DEBIAN/rules
	@echo '%:' >> $(PKG_DIR)/deb/DEBIAN/rules
	@echo '	dh $$@' >> $(PKG_DIR)/deb/DEBIAN/rules
	@chmod +x $(PKG_DIR)/deb/DEBIAN/rules

	@echo "--- Building DEB package v$(VERSION) ---"
	@dpkg-deb $(DEB_PKG_FLAGS) --build $(PKG_DIR)/deb $(PKG_DIR)/upac-$(VERSION).deb

	@echo "--- Package built: $(PKG_DIR)/deb/upac_$(VERSION)-1_$(ARCH).deb ---"

# ── Version syncing ────────────────────────────────────────────────────────────
sync: sync-build sync-pkg

sync-pkg:
	@echo "--- Syncing pkg-specs to v$(VERSION) from Cargo.toml ---"
	@sed -i "s/^pkgver=.*/pkgver=$(VERSION)/" $(ROOT_DIR)/pkg-specs/arch/PKGBUILD
	@sed -i "s/^Version: .*/Version: $(VERSION)-1/" $(ROOT_DIR)/pkg-specs/deb/control
	@sed -i -E "s/^upac \([0-9\.]+-1\)/upac ($(VERSION)-1)/" $(ROOT_DIR)/pkg-specs/deb/changelog

sync-build:
	@echo "--- Syncing Zig modules to v$(VERSION) ---"
	@sed -i -E 's/\.version[[:space:]]*=[[:space:]]*"[^"]*"/\.version = "$(VERSION)"/' $(ROOT_DIR)/upac-*/build.zig.zon

# ── Cleaning ───────────────────────────────────────────────────────────────────
clean: clean-build clean-pkg

clean-build:
	@echo "--- Cleaning ostree build artifacts ---"
	@rm -rf $(ROOT_DIR)/ostree

	@echo "--- Cleaning build artifacts ---"
	@echo "--- Cleaning upac-lib build artifacts ---"
	@rm -rf $(ROOT_DIR)/upac-lib/zig-out
	@rm -rf $(ROOT_DIR)/upac-lib/.zig-cache

	@echo "--- Cleaning upac-alpm build artifacts ---"
	@rm -rf $(ROOT_DIR)/upac-alpm/.zig-cache
	@rm -rf $(ROOT_DIR)/upac-alpm/zig-out

	@echo "--- Cleaning upac-rpm build artifacts ---"
	@rm -rf $(ROOT_DIR)/upac-rpm/.zig-cache
	@rm -rf $(ROOT_DIR)/upac-rpm/zig-out

	@echo "--- Cleaning upac-deb build artifacts ---"
	@rm -rf $(ROOT_DIR)/upac-deb/.zig-cache
	@rm -rf $(ROOT_DIR)/upac-deb/zig-out

	@echo "--- Cleaning global .zig-cache ---"
	@rm -rf $(ROOT_DIR)/.zig-cache

	@echo "--- Cleaning upac-cli build artifacts ---"
	@cd $(ROOT_DIR)/upac-cli && cargo clean

	@echo "--- Cleaning build directory artifacts ---"
	@rm -rf $(ROOT_DIR)/build

clean-pkg:
	@echo "--- Cleaning package building artifacts ---"
	@rm -rf $(PKG_DIR)
