const db = @import("upac-database");
const PackageMeta = db.PackageMeta;

// ── Публичные типы ────────────────────────────────────────────────────────────

pub const OstreeCommitRequest = struct {
    repo_path: []const u8,
    content_path: []const u8,
    branch: []const u8,
    operation: []const u8,
    packages: []const PackageMeta,
    db_path: []const u8,
};

pub const DiffEntry = struct {
    path: []const u8,
    kind: DiffKind,
};

pub const DiffKind = enum { added, removed, modified };

pub const OstreeError = error{
    RepoOpenFailed,
    CommitFailed,
    DiffFailed,
    RollbackFailed,
    NoPreviousCommit,
    Unexpected,
};
