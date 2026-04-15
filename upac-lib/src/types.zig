const std = @import("std");

// ── Package ─────────────────────────────────────────────────────────────────────
// An aggregating structure containing metadata and a list of all files belonging to the package
pub const Package = struct {
    meta: PackageMeta,
    files: []const PackageFile,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        self.meta.deinit(allocator);
        for (self.files) |package_file| package_file.deinit(allocator);
        allocator.free(self.files);
    }
};

// Stores detailed information: version, author, description, license, installation time and etc
pub const PackageMeta = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    url: []const u8,
    installed_at: i64,
    checksum: []const u8,

    // Deinitialization methods that guarantee the release of memory allocated for dynamic strings
    pub fn deinit(self: *PackageMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.author);
        allocator.free(self.description);
        allocator.free(self.license);
        allocator.free(self.url);
        allocator.free(self.checksum);
    }
};

// A simple structure for linking a file path in the system to its checksum
pub const PackageFile = struct {
    path: []const u8,
    checksum: []const u8,

    // Deinitialization methods that guarantee the release of memory allocated for dynamic strings
    pub fn deinit(self: *PackageFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.checksum);
    }
};

pub const PackageDiffKind = enum { added, removed, updated };

pub const PackageDiffEntry = struct {
    name: []const u8,
    kind: PackageDiffKind,
};

pub const AttributedDiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
    package_name: []const u8,
};

// A structure for storing information about a specific "restore point"
pub const CommitEntry = struct {
    checksum: []const u8,
    subject: []const u8,
};

// Listing of file change types: added, removed, modified
pub const DiffKind = enum { added, removed, modified };

// Description of the specific change: the file path and exactly what happened to it
pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
};
