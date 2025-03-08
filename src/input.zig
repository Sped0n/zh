const std = @import("std");
const assert = std.debug.assert;
const dprint = std.debug.print;

const termios = @import("termios.zig");
const Trie = @import("trie.zig");
const Writer = @import("writer.zig");

const ReadCharState = enum {
    Idle,
    EscSeq0,
    EscSeq1,
    Tab0,
    Exit,
};

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8),
cursor_pos: usize,
trie: *Trie,
state: ReadCharState = .Idle,
completions_cache: ?[]const []const u8 = null,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, trie: *Trie) Self {
    return Self{
        .buffer = std.ArrayList(u8).init(allocator),
        .cursor_pos = 0,
        .allocator = allocator,
        .trie = trie,
    };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

pub fn clear(self: *Self) void {
    self.buffer.clearRetainingCapacity();
    self.cursor_pos = 0;
}

fn free_completions_cache(self: *Self) void {
    assert(self.completions_cache != null);

    for (self.completions_cache.?) |c| self.allocator.free(c);
    self.allocator.free(self.completions_cache.?);
    self.completions_cache = null;
}

fn try_partial_completion(self: *Self, to_complete: []const u8) ?[]const u8 {
    assert(self.completions_cache != null);
    assert(self.completions_cache.?.len > 1);

    const completions = self.completions_cache.?;
    var last_valid_index = to_complete.len;
    for (to_complete.len..100) |i| Outer: {
        var target: ?u8 = null;
        for (completions) |c| {
            if (i > c.len - 1) {
                break :Outer;
            } else if (target == null) {
                target = c[i];
            } else if (target.? != c[i]) {
                break :Outer;
            }
        }
        last_valid_index += 1;
    }
    if (last_valid_index == to_complete.len) {
        return null;
    } else {
        return completions[0][to_complete.len..last_valid_index];
    }
}

fn idleHandler(self: *Self, char: u8, stdout: *Writer) !void {
    assert(self.state == .Idle);

    switch (char) {
        27 => {
            self.state = .EscSeq0;
        },
        127 => {
            try self.bkspHandler(stdout);
        },
        '\n' => {
            try self.enterHandler(stdout);
        },
        '\t' => {
            try self.tabHandler(stdout);
        },
        32...126 => {
            try self.defaultHandler(char, stdout);
        },
        else => {
            dprint("\nUnsupported Input: {c}\n", .{char});
        },
    }
}

fn escSeq0Handler(self: *Self, char: u8) void {
    assert(self.state == .EscSeq0);

    if (char == '[') {
        self.state = .EscSeq1;
    } else {
        self.state = .Idle;
    }
}

fn escSeq1Handler(self: *Self, char: u8, stdout: *Writer) !void {
    assert(self.state == .EscSeq1);

    switch (char) {
        'D' => {
            // Left arrow
            if (self.cursor_pos > 0) {
                self.cursor_pos -= 1;
                try stdout.print("\x1b[D", .{});
            }
        },
        'C' => {
            // Right arrow
            if (self.cursor_pos < self.buffer.items.len) {
                self.cursor_pos += 1;
                try stdout.print("\x1b[C", .{});
            }
        },
        else => {},
    }
    self.state = .Idle;
}

fn bkspHandler(self: *Self, stdout: *Writer) !void {
    assert(self.state == .Idle);

    if (!(self.cursor_pos > 0)) return;

    if (self.cursor_pos == self.buffer.items.len) {
        // Remove character from buffer
        _ = self.buffer.pop();
        self.cursor_pos -= 1;

        // ANSI backspace
        try stdout.print("\x1b[D\x1b[K", .{});
    } else {
        // Remove character from buffer
        _ = self.buffer.orderedRemove(self.cursor_pos - 1);
        const tail = self.buffer.items[self.cursor_pos - 1 ..];
        self.cursor_pos -= 1;

        try stdout.print("\x1b[D\x1b[K", .{});

        try stdout.print("{s}", .{tail});
        for (0..tail.len) |_| {
            try stdout.print("\x1b[D", .{});
        }
    }
}

fn enterHandler(self: *Self, stdout: *Writer) !void {
    assert(self.state == .Idle);

    try stdout.print("\n", .{});
    self.state = .Exit;
}

fn tabHandler(self: *Self, stdout: *Writer) !void {
    assert(self.state == .Idle);

    if (self.cursor_pos != self.buffer.items.len) return;

    var to_complete: ?[]const u8 = null;
    const buffer_last_index = self.buffer.items.len - 1;
    for (self.buffer.items, 0..) |item, i| {
        if (item == ' ' and i != 0) {
            to_complete = self.buffer.items[0..i];
            break;
        } else if (i == buffer_last_index) {
            to_complete = self.buffer.items[0 .. i + 1];
            break;
        }
    }
    if (to_complete == null) return;

    assert(self.completions_cache == null);

    self.completions_cache = try self.trie.findWithPrefix(to_complete.?);
    errdefer {
        self.free_completions_cache();
    }

    const completions = self.completions_cache.?;
    var completion: []const u8 = undefined;
    var is_partial_completion = false;
    if (completions.len == 0) {
        self.free_completions_cache();
        try stdout.print("{c}", .{7}); // bell
        return;
    } else if (completions.len == 1) {
        if (completions[0].len == to_complete.?.len) {
            self.free_completions_cache();
            try stdout.print("{c}", .{7}); // bell
            return;
        } else {
            completion = completions[0][to_complete.?.len..];
        }
    } else if (completions.len > 1) {
        if (self.try_partial_completion(to_complete.?)) |c| {
            is_partial_completion = true;
            completion = c;
        } else {
            try stdout.print("{c}", .{7}); // bell
            self.state = .Tab0;
            return;
        }
    }

    const to_complete_len = to_complete.?.len;
    if (self.cursor_pos == to_complete_len) {
        if (!is_partial_completion) {
            try stdout.print("{s} ", .{completion});
            try self.buffer.appendSlice(completion);
            try self.buffer.append(' ');
            self.cursor_pos += (completion.len + 1);
        } else {
            try stdout.print("{s}", .{completion});
            try self.buffer.appendSlice(completion);
            self.cursor_pos += completion.len;
        }
    } else {
        for (completion, to_complete_len..) |c, i| try self.buffer.insert(
            i,
            c,
        );
        for (0..self.cursor_pos - to_complete_len) |_| try stdout.print(
            "\x1b[D",
            .{},
        );
        const tail = self.buffer.items[to_complete_len..];
        try stdout.print("\x1b[K{s}", .{tail});
        self.cursor_pos += completion.len;
    }

    self.free_completions_cache();

    return;
}

fn tab0Handler(self: *Self, char: u8, stdout: *Writer) !void {
    assert(self.state == .Tab0);
    assert(self.completions_cache != null);

    self.state = .Idle;
    if (char != '\t') {
        try self.defaultHandler(char, stdout);
        return;
    }

    const completions = self.completions_cache.?;
    for (completions, 0..) |c, i| {
        if (i != 0) {
            try stdout.print("  {s}", .{c});
        } else {
            try stdout.print("\n{s}", .{c});
        }
    }
    try stdout.print("\n$ {s}", .{self.buffer.items});
    self.free_completions_cache();
}

fn defaultHandler(self: *Self, char: u8, stdout: *Writer) !void {
    assert(self.state == .Idle);

    try self.buffer.insert(self.cursor_pos, char);
    self.cursor_pos += 1;

    if (self.cursor_pos == self.buffer.items.len) {
        try stdout.print("{c}", .{char});
    } else {
        const tail = self.buffer.items[self.cursor_pos - 1 ..];
        try stdout.print("\x1b[K{s}", .{tail});
        for (0..tail.len - 1) |_| {
            try stdout.print("\x1b[D", .{});
        }
    }
}

pub fn readChar(self: *Self, stdout: *Writer) !bool {
    const stdin = std.io.getStdIn().reader();
    var buf: [1]u8 = undefined;
    const bytes_read = try stdin.read(&buf);

    if (bytes_read == 0) return true; // EOF

    const char = buf[0];

    switch (self.state) {
        .Idle => {
            try self.idleHandler(char, stdout);
        },
        .EscSeq0 => {
            self.escSeq0Handler(char);
        },
        .EscSeq1 => {
            try self.escSeq1Handler(char, stdout);
        },
        .Tab0 => {
            try self.tab0Handler(char, stdout);
        },
        else => {
            assert(false);
        },
    }
    if (self.state == .Exit) {
        self.state = .Idle;
        return true;
    }

    return false;
}

pub fn readLine(self: *Self, stdout: *Writer) ![]const u8 {
    self.clear();
    try termios.setTerminalEcho(false);
    defer termios.setTerminalEcho(true) catch {};

    while (true) {
        const read_complete = try self.readChar(stdout);
        if (read_complete) {
            break;
        }
    }

    return self.buffer.toOwnedSlice();
}
