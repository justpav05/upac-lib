const std = @import("std");

const states = @import("states.zig");

const types = @import("upac-types");
const Package = types.Package;

// ── Errors ────────────────────────────────────────────────────────────────────
pub const ParserFSMError = error{
    UnexpectedEndOfInput,
    UnexpectedChar,
    MissingField,
    InvalidHeader,
    InvalidFilesSection,
};

// ── DatabaseFSMStateId ──────────────────────────────────────────────────────────
pub const ParserFSMStateId = enum {
    start,

    open_package,
    author,
    version,
    license,
    category,
    description,
    link,
    date,
    checksum,
    close_package,
    open_files,
    file_path_start,
    file_path_end,
    file_checksum_start,
    file_checksum_end,
    close_files,

    done,
    failed,
};

// ── DatabaseFSM ─────────────────────────────────────────────────────────────────
pub const ParserFSM = struct {
    current_character_position: usize,

    current_file_path: []const u8,

    data: []const u8,
    result: Package,

    stack: std.ArrayList(ParserFSMStateId),
    allocator: std.mem.Allocator,

    pub fn enter(self: *ParserFSM, state_id: ParserFSMStateId) !void {
        try self.stack.append(state_id);
    }

    pub fn currentChar(self: *const ParserFSM) ?u8 {
        if (self.pos >= self.data.input.len) return null;
        return self.data.input[self.pos];
    }

    pub fn advance(self: *ParserFSM) void {
        if (self.pos < self.data.input.len) self.pos += 1;
    }

    pub fn run(input_string: []const u8, allocator: std.mem.Allocator) !Package {
        var machine = ParserFSM{
            .pos = 0,
            .current_file_path = &[_]u8{},
            .data = input_string,
            .result = PackageInfo{
                .name = &[_]u8{},
                .author = &[_]u8{},
                .version = &[_]u8{},
                .license = &[_]u8{},
                .category = &[_]u8{},
                .description = &[_]u8{},
                .link = &[_]u8{},
                .install_date = &[_]u8{},
                .checksum = &[_]u8{},
                .files = std.StringHashMap([]const u8).init(allocator),
            },
            .stack = std.ArrayList(ParserFSMStateId).init(allocator),
            .allocator = allocator,
        };
        defer machine.stack.deinit();
        errdefer machine.result.files.deinit();

        try states.stateStart(&machine);
        return machine.result;
    }
};
