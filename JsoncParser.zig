//! Reads JSONC, JSON with `//` and `/* */` comments and trailing commas (VS Code settings,
//! waybar), into the tree kosm matches paths against. Hand-written: no tree-sitter
//! grammar accepts trailing commas. Keys keep their escapes as written, like the `json` adapter.

const JsoncParser = @This();

const std = @import("std");
const kosm = @import("kosm");
const Node = kosm.Adapter.Node;

allocator: std.mem.Allocator,
source: []const u8,
context: *kosm.Adapter.Context,
index: usize = 0,

/// Deeper nesting is refused rather than risking the stack.
const max_depth = 256;

const Error = kosm.Adapter.ParseError;

/// An adapter `parser`: the file's one top-level value. Nodes point into `source`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context) Error!Node {
    var parser: JsoncParser = .{ .allocator = allocator, .source = source, .context = context };
    try parser.skipTrivia();
    if (parser.index == source.len) return .{ .key = null, .kind = .table, .position = 0, .value = .{ .start = 0, .end = 0 } };
    const root = try parser.value(0);
    try parser.skipTrivia();
    if (parser.index != source.len) return parser.fail("text after the file's value", .{});
    return root;
}

fn value(parser: *JsoncParser, depth: usize) Error!Node {
    if (depth == max_depth) return parser.fail("values nest deeper than {d} levels", .{max_depth});
    const start = parser.index;
    const first = parser.peek() orelse return parser.fail("a value is missing", .{});
    var node: Node = .{ .key = null, .kind = .scalar, .position = start, .value = null };
    switch (first) {
        '{' => {
            node.kind = .table;
            node.children = try parser.object(depth);
        },
        '[' => {
            node.kind = .list;
            node.children = try parser.array(depth);
        },
        '"' => _ = try parser.string(),
        '-', '0'...'9' => try parser.number(),
        else => {
            const literal = for ([_][]const u8{ "true", "false", "null" }) |word| {
                if (std.mem.startsWith(u8, parser.source[start..], word)) break word;
            } else return parser.fail("'{c}' does not start a value", .{first});
            parser.index += literal.len;
        },
    }
    node.value = .{ .start = start, .end = parser.index };
    return node;
}

fn object(parser: *JsoncParser, depth: usize) Error![]const Node {
    parser.index += 1;
    var entries: std.ArrayList(Node) = .empty;
    while (true) {
        try parser.skipTrivia();
        if (parser.peek() == '}') break;
        const position = parser.index;
        if (parser.peek() != '"') return parser.fail("an object key must be a string", .{});
        const key = try parser.string();
        try parser.skipTrivia();
        if (parser.peek() != ':') return parser.fail("':' must follow the key", .{});
        parser.index += 1;
        try parser.skipTrivia();
        var entry = try parser.value(depth + 1);
        entry.key = key;
        entry.position = position;
        try entries.append(parser.allocator, entry);
        if (!try parser.separator('}')) break;
    }
    parser.index += 1;
    return entries.items;
}

fn array(parser: *JsoncParser, depth: usize) Error![]const Node {
    parser.index += 1;
    var elements: std.ArrayList(Node) = .empty;
    while (true) {
        try parser.skipTrivia();
        if (parser.peek() == ']') break;
        try elements.append(parser.allocator, try parser.value(depth + 1));
        if (!try parser.separator(']')) break;
    }
    parser.index += 1;
    return elements.items;
}

/// After an entry: a comma (true, another entry may follow) or the closing byte (false).
fn separator(parser: *JsoncParser, close: u8) Error!bool {
    try parser.skipTrivia();
    const next = parser.peek() orelse return parser.fail("'{c}' is missing", .{close});
    if (next == ',') {
        parser.index += 1;
        return true;
    }
    if (next != close) return parser.fail("',' or '{c}' must follow a value", .{close});
    return false;
}

/// Reads a string and returns its text between the quotes, escapes as written.
fn string(parser: *JsoncParser) Error![]const u8 {
    const start = parser.index + 1;
    parser.index = start;
    while (parser.peek()) |character| {
        switch (character) {
            '"' => {
                parser.index += 1;
                return parser.source[start .. parser.index - 1];
            },
            '\\' => parser.index += 2,
            '\n' => return parser.fail("a string runs past the end of its line", .{}),
            else => parser.index += 1,
        }
    }
    parser.index = start - 1;
    return parser.fail("a string has no closing quote", .{});
}

