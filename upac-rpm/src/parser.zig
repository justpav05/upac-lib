// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

// ── Contains RPM magic bytes and header magic bytes ─────────────────────────────────────────────────────────────
const rpm_magic: [4]u8 = .{ 0xED, 0xAB, 0xEE, 0xDB };
const header_magic: [3]u8 = .{ 0x8E, 0xAD, 0xE8 };

// Represents an RPM tag, identified by its numeric tag ID
const RpmTag = enum(u32) {
    name = 1000,
    version = 1001,
    release = 1002,
    summary = 1004,
    description = 1005,
    license = 1014,
    url = 1020,
    packager = 1022,
    _,
};

// Represents the type of an RPM tag value
const RpmTagType = enum(u32) {
    null_type = 0,
    char = 1,
    int8 = 2,
    int16 = 3,
    int32 = 4,
    int64 = 5,
    string = 6,
    binary = 7,
    string_array = 8,
    i18n_string = 9,
    _,
};

// ── Public types ────────────────────────────────────────────────────────────
// Contains metadata extracted from the RPM package header
pub const RpmHeader = struct {
    name: ?[]const u8,
    version: ?[]const u8,
    release: ?[]const u8,
    summary: ?[]const u8,
    license: ?[]const u8,
    url: ?[]const u8,
    packager: ?[]const u8,

    // Frees the memory allocated for the header fields
    pub fn deinit(self: *RpmHeader, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.release) |value| allocator.free(value);
        if (self.summary) |value| allocator.free(value);
        if (self.license) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        if (self.packager) |value| allocator.free(value);
    }
};

// ── Parser ────────────────────────────────────────────────────────────────────
// Main entry point for RPM parsing: verifies the signature and reads the headers.
pub fn parseHeader(allocator: std.mem.Allocator, file: std.fs.File) !RpmHeader {
    try verifyMagic(file);
    try skipLeadSection(file);
    try skipSignatureSection(allocator, file);

    return try readHeaderSection(allocator, file);
}

// ── Internal functions ────────────────────────────────────────────────────────
// Checks for the presence of the RPM magic number (0xEDAB EEDB) at the beginning of the file
fn verifyMagic(file: std.fs.File) !void {
    var magic_buffer: [4]u8 = undefined;
    const bytes_read = try file.read(&magic_buffer);

    if (bytes_read < 4 or !std.mem.eql(u8, &magic_buffer, &rpm_magic)) {
        return error.InvalidRpmMagic;
    }
}

// Skips the obsolete Lead section (96 bytes) used in old RPM formats
fn skipLeadSection(file: std.fs.File) !void {
    try file.seekBy(96 - 4);
}

// Skips the digital signature section, accounting for its header, data, and alignment
fn skipSignatureSection(allocator: std.mem.Allocator, file: std.fs.File) !void {
    var section_header_buffer: [8]u8 = undefined;
    try file.reader().readNoEof(&section_header_buffer);

    if (!std.mem.eql(u8, section_header_buffer[0..3], &header_magic)) {
        return error.InvalidSignatureMagic;
    }

    var count_buffer: [4]u8 = undefined;
    try file.reader().readNoEof(&count_buffer);
    const tag_count = std.mem.readInt(u32, &count_buffer, .big);

    var size_buffer: [4]u8 = undefined;
    try file.reader().readNoEof(&size_buffer);
    const data_size = std.mem.readInt(u32, &size_buffer, .big);

    const tags_size = tag_count * 16;

    const skip_buffer = try allocator.alloc(u8, tags_size + data_size);
    defer allocator.free(skip_buffer);
    try file.reader().readNoEof(skip_buffer);

    const total_size = 16 + tags_size + data_size;
    const alignment_remainder = total_size % 8;
    if (alignment_remainder != 0) {
        var padding: [8]u8 = undefined;
        try file.reader().readNoEof(padding[0 .. 8 - alignment_remainder]);
    }
}

// Reads the main header section, extracting the tag table and data block
fn readHeaderSection(allocator: std.mem.Allocator, file: std.fs.File) !RpmHeader {
    var section_header_buffer: [8]u8 = undefined;
    try file.reader().readNoEof(&section_header_buffer);

    if (!std.mem.eql(u8, section_header_buffer[0..3], &header_magic)) {
        return error.InvalidHeaderMagic;
    }

    var tag_count_buffer: [4]u8 = undefined;
    try file.reader().readNoEof(&tag_count_buffer);
    const tag_count = std.mem.readInt(u32, &tag_count_buffer, .big);

    var data_size_buffer: [4]u8 = undefined;
    try file.reader().readNoEof(&data_size_buffer);
    const data_size = std.mem.readInt(u32, &data_size_buffer, .big);

    const TagEntry = struct {
        tag: u32,
        tag_type: u32,
        offset: u32,
        count: u32,
    };

    const tag_entries = try allocator.alloc(TagEntry, tag_count);
    defer allocator.free(tag_entries);

    for (tag_entries) |*tag_entry| {
        var tag_buffer: [4]u8 = undefined;
        try file.reader().readNoEof(&tag_buffer);
        tag_entry.tag = std.mem.readInt(u32, &tag_buffer, .big);

        var type_buffer: [4]u8 = undefined;
        try file.reader().readNoEof(&type_buffer);
        tag_entry.tag_type = std.mem.readInt(u32, &type_buffer, .big);

        var offset_buffer: [4]u8 = undefined;
        try file.reader().readNoEof(&offset_buffer);
        tag_entry.offset = std.mem.readInt(u32, &offset_buffer, .big);

        var count_buffer: [4]u8 = undefined;
        try file.reader().readNoEof(&count_buffer);
        tag_entry.count = std.mem.readInt(u32, &count_buffer, .big);
    }

    const data_block = try allocator.alloc(u8, data_size);
    defer allocator.free(data_block);

    try file.reader().readNoEof(data_block);

    var rpm_header = RpmHeader{
        .name = null,
        .version = null,
        .release = null,
        .summary = null,
        .license = null,
        .url = null,
        .packager = null,
    };
    errdefer rpm_header.deinit(allocator);

    for (tag_entries) |tag_entry| {
        const rpm_tag = std.meta.intToEnum(RpmTag, tag_entry.tag) catch continue;

        switch (rpm_tag) {
            .name => rpm_header.name = try readString(allocator, data_block, tag_entry.offset),
            .version => rpm_header.version = try readString(allocator, data_block, tag_entry.offset),
            .release => rpm_header.release = try readString(allocator, data_block, tag_entry.offset),
            .summary => rpm_header.summary = try readString(allocator, data_block, tag_entry.offset),
            .license => rpm_header.license = try readString(allocator, data_block, tag_entry.offset),
            .url => rpm_header.url = try readString(allocator, data_block, tag_entry.offset),
            .packager => rpm_header.packager = try readString(allocator, data_block, tag_entry.offset),
            else => {},
        }
    }

    return rpm_header;
}

// Reads a null-terminated string from a data block at a specified offset
fn readString(allocator: std.mem.Allocator, data_block: []const u8, offset: u32) ![]const u8 {
    if (offset >= data_block.len) return error.InvalidTagOffset;

    const string_start = data_block[offset..];
    const null_terminator_position = std.mem.indexOfScalar(u8, string_start, 0) orelse return error.UnterminatedString;

    return allocator.dupe(u8, string_start[0..null_terminator_position]);
}
