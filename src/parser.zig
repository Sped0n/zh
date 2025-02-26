const std = @import("std");
const assert = std.debug.assert;

const Writer = @import("writer.zig");

const ParserState = enum {
    Idle,
    Default,
    BS, // Backslash
    SQ, // Single Quote
    DQ, // Double Quote
    DQBS, // Double Quote Backslash
};

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8),
args: std.ArrayList([]const u8),
state: ParserState = .Default,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .buffer = std.ArrayList(u8).init(allocator),
        .args = std.ArrayList([]const u8).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.free_buffer();
    self.buffer.deinit();
    self.args.deinit();
}

fn free_buffer(self: *Self) void {
    for (self.args.items) |arg| {
        self.allocator.free(arg);
    }
    self.buffer.clearAndFree();
}

fn idleHandler(self: *Self, char: u8) !void {
    assert(self.state == .Idle);

    switch (char) {
        ' ' => {},
        '\'' => {
            self.state = .SQ;
        },
        '"' => {
            self.state = .DQ;
        },
        '\\' => {
            self.state = .BS;
        },
        else => {
            try self.buffer.append(char);
            self.state = .Default;
        },
    }
}

fn defaultHandler(self: *Self, char: u8) !void {
    assert(self.state == .Default);

    switch (char) {
        ' ' => {
            if (self.buffer.items.len > 0) {
                try self.args.append(try self.buffer.toOwnedSlice());
            }
            self.state = .Idle;
        },
        '\\' => {
            self.state = .BS;
        },
        '\'' => {
            self.state = .SQ;
        },
        '"' => {
            self.state = .DQ;
        },
        else => {
            try self.buffer.append(char);
        },
    }
}

fn bsHandler(self: *Self, char: u8) !void {
    assert(self.state == .BS);

    try self.buffer.append(char);
    self.state = .Default;
}

fn sqHandler(self: *Self, char: u8) !void {
    assert(self.state == .SQ);

    if (char == '\'') {
        self.state = .Default;
    } else {
        try self.buffer.append(char);
    }
}

fn dqHandler(self: *Self, char: u8) !void {
    assert(self.state == .DQ);

    switch (char) {
        '"' => {
            self.state = .Default;
        },
        '\\' => {
            self.state = .DQBS;
        },
        else => {
            try self.buffer.append(char);
        },
    }
}

fn dqbsHandler(self: *Self, char: u8) !void {
    assert(self.state == .DQBS);

    switch (char) {
        '"', '\\', ' ' => {
            try self.buffer.append(char);
        },
        else => {
            try self.buffer.appendSlice(&[_]u8{ '\\', char });
        },
    }

    self.state = .DQ;
}

pub fn parse(self: *Self, input: []const u8) ![]const []const u8 {
    defer self.buffer.clearAndFree();
    errdefer self.free_buffer();

    for (input) |char| {
        switch (self.state) {
            .Idle => {
                try self.idleHandler(char);
            },
            .Default => {
                try self.defaultHandler(char);
            },
            .BS => {
                try self.bsHandler(char);
            },
            .SQ => {
                try self.sqHandler(char);
            },
            .DQ => {
                try self.dqHandler(char);
            },
            .DQBS => {
                try self.dqbsHandler(char);
            },
        }
    }

    switch (self.state) {
        .Idle => {
            return try self.args.toOwnedSlice();
        },
        .Default => {
            if (self.buffer.items.len > 0) {
                try self.args.append(try self.buffer.toOwnedSlice());
            }
            return try self.args.toOwnedSlice();
        },
        else => {
            self.free_buffer();
            return error.ParseError;
        },
    }
}

pub fn redirectParse(
    raw_argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) ![]const []const u8 {
    if (!(raw_argv.len >= 3)) return error.ParseError;

    if (std.mem.eql(
        u8,
        raw_argv[raw_argv.len - 2],
        ">",
    ) or std.mem.eql(
        u8,
        raw_argv[raw_argv.len - 2],
        "1>",
    )) {
        if (stdout.toFile(raw_argv[raw_argv.len - 1], false)) {
            return raw_argv[0 .. raw_argv.len - 2];
        } else {
            try stderr.print("zh: redirect failed\n", .{});
            return error.RedirectError;
        }
    } else if (std.mem.eql(u8, raw_argv[raw_argv.len - 2], "2>")) {
        if (stderr.toFile(raw_argv[raw_argv.len - 1], false)) {
            return raw_argv[0 .. raw_argv.len - 2];
        } else {
            try stderr.print("zh: redirect failed\n", .{});
            return error.RedirectError;
        }
    } else if (std.mem.eql(
        u8,
        raw_argv[raw_argv.len - 2],
        ">>",
    ) or std.mem.eql(
        u8,
        raw_argv[raw_argv.len - 2],
        "1>>",
    )) {
        if (stdout.toFile(raw_argv[raw_argv.len - 1], true)) {
            return raw_argv[0 .. raw_argv.len - 2];
        } else {
            try stderr.print("zh: redirect failed\n", .{});
            return error.RedirectError;
        }
    } else if (std.mem.eql(u8, raw_argv[raw_argv.len - 2], "2>>")) {
        if (stderr.toFile(raw_argv[raw_argv.len - 1], true)) {
            return raw_argv[0 .. raw_argv.len - 2];
        } else {
            try stderr.print("zh: redirect failed\n", .{});
            return error.RedirectError;
        }
    }

    return error.ParseError;
}
