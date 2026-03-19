ROOT_DIR := $(CURDIR)

.PHONY: all lib backends cli clean

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

clean:
	rm -rf $(ROOT_DIR)/upac-lib/zig-out $(ROOT_DIR)/upac-lib/.zig-cache
	rm -rf $(ROOT_DIR)/upac-alpm-backend/zig-out $(ROOT_DIR)/upac-alpm-backend/.zig-cache
	cd $(ROOT_DIR)/upac-cli && cargo clean
