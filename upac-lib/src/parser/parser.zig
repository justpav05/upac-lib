const std = @import("std");

// ── Типы ─────────────────────────────────────────────────────────────────────
pub const TomlValue = union(enum) {
    string: []const u8,
    integer: i64,
    string_array: [][]const u8,
};

pub const TomlTable = struct {
    name: []const u8,
    entries: std.StringHashMap(TomlValue),
};

pub const TomlDocument = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(TomlTable),

    pub fn deinit(self: *TomlDocument) void {
        for (self.tables.items) |*table| {
            var table_iter = table.entries.iterator();
            while (table_iter.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .string => |string| self.allocator.free(string),
                    .string_array => |string_arr| {
                        for (string_arr) |string| self.allocator.free(string);
                        self.allocator.free(string_arr);
                    },
                    .integer => {},
                }
            }
            table.entries.deinit();
        }
        self.tables.deinit();
    }

    pub fn getTable(self: *TomlDocument, name: []const u8) ?*TomlTable {
        for (self.tables.items) |*table| {
            if (std.mem.eql(u8, table.name, name)) return table;
        }
        return null;
    }

    pub fn getString(self: *TomlDocument, table_name: []const u8, key: []const u8) ?[]const u8 {
        const table = self.getTable(table_name) orelse return null;
        const value = table.entries.get(key) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    pub fn getInteger(self: *TomlDocument, table_name: []const u8, key: []const u8) ?i64 {
        const table = self.getTable(table_name) orelse return null;
        const value = table.entries.get(key) orelse return null;
        return switch (value) {
            .integer => |integer| integer,
            else => null,
        };
    }

    pub fn getArray(self: *TomlDocument, table_name: []const u8, key: []const u8) ?[][]const u8 {
        const table = self.getTable(table_name) orelse return null;
        const value = table.entries.get(key) orelse return null;
        return switch (value) {
            .string_array => |string_arr| string_arr,
            else => null,
        };
    }
};

// ── Парсер ────────────────────────────────────────────────────────────────────
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !TomlDocument {
    var document = TomlDocument{
        .allocator = allocator,
        .tables = std.ArrayList(TomlTable).init(allocator),
    };
    errdefer document.deinit();

    // Корневая секция
    try document.tables.append(TomlTable{
        .name = "",
        .entries = std.StringHashMap(TomlValue).init(allocator),
    });

    var current_table = &document.tables.items[0];
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0 or line[0] == '#') continue;

        // Секция [name]
        if (line[0] == '[') {
            const closing = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidSectionHeader;
            const section_name = std.mem.trim(u8, line[1..closing], " \t");

            try document.tables.append(TomlTable{
                .name = section_name,
                .entries = std.StringHashMap(TomlValue).init(allocator),
            });
            current_table = &document.tables.items[document.tables.items.len - 1];
            continue;
        }

        // key = value
        const equals_pos = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidKeyValue;
        const key = std.mem.trim(u8, line[0..equals_pos], " \t");
        const raw_value = std.mem.trim(u8, line[equals_pos + 1 ..], " \t");

        const value = try parseValue(allocator, raw_value);
        try current_table.entries.put(key, value);
    }

    return document;
}

fn parseValue(allocator: std.mem.Allocator, raw: []const u8) !TomlValue {
    // Массив ["a", "b"]
    if (raw.len > 0 and raw[0] == '[') {
        return .{ .string_array = try parseStringArray(allocator, raw) };
    }

    // Строка "value"
    if (raw.len >= 2 and raw[0] == '"') {
        const closing = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return error.UnterminatedString;
        if (closing == 0) return error.UnterminatedString;
        return .{ .string = try allocator.dupe(u8, raw[1..closing]) };
    }

    // Целое число
    const integer = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidValue;
    return .{ .integer = integer };
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |s| allocator.free(s);
        result.deinit();
    }

    // Убираем [ и ]
    const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t");
    if (inner.len == 0) return result.toOwnedSlice();

    var position: usize = 0;
    while (position < inner.len) {
        // Ищем открывающую кавычку
        const open_quote = std.mem.indexOfScalarPos(u8, inner, position, '"') orelse break;
        const close_quote = std.mem.indexOfScalarPos(u8, inner, open_quote + 1, '"') orelse return error.UnterminatedString;

        try result.append(try allocator.dupe(u8, inner[open_quote + 1 .. close_quote]));
        position = close_quote + 1;
    }

    return result.toOwnedSlice();
}
