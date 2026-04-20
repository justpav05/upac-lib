// ── Imports ─────────────────────────────────────────────────────────────────────
const index = @import("index.zig");
const database = @import("database.zig");

// ── Export types ─────────────────────────────────────────────────────────────────────
pub const IndexEntry = index.IndexEntry;
pub const IndexError = index.IndexError;
pub const IndexFSMStateId = index.IndexFSMStateId;

pub const FileMap = database.FileMap;
pub const DatabaseError = database.DatabaseError;

// ── Export index API ─────────────────────────────────────────────────────────────────
pub const find = index.find;

pub const append = index.append;

pub const remove = index.remove;

// ── Export database API ──────────────────────────────────────────────────────────────
pub const writePackage = database.writePackage;

pub const readMeta = database.readMeta;

pub const readFiles = database.readFiles;

pub const freeFileMap = database.freeFileMap;
pub const freePackageMeta = database.freePackageMeta;
