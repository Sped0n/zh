const std = @import("std");

const handlers = @import("handlers.zig");
const Builtins = handlers.Builtins;
const Exlut = @import("exlut.zig");
const Parser = @import("parser.zig");
const Writer = @import("writer.zig");
const Input = @import("input.zig");
const Trie = @import("trie.zig");

test {
    comptime {
        _ = @import("./test/tests.zig");
    }
}

pub fn main() !u8 {
    // Initialize GPA
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Input parser
    var parser = Parser.init(allocator);
    defer parser.deinit();

    // Exec Lookup Table
    var exlut = Exlut.init(allocator);
    defer exlut.deinit();
    try exlut.populate();

    // Trie (completion)
    var trie = try Trie.init(allocator);
    defer trie.deinit();
    try trie.populate(&exlut);

    // Stdin
    var input = Input.init(allocator, &trie); // Initialize the input reader
    defer input.deinit();

    // Stdout
    var stdout = Writer.init(&std.io.getStdOut);
    var stderr = Writer.init(&std.io.getStdOut);

    while (true) {
        // Writer reset
        _ = stdout.toDefault();
        _ = stderr.toDefault();

        // Prompt
        try stdout.writer.print("$ ", .{});

        // Read user input using the Input struct
        const user_input = try input.readLine(&stdout); // Use the readLine function
        defer allocator.free(user_input);

        const raw_argv = parser.parse(user_input) catch {
            try stderr.writer.print("zh: parse error\n", .{});
            continue;
        };
        defer {
            for (raw_argv) |arg| {
                allocator.free(arg);
            }
            allocator.free(raw_argv);
        }

        if (raw_argv.len == 0) continue;

        const argv = Parser.redirectParse(
            raw_argv,
            &stdout,
            &stderr,
        ) catch raw_argv;

        const command = std.meta.stringToEnum(Builtins, argv[0]) orelse {
            if (exlut.hasExecutable(argv[0])) {
                _ = handlers.execHandler(allocator, argv, &stdout, &stderr) catch {};
            } else {
                try stderr.writer.print("{s}: command not found\n", .{argv[0]});
            }
            continue;
        };

        switch (command) {
            .exit => {
                switch (try handlers.exitHandler(argv, &stderr)) {
                    .NoAction => {},
                    .Exit => {
                        return 0;
                    },
                    .Panic => {
                        return 1;
                    },
                }
            },
            .echo => {
                _ = try handlers.echoHandler(argv, &stdout);
            },
            .type => {
                _ = try handlers.typeHandler(argv, &exlut, &stdout, &stderr);
            },
            .pwd => {
                _ = try handlers.pwdHandler(allocator, argv, &stdout, &stderr);
            },
            .cd => {
                _ = try handlers.cdHandler(allocator, argv, &stderr);
            },
        }
    }

    return 0;
}