fn number(parser: *JsoncParser) Error!void {
    if (parser.peek() == '-') parser.index += 1;
    if (!parser.digits()) return parser.fail("a number needs digits", .{});
    if (parser.peek() == '.') {
        parser.index += 1;
        if (!parser.digits()) return parser.fail("a number needs digits after its '.'", .{});
    }
    if (parser.peek() == 'e' or parser.peek() == 'E') {
        parser.index += 1;
        if (parser.peek() == '+' or parser.peek() == '-') parser.index += 1;
        if (!parser.digits()) return parser.fail("a number needs digits in its exponent", .{});
    }
}

fn digits(parser: *JsoncParser) bool {
    const start = parser.index;
    while (parser.peek()) |character| {
        if (!std.ascii.isDigit(character)) break;
        parser.index += 1;
    }
    return parser.index != start;
}

/// Skips whitespace and comments.
fn skipTrivia(parser: *JsoncParser) Error!void {
    while (parser.peek()) |character| {
        if (std.ascii.isWhitespace(character)) {
            parser.index += 1;
        } else if (std.mem.startsWith(u8, parser.source[parser.index..], "//")) {
            parser.index = std.mem.indexOfScalarPos(u8, parser.source, parser.index, '\n') orelse parser.source.len;
        } else if (std.mem.startsWith(u8, parser.source[parser.index..], "/*")) {
            const close = std.mem.indexOfPos(u8, parser.source, parser.index + 2, "*/") orelse
                return parser.fail("a /* comment has no closing */", .{});
            parser.index = close + 2;
        } else return;
    }
}

fn peek(parser: *const JsoncParser) ?u8 {
    if (parser.index >= parser.source.len) return null;
    return parser.source[parser.index];
}

fn fail(parser: *JsoncParser, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
    const before = parser.source[0..@min(parser.index, parser.source.len)];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |newline| newline + 1 else 0;
    const line = std.mem.countScalar(u8, before, '\n') + 1;
    var message_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, format, arguments) catch message_buffer[0..];
    return parser.context.invalidSyntax("line {d}, column {d}: {s}", .{ line, before.len - line_start + 1, message });
}

const testing = std.testing;

fn parseText(arena: *std.heap.ArenaAllocator, text: []const u8, context: *kosm.Adapter.Context) Error!Node {
    return parse(arena.allocator(), text, context);
}

test "comments, trailing commas and comment-like text inside strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    const text =
        \\// top
        \\{
        \\  "url": "https://example.com/*not a comment*/", // trailing
        \\  /* a { brace */ "list": [1, -2.5e3, true, null, ],
        \\  "nested": { "a\"b": {}, },
        \\}
    ;
    const root = try parseText(&arena, text, &context);
    try testing.expectEqual(.table, root.kind);
    try testing.expectEqual(3, root.children.len);
    const url = root.children[0];
    try testing.expectEqualStrings("url", url.key.?);
    try testing.expectEqualStrings("\"https://example.com/*not a comment*/\"", text[url.value.?.start..url.value.?.end]);
    try testing.expectEqual(4, root.children[1].children.len);
    try testing.expectEqualStrings("a\\\"b", root.children[2].children[0].key.?);
}

test "a top-level array is the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    const root = try parseText(&arena, "[ { \"layer\": \"top\" }, { \"layer\": \"bottom\" }, ]\n", &context);
    try testing.expectEqual(.list, root.kind);
    try testing.expectEqual(2, root.children.len);
    try testing.expectEqualStrings("layer", root.children[1].children[0].key.?);
}

fn expectFailure(text: []const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    try testing.expectError(error.InvalidSyntax, parseText(&arena, text, &context));
    try testing.expectEqualStrings(message, context.message());
}

test "malformed JSONC names its line and column" {
    try expectFailure("{ \"a\": 1 \"b\": 2 }", "line 1, column 10: ',' or '}' must follow a value");
    try expectFailure("{\n  \"a\": 1,\n  b: 2\n}", "line 3, column 3: an object key must be a string");
    try expectFailure("{ \"a\": \"text }", "line 1, column 8: a string has no closing quote");
    try expectFailure("{ \"a\": [1, 2 }", "line 1, column 14: ',' or ']' must follow a value");
    try expectFailure("{ /* open", "line 1, column 3: a /* comment has no closing */");
    try expectFailure("{} {}", "line 1, column 4: text after the file's value");
    try expectFailure("{ \"a\": tru }", "line 1, column 8: 't' does not start a value");
    try expectFailure("{ \"a\": 1. }", "line 1, column 10: a number needs digits after its '.'");
    try expectFailure("{ \"a\": ", "line 1, column 8: a value is missing");
}
