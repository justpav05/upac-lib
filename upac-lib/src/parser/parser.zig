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
    var current_position: usize = 0;

    while (current_position < content.len) {
        // Пропускаем пробелы и переносы строк
        while (current_position < content.len and
            (content[current_position] == ' ' or
            content[current_position] == '\t' or
            content[current_position] == '\n' or
            content[current_position] == '\r')) : (current_position += 1)
        {}

        if (current_position >= content.len) break;

        // Комментарий
        if (content[current_position] == '#') {
            while (current_position < content.len and content[current_position] != '\n') : (current_position += 1) {}
            continue;
        }

        // Секция [name]
        if (content[current_position] == '[') {
            current_position += 1;
            const closing_bracket_position = std.mem.indexOfScalarPos(u8, content, current_position, ']') orelse return error.InvalidSectionHeader;
            const section_name = std.mem.trim(u8, content[current_position..closing_bracket_position], " \t");
            current_position = closing_bracket_position + 1;

            try document.tables.append(TomlTable{
                .name = section_name,
                .entries = std.StringHashMap(TomlValue).init(allocator),
            });
            current_table = &document.tables.items[document.tables.items.len - 1];
            continue;
        }

        // Ищем конец строки для key = value
        const line_end = std.mem.indexOfScalarPos(u8, content, current_position, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[current_position..line_end], " \t\r");

        if (line.len == 0) {
            current_position = line_end + 1;
            continue;
        }

        const equals_position = std.mem.indexOfScalar(u8, line, '=') orelse {
            current_position = line_end + 1;
            continue;
        };

        const key = std.mem.trim(u8, line[0..equals_position], " \t");
        const raw_value = std.mem.trim(u8, line[equals_position + 1 ..], " \t");

        // Многострочный массив — ищем ] в полном тексте
        if (raw_value.len > 0 and raw_value[0] == '[') {
            const array_start = @intFromPtr(raw_value.ptr) - @intFromPtr(content.ptr);
            const parse_result = try parseStringArray(allocator, content, array_start);

            try current_table.entries.put(key, .{ .string_array = parse_result.value });
            current_position = parse_result.end_position;
            continue;
        }

        const parsed_value = try parseValue(allocator, raw_value);
        try current_table.entries.put(key, parsed_value);
        current_position = line_end + 1;
    }

    return document;
}

fn parseValue(allocator: std.mem.Allocator, raw_value: []const u8) !TomlValue {
    // Строка "value"
    if (raw_value.len >= 2 and raw_value[0] == '"') {
        const closing_quote_position = std.mem.lastIndexOfScalar(u8, raw_value, '"') orelse return error.UnterminatedString;
        if (closing_quote_position == 0) return error.UnterminatedString;
        return .{ .string = try allocator.dupe(u8, raw_value[1..closing_quote_position]) };
    }

    // Целое число
    const integer_value = std.fmt.parseInt(i64, raw_value, 10) catch return error.InvalidValue;
    return .{ .integer = integer_value };
}

fn parseStringArray(allocator: std.mem.Allocator, content: []const u8, start_position: usize) !struct { value: [][]const u8, end_position: usize } {
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |string_value| allocator.free(string_value);
        result.deinit();
    }

    var current_position = start_position + 1;
    while (current_position < content.len) {
        const current_char = content[current_position];

        if (current_char == ']') {
            return .{ .value = try result.toOwnedSlice(), .end_position = current_position + 1 };
        }

        if (current_char == '"') {
            const close_quote_position = std.mem.indexOfScalarPos(u8, content, current_position + 1, '"') orelse return error.UnterminatedString;
            try result.append(try allocator.dupe(u8, content[current_position + 1 .. close_quote_position]));
            current_position = close_quote_position + 1;
            continue;
        }

        current_position += 1;
    }

    return error.UnterminatedArray;
}
