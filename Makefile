ROOT_DIR  := $(CURDIR)
DIST_DIR  := $(HOME)/Документы/upac

.PHONY: all lib backends cli dist clean

all: lib backends cli

lib:
	@echo "--- Building upac-lib ---"
	cd $(ROOT_DIR)/upac-lib && zig build --prefix zig-out

backends:
	@echo "--- Building upac-backend-arch ---"
	cd $(ROOT_DIR)/upac-alpm-backend && zig build --prefix zig-out

cli:
	@echo "--- Building upac-cli ---"
	cd $(ROOT_DIR)/upac-cli && cargo build

dist: all
	@echo "--- Copying artifacts to $(DIST_DIR) ---"
	@mkdir -p $(DIST_DIR)/lib
	@mkdir -p $(DIST_DIR)/bin
	@cp -v $(ROOT_DIR)/upac-lib/zig-out/lib/libupac.so              $(DIST_DIR)/lib/
	@cp -v $(ROOT_DIR)/upac-alpm-backend/zig-out/lib/libupac-backend-arch.so $(DIST_DIR)/lib/
	@cp -v $(ROOT_DIR)/upac-cli/target/debug/upac-cli                   $(DIST_DIR)/bin/
	@echo "--- Done: $(DIST_DIR) ---"
	@ls -lh $(DIST_DIR)/lib/ $(DIST_DIR)/bin/

clean:
	rm -rf $(ROOT_DIR)/upac-lib/zig-out $(ROOT_DIR)/upac-lib/.zig-cache
	rm -rf $(ROOT_DIR)/upac-alpm-backend/zig-out $(ROOT_DIR)/upac-alpm-backend/.zig-cache
	cd $(ROOT_DIR)/upac-cli && cargo clean
	rm -rf $(DIST_DIR)
