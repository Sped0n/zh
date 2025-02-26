const std = @import("std");
const fs = std.fs;

file: ?fs.File = null,
default_file_getter: *const fn () fs.File,
writer: fs.File.Writer,

const Self = @This();

pub fn init(default_file_getter: *const fn () fs.File) Self {
    const f = default_file_getter();
    return Self{
        .file = null,
        .default_file_getter = default_file_getter,
        .writer = f.writer(),
    };
}

pub fn deinit(self: *Self) void {
    if (self.file) |f| {
        f.close();
    }
}

pub fn toDefault(self: *Self) bool {
    if (self.file) |f| {
        f.close();
        self.file = null;
        const df = self.default_file_getter();
        self.writer = df.writer();
        return true;
    } else {
        return false;
    }
}

pub fn toFile(self: *Self, path: []const u8, try_append: bool) bool {
    if (self.file) |f| {
        f.close();
        self.file = null;
    }

    var try_create = false;
    const path_is_absolute = fs.path.isAbsolute(path);

    const file_open_flags: fs.File.OpenFlags = .{ .mode = .read_write };
    if (if (path_is_absolute) fs.openFileAbsolute(
        path,
        file_open_flags,
    ) else fs.cwd().openFile(
        path,
        file_open_flags,
    )) |f| {
        if (try_append) f.seekFromEnd(0) catch {
            f.close();
            return false;
        };
        self.file = f;
    } else |err| {
        if (err == fs.File.OpenError.FileNotFound) {
            try_create = true;
        } else {
            return false;
        }
    }

    if (!try_create) {
        self.writer = self.file.?.writer();
        return true;
    }

    const file_create_flags: fs.File.CreateFlags = .{ .read = true };
    if (if (path_is_absolute) fs.createFileAbsolute(
        path,
        file_create_flags,
    ) else fs.cwd().createFile(
        path,
        file_create_flags,
    )) |f| {
        self.file = f;
    } else |_| {
        return false;
    }

    self.writer = self.file.?.writer();
    return true;
}

pub fn isDefault(self: *Self) bool {
    return self.file == null;
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    try self.writer.print(fmt, args);
}
