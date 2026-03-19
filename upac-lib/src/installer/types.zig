const database = @import("upac-database");

const PackageMeta = database.PackageMeta;
const PackageFiles = database.PackageFiles;

// ── Публичные типы ────────────────────────────────────────────────────────────

pub const InstallRequest = struct {
    meta: PackageMeta,
    root_path: []const u8,
    repo_path: []const u8,
    package_path: []const u8,
    db_path: []const u8,
    max_retries: u8,
};
