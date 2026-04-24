// ── Imports ─────────────────────────────────────────────────────────────────────
const std = @import("std");

// ── File index format ───────────────────────────────────────────────────
//   ffmpeg a3f9b1c2d4e5...
//   zlib   deadbeef1234...

// ── Errors ────────────────────────────────────────────────────────────────────
pub const IndexError = error{
    MalformedEntry,
    ReadFailed,
    WriteFailed,
};

// ── IndexEntry ────────────────────────────────────────────────────────────────
pub const IndexEntry = struct {
    name: []const u8,
    checksum: []const u8,

    source_offset: usize,
    source_len: usize,
};

// ── IndexFSMStateId ───────────────────────────────────────────────────────────
pub const IndexFSMStateId = enum {
    start,

    line_start,
    reading_name,
    skip_line,
    reading_checksum,

    done,
    not_found,
};

// ── IndexFSM ──────────────────────────────────────────────────────────────────
const IndexFSM = struct {
    current_character_position: usize,
    line_start_offset: usize,

    target_package_name: []const u8,
    package_content: []const u8,

    name_start: usize,
    name_end: usize,

    result: ?IndexEntry,

    stack: std.ArrayList(IndexFSMStateId),
    allocator: std.mem.Allocator,

    // Adds the ID of the new state to the automaton's stack
    fn enter(self: *IndexFSM, state_id: IndexFSMStateId) IndexError!void {
        try self.stack.append(state_id);
    }

    // Returns the current character from the content being processed, or null if the end has been reached
    fn currentChar(self: *const IndexFSM) ?u8 {
        if (self.current_character_position >= self.package_content.len) return null;
        return self.package_content[self.current_character_position];
    }

    // Advances the current position pointer by one character
    fn advance(self: *IndexFSM) void {
        if (self.current_character_position < self.package_content.len)
            self.current_character_position += 1;
    }

    fn check(self: *IndexFSM, value: anytype, comptime err: IndexError) IndexError!@typeInfo(@TypeOf(value)).ErrorUnion.payload {
        _ = self;
        return value catch err;
    }

    fn unwrap(self: *IndexFSM, value: anytype, comptime err: IndexError) IndexError!@typeInfo(@TypeOf(value)).Optional.child {
        _ = self;
        return value orelse err;
    }

    // Initializes the automaton structure and initiates the content parsing process
    fn run(content: []const u8, package_name: []const u8, allocator: std.mem.Allocator) IndexError!?IndexEntry {
        const package_name_lower = try std.ascii.allocLowerString(allocator, package_name);
        defer allocator.free(package_name_lower);

        var machine = IndexFSM{
            .current_character_position = 0,

            .target_package_name = package_name_lower,
            .package_content = content,
            .line_start_offset = 0,

            .name_start = 0,
            .name_end = 0,

            .result = null,

            .stack = std.ArrayList(IndexFSMStateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.stack.deinit();

        try stateLineStart(&machine);
        return machine.result;
    }
};

// ── FSM states ────────────────────────────────────────────────────────────────
// Checks the beginning of the line for characters or an end-of-file indicator
fn stateLineStart(machine: *IndexFSM) anyerror!void {
    try machine.enter(.line_start);

    while (machine.currentChar() == '\n') machine.advance();

    if (machine.currentChar() == null) {
        try machine.enter(.not_found);
        return;
    }

    machine.line_start_offset = machine.current_character_position;
    machine.name_start = machine.current_character_position;
    return stateReadingName(machine);
}

// Reads the package name up to the first space and compares it with the target
fn stateReadingName(machine: *IndexFSM) anyerror!void {
    try machine.enter(.reading_name);

    while (machine.currentChar()) |char| {
        if (char == ' ' or char == '\t') break;
        if (char == '\n') return IndexError.MalformedEntry;
        machine.advance();
    }

    if (machine.currentChar() == null) return IndexError.MalformedEntry;

    machine.name_end = machine.current_character_position;
    machine.advance();

    const name_slice = machine.package_content[machine.name_start..machine.name_end];

    if (!asciiEqlLower(name_slice, machine.target_package_name)) return stateSkipLine(machine);
    return stateReadingChecksum(machine);
}

// Skips the current line if the package name does not match
fn stateSkipLine(machine: *IndexFSM) anyerror!void {
    try machine.enter(.skip_line);

    while (machine.currentChar()) |char| {
        machine.advance();
        if (char == '\n') break;
    }

    return stateLineStart(machine);
}

// Reads the packet checksum, calculates the source line length, and saves the result to IndexEntry
fn stateReadingChecksum(machine: *IndexFSM) anyerror!void {
    try machine.enter(.reading_checksum);

    const checksum_start = machine.current_character_position;

    while (machine.currentChar()) |char| {
        if (char == '\n' or char == ' ' or char == '\t') break;
        machine.advance();
    }

    const checksum_end = machine.current_character_position;
    if (checksum_end == checksum_start) return IndexError.MalformedEntry;

    if (machine.currentChar() == '\n') machine.advance();

    const source_len = machine.current_character_position - machine.line_start_offset;

    machine.result = IndexEntry{
        .name = machine.package_content[machine.name_start..machine.name_end],
        .checksum = machine.package_content[checksum_start..checksum_end],
        .source_offset = machine.line_start_offset,
        .source_len = source_len,
    };

    try machine.enter(.done);
}

// ── Public API ─────────────────────────────────────────────────────────────
// A public interface for searching the index for an entry by package name. Launches the FSM
pub fn find(content: []const u8, package_name: []const u8, allocator: std.mem.Allocator) IndexError!?IndexEntry {
    return IndexFSM.run(content, package_name, allocator);
}

// Appends a new line containing the package name and its hash to the end of the index file. If the file does not exist, it will be created
pub fn append(index_path: []const u8, package_name: []const u8, checksum: []const u8, allocator: std.mem.Allocator) IndexError!void {
    const package_name_lower = try check(std.ascii.allocLowerString(allocator, package_name), IndexError.WriteFailed);
    defer allocator.free(package_name_lower);

    const file = std.fs.openFileAbsolute(index_path, .{ .mode = .read_write }) catch try check(std.fs.createFileAbsolute(index_path, .{}), IndexError.WriteFailed);
    defer file.close();

    try check(file.seekFromEnd(0), IndexError.WriteFailed);
    try check(file.writer().print("{s} {s}\n", .{ package_name_lower, checksum }), IndexError.WriteFailed);
}

// Removes an entry from the index. The function reads the entire file, extracts the segment corresponding to the entry to be deleted (using the offset and length), and overwrites the file
pub fn remove(index_path: []const u8, entry: IndexEntry, allocator: std.mem.Allocator) IndexError!void {
    const content = try check(std.fs.cwd().readFileAlloc(allocator, index_path, 16 * 1024 * 1024), IndexError.ReadFailed);
    defer allocator.free(content);

    const end = entry.source_offset + entry.source_len;
    if (end > content.len) return IndexError.MalformedEntry;

    const new_content = try check(std.mem.concat(allocator, u8, &.{ content[0..entry.source_offset], content[end..] }), IndexError.WriteFailed);
    defer allocator.free(new_content);

    const file = try check(std.fs.createFileAbsolute(index_path, .{}), IndexError.WriteFailed);
    defer file.close();

    try check(file.writeAll(new_content), IndexError.WriteFailed);
}

// ── Private helpers ───────────────────────────────────────────────────────────
// A helper function for case-insensitive string comparison
inline fn check(value: anytype, comptime err: IndexError) IndexError!@typeInfo(@TypeOf(value)).ErrorUnion.payload {
    return value catch err;
}

fn asciiEqlLower(first_string: []const u8, second_string: []const u8) bool {
    if (first_string.len != second_string.len) return false;
    for (first_string, second_string) |first_string_c, second_string_c| {
        if (std.ascii.toLower(first_string_c) != second_string_c) return false;
    }
    return true;
}
