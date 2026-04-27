// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

// ── Errors ────────────────────────────────────────────────────────────────────
pub const IndexError = error{
    MalformedEntry,
    AllocFailed,
};

// ── IndexEntry ────────────────────────────────────────────────────────────────
pub const IndexEntry = struct {
    name: []const u8,
    checksum: []const u8,

    source_offset: usize,
    source_len: usize,
};

// ── Public API ─────────────────────────────────────────────────────────────
// Ищет пакет по имени в теле коммита. Возвращает null если не найден
pub fn find(content: []const u8, package_name: []const u8, allocator: std.mem.Allocator) IndexError!?IndexEntry {
    const package_name_lower = std.ascii.allocLowerString(allocator, package_name) catch return IndexError.AllocFailed;
    defer allocator.free(package_name_lower);

    var pos: usize = 0;
    while (pos < content.len) {
        while (pos < content.len and content[pos] == '\n') pos += 1;
        if (pos >= content.len) break;

        const line_start = pos;

        const name_start = pos;
        while (pos < content.len and content[pos] != ' ' and content[pos] != '\t' and content[pos] != '\n') pos += 1;
        if (pos >= content.len or content[pos] == '\n') return IndexError.MalformedEntry;

        const name_end = pos;
        pos += 1;

        const checksum_start = pos;
        while (pos < content.len and content[pos] != '\n') pos += 1;
        const checksum_end = pos;

        if (pos < content.len) pos += 1;

        const name_slice = content[name_start..name_end];
        const checksum_slice = std.mem.trim(u8, content[checksum_start..checksum_end], " \t\r");

        if (checksum_slice.len == 0) return IndexError.MalformedEntry;

        if (asciiEqlLower(name_slice, package_name_lower)) {
            return IndexEntry{
                .name = name_slice,
                .checksum = checksum_slice,
                .source_offset = line_start,
                .source_len = pos - line_start,
            };
        }
    }

    return null;
}

pub fn append(content: []const u8, package_name: []const u8, checksum: []const u8, allocator: std.mem.Allocator) IndexError![]u8 {
    const package_name_lower = std.ascii.allocLowerString(allocator, package_name) catch return IndexError.AllocFailed;
    defer allocator.free(package_name_lower);

    const separator: []const u8 = if (content.len > 0 and content[content.len - 1] != '\n') "\n" else "";

    return std.mem.concat(allocator, u8, &.{
        content,
        separator,
        package_name_lower,
        " ",
        checksum,
        "\n",
    }) catch IndexError.AllocFailed;
}

pub fn remove(content: []const u8, entry: IndexEntry, allocator: std.mem.Allocator) IndexError![]u8 {
    const end = entry.source_offset + entry.source_len;
    if (end > content.len) return IndexError.MalformedEntry;

    return std.mem.concat(allocator, u8, &.{
        content[0..entry.source_offset],
        content[end..],
    }) catch IndexError.AllocFailed;
}

// ── Private helpers ───────────────────────────────────────────────────────────
fn asciiEqlLower(a: []const u8, b_lower: []const u8) bool {
    if (a.len != b_lower.len) return false;
    for (a, b_lower) |ca, cb| {
        if (std.ascii.toLower(ca) != cb) return false;
    }
    return true;
}
