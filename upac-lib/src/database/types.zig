// ── Публичные типы ────────────────────────────────────────────────────────────
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    url: []const u8,
    installed_at: i64,
    checksum: []const u8,
};

pub const PackageFiles = struct {
    name: []const u8,
    paths: []const []const u8,
};
