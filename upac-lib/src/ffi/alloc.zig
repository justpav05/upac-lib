const std = @import("std");

/// Глобальный аллокатор для .so — инициализируется один раз.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

/// Освобождает память выделенную библиотекой.
pub export fn upac_free(ptr: *anyopaque) callconv(.C) void {
    _ = ptr;
    // TODO: для корректного free нужен размер — используем upac_free_slice
}

pub export fn upac_free_slice(ptr: *anyopaque, len: usize) callconv(.C) void {
    const slice = @as([*]u8, @ptrCast(ptr))[0..len];
    gpa.allocator().free(slice);
}
