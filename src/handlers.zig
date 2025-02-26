const std = @import("std");

const Exlut = @import("exlut.zig");
const Writer = @import("writer.zig");

pub const Builtins = enum { exit, echo, type, pwd, cd };
pub const ShellAction = enum { Panic, Exit, NoAction };

pub fn exitHandler(
    argv: []const []const u8,
    stderr: *Writer,
) std.fs.File.WriteError!ShellAction {
    if (argv.len != 2) {
        try stderr.print("exit: arguments number mismatch, {d} vs 2\n", .{argv.len});
        return .NoAction;
    }
    const arg = std.fmt.parseInt(u8, argv[1], 10) catch {
        try stderr.print("exit: invalid argument: {s}\n", .{argv[1]});
        return .NoAction;
    };
    if (arg == 0) {
        return .Exit;
    } else {
        return .Panic;
    }
}

pub fn echoHandler(
    argv: []const []const u8,
    stdout: *Writer,
) !ShellAction {
    for (argv[1..argv.len], 0..) |word, index| {
        if (index != 0)
            try stdout.print(" ", .{});
        try stdout.print("{s}", .{word});
    }
    try stdout.print("\n", .{});
    return .NoAction;
}

pub fn typeHandler(
    argv: []const []const u8,
    exlut: *Exlut,
    stdout: *Writer,
    stderr: *Writer,
) !ShellAction {
    if (argv.len != 2) {
        try stderr.print("type: arguments number mismatch, {d} vs 2\n", .{argv.len});
        return .NoAction;
    }
    const target = argv[1];
    _ = std.meta.stringToEnum(Builtins, target) orelse {
        const target_path = exlut.getExecutablePath(target) orelse {
            try stderr.print("{s}: not found\n", .{target});
            return .NoAction;
        };
        try stdout.print("{s} is {s}\n", .{ target, target_path });
        return .NoAction;
    };
    try stdout.print("{s} is a shell builtin\n", .{target});
    return .NoAction;
}

pub fn pwdHandler(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) !ShellAction {
    if (argv.len != 1) {
        try stderr.print("pwd: too many arguments\n", .{});
        return .NoAction;
    }
    const pwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(pwd);
    try stdout.print("{s}\n", .{pwd});
    return .NoAction;
}

pub fn cdHandler(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stderr: *Writer,
) !ShellAction {
    if (argv.len != 2) {
        try stderr.print("cd: arguments number mismatch, {d} vs 2\n", .{argv.len});
        return .NoAction;
    }

    var dir: ?std.fs.Dir = null;
    defer {
        if (dir) |*d| {
            d.*.close();
        }
    }

    const target = argv[1];
    if (target[0] != '~') {
        dir = std.fs.cwd().openDir(target, .{}) catch {
            try stderr.print("cd: {s}: No such file or directory\n", .{target});
            return .NoAction;
        };
    } else {
        var env_map = std.process.getEnvMap(allocator) catch {
            return .NoAction;
        };
        defer env_map.deinit();

        const home = env_map.get("HOME") orelse {
            try stderr.print("cd: HOME variable not available\n", .{});
            return .NoAction;
        };

        if (target.len > 1) {
            const path = std.fs.path.join(allocator, &[_][]const u8{ home, target[1..] }) catch {
                try stderr.print("cd: {s}: No such file or directory\n", .{target});
                return .NoAction;
            };
            defer allocator.free(path);
            dir = std.fs.cwd().openDir(path, .{}) catch {
                try stderr.print("cd: {s}: No such file or directory\n", .{target});
                return .NoAction;
            };
        } else {
            dir = std.fs.cwd().openDir(home, .{}) catch {
                try stderr.print("cd: {s}: No such file or directory\n", .{target});
                return .NoAction;
            };
        }
    }

    if (dir) |*d| {
        d.*.setAsCwd() catch |err| {
            try stderr.print("cd: {any}\n", .{err});
        };
    }

    return .NoAction;
}

pub fn execHandler(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) !std.process.Child.Term {
    const stdout_is_default = stdout.isDefault();
    const stderr_is_default = stderr.isDefault();

    var child = std.process.Child.init(argv, allocator);

    if (stdout_is_default and stderr_is_default) {
        return try child.spawnAndWait();
    }

    if (!stdout_is_default) child.stdout_behavior = .Pipe;
    if (!stderr_is_default) child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    var stdout_bytes: []u8 = undefined;
    if (!stdout_is_default) stdout_bytes = try child.stdout.?.reader().readAllAlloc(allocator, 50 * 1024);
    defer {
        if (!stdout_is_default) allocator.free(stdout_bytes);
    }

    var stderr_bytes: []u8 = undefined;
    if (!stderr_is_default) stderr_bytes = try child.stderr.?.reader().readAllAlloc(allocator, 50 * 1024);
    defer {
        if (!stderr_is_default) allocator.free(stderr_bytes);
    }

    const term = try child.wait();

    if (!stdout_is_default) try stdout.print("{s}", .{stdout_bytes});
    if (!stderr_is_default) try stderr.print("{s}", .{stderr_bytes});

    return term;
}
