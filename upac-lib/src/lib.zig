// ── Imports ─────────────────────────────────────────────────────────────────────
const ffi_symbols = @import("symbols/ffi.zig");
pub export const request_cancel = ffi_symbols.request_cancel;
pub export const reset_cancel = ffi_symbols.reset_cancel;

pub export const deinit = ffi_symbols.deinit;

const installer_symbols = @import("symbols/installer.zig");
pub export const install = installer_symbols.install;

const uninstaller_symbols = @import("symbols/uninstaller.zig");
pub export const uninstall = uninstaller_symbols.uninstall;

const rollback_symbols = @import("symbols/rollback.zig");
pub export const rollback = rollback_symbols.rollback;

const diff_symbols = @import("symbols/diff.zig");
pub export const diff_packages = diff_symbols.diff_packages;
pub export const diff_packages_free = diff_symbols.diff_packages_free;

pub export const diff_files = diff_symbols.diff_files;
pub export const diff_files_free = diff_symbols.diff_files_free;

const list_symbols = @import("symbols/list.zig");
pub export const list_packages = list_symbols.list_packages;

pub export const packages_count = list_symbols.packages_count;
pub export const packages_free = list_symbols.packages_free;
pub export const package_get_slice_field = list_symbols.package_get_slice_field;
pub export const package_get_int_field = list_symbols.package_get_int_field;

pub export const list_commits = list_symbols.list_commits;
pub export const commits_free = list_symbols.commits_free;

const init_symbols = @import("symbols/init.zig");
pub export const init = init_symbols.init;
