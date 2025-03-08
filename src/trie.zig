const std = @import("std");

const handler = @import("handlers.zig");
const Exlut = @import("exlut.zig");

const Node = struct {
    children: std.AutoHashMap(u8, *Node),
    is_end: bool,

    fn init(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .children = std.AutoHashMap(u8, *Node).init(allocator),
            .is_end = false,
        };
        return node;
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.destroy(entry.value_ptr.*);
        }
        self.children.deinit();
    }
};

root: *Node,
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !Self {
    return Self{
        .root = try Node.init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.root.deinit(self.allocator);
    self.allocator.destroy(self.root);
}

pub fn insert(self: *Self, word: []const u8) !void {
    var current = self.root;

    for (word) |c| {
        if (!current.children.contains(c)) {
            const new_node = try Node.init(self.allocator);
            try current.children.put(c, new_node);
        }
        current = current.children.get(c).?;
    }
    current.is_end = true;
}

pub fn findWithPrefix(self: *Self, prefix: []const u8) ![]const []const u8 {
    var results = std.ArrayList([]const u8).init(self.allocator);
    errdefer {
        for (results.items) |result| {
            self.allocator.free(result);
        }
        results.deinit();
    }
    var current = self.root;

    for (prefix) |c| {
        if (!current.children.contains(c)) {
            return try results.toOwnedSlice();
        }
        current = current.children.get(c).?;
    }

    var word_buffer = std.ArrayList(u8).init(self.allocator);
    defer word_buffer.deinit();

    try word_buffer.appendSlice(prefix);

    try self.dfs(current, &word_buffer, &results);

    return try results.toOwnedSlice();
}

fn dfs(
    self: *Self,
    node: *Node,
    word_buffer: *std.ArrayList(u8),
    results: *std.ArrayList([]const u8),
) !void {
    if (node.is_end) {
        const word = try self.allocator.dupe(u8, word_buffer.items);
        errdefer self.allocator.free(word);
        try results.append(word);
    }

    var keys = std.ArrayList(u8).init(self.allocator);
    defer keys.deinit();
    var it = node.children.keyIterator();
    while (it.next()) |key| {
        try keys.append(key.*);
    }

    std.mem.sort(u8, keys.items, {}, std.sort.asc(u8));

    for (keys.items) |c| {
        const child_node = node.children.get(c).?;
        try word_buffer.append(c);
        try self.dfs(child_node, word_buffer, results);
        _ = word_buffer.pop();
    }
}

pub fn populate(self: *Self, exlut: *Exlut) !void {
    inline for (@typeInfo(handler.Builtins).@"enum".fields) |field| {
        try self.insert(field.name);
    }
    var exec_it = exlut.map.keyIterator();
    while (exec_it.next()) |exec_name| {
        try self.insert(exec_name.*);
    }
}
