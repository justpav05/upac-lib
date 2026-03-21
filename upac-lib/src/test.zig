const std = @import("std");
const toml = @import("upac-toml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Тест 1 — index.toml
    std.debug.print("=== test index ===\n", .{});
    var index_doc = try toml.parse(allocator, "packages = [\"foo\", \"bar\"]\n");
    defer index_doc.deinit();

    const packages = index_doc.getArray("", "packages");
    if (packages) |package_list| {
        for (package_list) |package_name| {
            std.debug.print("package: {s}\n", .{package_name});
        }
    }

    // Тест 2 — package.toml
    std.debug.print("=== test meta ===\n", .{});
    var meta_doc = try toml.parse(allocator,
        \\[meta]
        \\name = "reflector"
        \\version = "2023-5"
        \\installed_at = 12345
    );
    defer meta_doc.deinit();

    const name = meta_doc.getString("meta", "name");
    const installed_at = meta_doc.getInteger("meta", "installed_at");
    std.debug.print("name: {s}\n", .{name orelse "NOT FOUND"});
    std.debug.print("installed_at: {}\n", .{installed_at orelse 0});
}
