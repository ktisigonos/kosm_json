//! JSON: set values by path in JSON files you write by hand (the `json` adapter).

const std = @import("std");
const kosm = @import("kosm");

extern fn tree_sitter_json() callconv(.c) *const kosm.treesitter.Language;

/// Edits strict `.json` files through `output.edit`; comments are allowed, trailing
/// commas are not. A key holding a dot is a quoted path segment: `"editor.fontSize"`.
/// `generate` writes whole files, objects and arrays indented by two spaces.
pub const adapter: kosm.Adapter = .{
    .name = "json",
    .extensions = &.{".json"},
    .default_format = .{ .boolean = .true_false },
    .format = format,
    .serialize = serialize,
    .insert = insert,
    .parser = kosm.treesitter.parser(tree_sitter_json, .{
        .pair = "pair",
        .key = "key",
        .value = "value",
        .nest = &.{"object"},
        .list = &.{"array"},
        .quoted_key = &.{"string"},
    }),
};

/// Edits JSONC: `.jsonc` files, and with `.lang = "jsonc"` any JSON file with comments or
/// trailing commas, such as VS Code's `settings.json`. Writes values like `json`.
pub const jsonc: kosm.Adapter = .{
    .name = "jsonc",
    .extensions = &.{".jsonc"},
    .default_format = adapter.default_format,
    .format = format,
    .insert = insert,
    .parser = JsoncParser.parse,
};

const JsoncParser = @import("JsoncParser.zig");
const inserting = @import("inserting.zig");

/// An entry at the end of an object or array: `"key": value`, or the value in an array.
fn insert(allocator: std.mem.Allocator, source: []const u8, parent: *const kosm.Adapter.Node, key: ?[]const u8, value: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.InsertError![]const kosm.Adapter.Insertion {
    var entry: std.Io.Writer.Allocating = .init(allocator);
    if (key) |name| {
        writeString(&entry.writer, name) catch return error.OutOfMemory;
        entry.writer.writeAll(": ") catch return error.OutOfMemory;
    }
    entry.writer.writeAll(value) catch return error.OutOfMemory;
    return inserting.insert(allocator, source, parent, entry.written(), context);
}

/// One value as JSON: strings, colors and joined values quoted and escaped, tables and lists on
/// one line. JSON has no bare text such as `0.25s`, so a joined value is one string.
fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string => |text| try writeString(writer, text),
        .raw => |text| try writer.writeAll(text),
        .joined => {
            var buffer: [max_joined_length]u8 = undefined;
            var rendered: std.Io.Writer = .fixed(&buffer);
            writePlain(&rendered, value, context) catch |err| switch (err) {
                error.WriteFailed => return context.unsupported("a joined value is longer than {d} bytes", .{max_joined_length}),
                error.UnsupportedValue => return error.UnsupportedValue,
            };
            try writeString(writer, rendered.buffered());
        },
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| {
            if (!std.math.isFinite(float)) return context.unsupported("JSON has no infinity or NaN", .{});
            try context.writeFloat(writer, float);
        },
        .boolean => |boolean| {
            if (context.format.boolean != .true_false)
                return context.unsupported("JSON spells booleans only as true and false; leave format.boolean at .true_false", .{});
            try context.writeBoolean(writer, boolean);
        },
        .color => |color| {
            var buffer: [128]u8 = undefined;
            var color_writer: std.Io.Writer = .fixed(&buffer);
            context.writeColor(&color_writer, color) catch return context.unsupported("the color format prints more than {d} bytes", .{buffer.len});
            try writeString(writer, color_writer.buffered());
        },
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try format(writer, item, context);
            }
            try writer.writeByte(']');
        },
        .table => |entries| {
            try writer.writeByte('{');
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeString(writer, entry.key);
                try writer.writeAll(": ");
                try format(writer, entry.value, context);
            }
            try writer.writeByte('}');
        },
    }
}

/// Longest joined value written as one string.
const max_joined_length = 1024;

/// A value's text inside a string: parts of a joined value are written back to back.
fn writePlain(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string, .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| try context.writeColor(writer, color),
        .joined => |parts| for (parts) |part| try writePlain(writer, part, context),
        .list, .table => return context.unsupported("a joined value holds plain parts, not a {s}", .{@tagName(value)}),
    }
}

/// Spaces per nesting level in a generated file.
const indent_width = 2;

/// A whole file: `format`'s values, with objects and arrays that hold anything spread over
/// indented lines, ending in a newline.
fn serialize(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    try writeIndented(writer, root, 0, context);
    try writer.writeByte('\n');
}

fn writeIndented(writer: *std.Io.Writer, value: kosm.Value, depth: usize, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .table => |entries| {
            if (entries.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{\n");
            for (entries, 0..) |entry, index| {
                try writer.splatByteAll(' ', (depth + 1) * indent_width);
                try writeString(writer, entry.key);
                try writer.writeAll(": ");
                try writeIndented(writer, entry.value, depth + 1, context);
                try writer.writeAll(if (index + 1 == entries.len) "\n" else ",\n");
            }
            try writer.splatByteAll(' ', depth * indent_width);
            try writer.writeByte('}');
        },
        .list => |items| {
            if (items.len == 0) return writer.writeAll("[]");
            try writer.writeAll("[\n");
            for (items, 0..) |item, index| {
                try writer.splatByteAll(' ', (depth + 1) * indent_width);
                try writeIndented(writer, item, depth + 1, context);
                try writer.writeAll(if (index + 1 == items.len) "\n" else ",\n");
            }
            try writer.splatByteAll(' ', depth * indent_width);
            try writer.writeByte(']');
        },
        else => try format(writer, value, context),
    }
}

fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |character| switch (character) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{character}),
        else => try writer.writeByte(character),
    };
    try writer.writeByte('"');
}

const testing = std.testing;

test {
    _ = JsoncParser;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    plan: kosm.Plan,
    diagnostics: kosm.Diagnostics = .{},
    warnings: kosm.Warnings = undefined,
    home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    output: kosm.Output = undefined,

    fn init(fixture: *Fixture, files: []const [2][]const u8) !void {
        fixture.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .plan = .init(testing.allocator, testing.io) };
        for (files) |file| {
            if (std.Io.Dir.path.dirname(file[0])) |parent| try fixture.tmp.dir.createDirPath(testing.io, parent);
            try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
        }
        fixture.warnings = .init(fixture.arena.allocator());
        const length = try fixture.tmp.dir.realPath(testing.io, &fixture.home_buffer);
        fixture.output = .{
            .allocator = fixture.arena.allocator(),
            .home = fixture.home_buffer[0..length],
            .adapters = &.{ adapter, jsonc },
            .plan = &fixture.plan,
            .diagnostics = &fixture.diagnostics,
            .warnings = &fixture.warnings,
            .app = "editor",
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.plan.deinit();
        fixture.arena.deinit();
        fixture.tmp.cleanup();
    }

    fn planned(fixture: *Fixture, display_path: []const u8) []const u8 {
        for (fixture.plan.files.items) |file| {
            if (std.mem.eql(u8, file.display_path, display_path)) return file.new;
        }
        return "(not planned)";
    }
};

const vscode_settings =
    \\// Settings in here override the defaults.
    \\{
    \\    "editor.fontSize": 14,
    \\    "editor.fontFamily": "'JetBrains Mono', monospace",
    \\    /* the theme kosm keeps */
    \\    "workbench.colorCustomizations": {
    \\        "terminal.background": "#000000",
    \\        "editor.background"  :   "#101010"
    \\    },
    \\    "files.exclude": { "**/.git": true },
    \\    "editor.rulers": [80, 120]
    \\}
    \\
;

test "set changes only the value's bytes in commented, oddly spaced JSON" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "Code/User/settings.json", vscode_settings }});
    defer fixture.deinit();
    var settings = try fixture.output.edit(.{ .files = "~/Code/User/settings.json" });
    try settings.set("\"editor.fontSize\"", 16);
    try settings.set(.{ "workbench.colorCustomizations", "editor.background" }, kosm.hex("#5e81ac"));
    try settings.set("\"workbench.colorCustomizations\".\"terminal.background\"", kosm.raw("\"#102840\""));
    try settings.set("\"editor.fontFamily\"", "\"Iosevka\"\tTerm");
    try settings.set(.{ "files.exclude", "**/.git" }, false);
    try settings.set("\"editor.rulers\"", .{ 100, 140 });

    try testing.expectEqualStrings(
        \\// Settings in here override the defaults.
        \\{
        \\    "editor.fontSize": 16,
        \\    "editor.fontFamily": "\"Iosevka\"\tTerm",
        \\    /* the theme kosm keeps */
        \\    "workbench.colorCustomizations": {
        \\        "terminal.background": "#102840",
        \\        "editor.background"  :   "#5e81ac"
        \\    },
        \\    "files.exclude": { "**/.git": false },
        \\    "editor.rulers": [100, 140]
        \\}
        \\
    , fixture.planned("~/Code/User/settings.json"));
}

test "a color outside sRGB is written clipped, without a warning" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "settings.json", vscode_settings }});
    defer fixture.deinit();
    const vivid: kosm.Color = .{ .lightness = 0.9, .chroma = 0.4, .hue = 140 };
    var settings = try fixture.output.edit(.{ .files = "~/settings.json" });
    try settings.set(.{ "workbench.colorCustomizations", "editor.background" }, vivid);
    try testing.expectEqual(0, fixture.warnings.items.items.len);
    try testing.expect(std.mem.indexOf(u8, fixture.planned("~/settings.json"), "\"editor.background\"  :   \"#00ff00\"") != null);
}

test "an unchanged value leaves the file unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "settings.json", vscode_settings }});
    defer fixture.deinit();
    var settings = try fixture.output.edit(.{ .files = "~/settings.json" });
    try settings.set("\"editor.fontSize\"", 14);
    try settings.set(.{ "files.exclude", "**/.git" }, true);
    try testing.expect(!fixture.plan.hasChanges());
}

const waybar_top =
    \\{
    \\  "layer": "top",
    \\  "height": 30,
    \\  "clock": { "format": "{:%H:%M}", "interval": 60 },
    \\  "battery": { "format": "{capacity}%", "interval": 30 }
    \\}
    \\
;
const waybar_bottom =
    \\{ "layer": "bottom", "height": 24, "clock": { "format": "{:%a}" } }
    \\
;

test "cardinality decides how many matches across files may be set" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{ .{ "waybar/top.jsonc", waybar_top }, .{ "waybar/bottom.jsonc", waybar_bottom } });
    defer fixture.deinit();
    var bars = try fixture.output.edit(.{ .files = "~/waybar/*.jsonc" });

    try testing.expectError(error.TooManyMatches, bars.set("height", 32));
    try testing.expectEqualStrings("path 'height' matches 2 values (~/waybar/bottom.jsonc:1, ~/waybar/top.jsonc:3); narrow .files, or pick with setFirst, setAll or setNth", fixture.diagnostics.message());
    try testing.expectEqualStrings("~/waybar/*.jsonc", fixture.diagnostics.file);
    try testing.expectError(error.NoMatch, bars.set("width", 32));
    try testing.expectError(error.IndexOutOfRange, bars.setNth("height", 2, 32));
    try testing.expectError(error.IndexOutOfRange, bars.setRange("*.interval", 1, 3, 1));
    try testing.expectError(error.InvalidIndices, bars.setIndices("height", &.{ 0, 0 }, 1));
    try testing.expectError(error.InvalidIndices, bars.setIndices("height", &.{}, 1));
    try testing.expectError(error.InvalidIndices, bars.setRange("height", 1, 1, 1));
    try testing.expectError(error.InvalidKeyPath, bars.set("clock..format", 1));
    try testing.expectEqualStrings("path 'clock..format', column 7: a segment is empty (two dots, or a dot at an end)", fixture.diagnostics.message());
    try testing.expect(!fixture.plan.hasChanges());

    try bars.setFirst("layer", "overlay");
    try bars.setNth("height", 1, 34);
    try bars.setAll("clock.format", "{:%R}");
    try bars.setIndices("*.interval", &.{1}, 15);
    try testing.expectEqualStrings(
        \\{ "layer": "overlay", "height": 24, "clock": { "format": "{:%R}" } }
        \\
    , fixture.planned("~/waybar/bottom.jsonc"));
    try testing.expectEqualStrings(
        \\{
        \\  "layer": "top",
        \\  "height": 34,
        \\  "clock": { "format": "{:%R}", "interval": 60 },
        \\  "battery": { "format": "{capacity}%", "interval": 15 }
        \\}
        \\
    , fixture.planned("~/waybar/top.jsonc"));

    try testing.expectError(error.EditsOverlap, bars.setFirst("layer", "top"));
    try testing.expectEqualStrings("app 'editor' already writes the value on line 1 of this file; the same bytes cannot be written twice", fixture.diagnostics.message());
}

test "a duplicate key is two matches, so set refuses to guess" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.json", "{ \"size\": 1, \"size\": 2 }" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/a.json" });
    try testing.expectError(error.TooManyMatches, file.set("size", 3));
    try file.setRange("size", 0, 2, 3);
    try testing.expectEqualStrings("{ \"size\": 3, \"size\": 3 }", fixture.planned("~/a.json"));
}

test "the escape hatch reaches list elements and replaces them" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "waybar.json", "{\n  \"modules-left\": [\"clock\", { \"name\": \"tray\" }, 3],\n  \"name\": \"x\"\n}\n" }});
    defer fixture.deinit();
    var bar = try fixture.output.edit(.{ .files = "~/waybar.json" });

    const modules = try bar.nodes("modules-left");
    try testing.expectEqual(1, modules.len);
    try testing.expectEqual(.list, modules[0].kind);
    try testing.expectEqual(2, modules[0].line);
    const items = try bar.elements(modules[0]);
    try testing.expectEqual(3, items.len);
    try testing.expectEqualStrings("{ \"name\": \"tray\" }", items[1].text);
    try testing.expectEqual(.table, items[1].kind);
    try testing.expectEqual(0, (try bar.nodes("missing")).len);
    try testing.expectError(error.NotAList, bar.elements(items[0]));

    try bar.replace(items[0], "battery");
    try bar.replace(items[2], 4);
    try bar.set("name", "y");
    try testing.expectEqualStrings("{\n  \"modules-left\": [\"battery\", { \"name\": \"tray\" }, 4],\n  \"name\": \"y\"\n}\n", fixture.planned("~/waybar.json"));
}

test "edit refuses files that do not parse, naming the line" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "broken.json", "{\n  \"a\": 1,\n  \"b\" 2\n}\n" }});
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/broken.json" }));
    try testing.expectEqualStrings("~/broken.json", fixture.diagnostics.file);
    try testing.expectEqualStrings("adapter 'json': line 2, column 9: syntax error; kosm edits only files that parse", fixture.diagnostics.message());
}

test "a trailing comma is a syntax error in json and fine in jsonc" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "settings.json", "{\n  // size\n  \"a\": 1,\n}\n" }});
    defer fixture.deinit();
    try testing.expectError(error.InvalidSyntax, fixture.output.edit(.{ .files = "~/settings.json" }));
    var settings = try fixture.output.edit(.{ .files = "~/settings.json", .lang = "jsonc" });
    try settings.set("a", 2);
    try testing.expectEqualStrings("{\n  // size\n  \"a\": 2,\n}\n", fixture.planned("~/settings.json"));
}

test "an empty path reaches a top-level array, such as waybar's list of bars" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{ .{ "waybar/config.jsonc", "[\n  { \"layer\": \"top\" },\n  { \"layer\": \"bottom\" },\n]\n" }, .{ "list.json", "[1, 2]" } });
    defer fixture.deinit();
    var bars = try fixture.output.edit(.{ .files = "~/waybar/config.jsonc" });
    const roots = try bars.nodes("");
    try testing.expectEqual(1, roots.len);
    const bar_list = try bars.elements(roots[0]);
    try testing.expectEqual(2, bar_list.len);
    try testing.expectEqual(3, bar_list[1].line);
    try testing.expectError(error.InvalidKeyPath, bars.set("", 1));

    var list = try fixture.output.edit(.{ .files = "~/list.json" });
    const numbers = try list.elements((try list.nodes(""))[0]);
    try list.replace(numbers[1], 3);
    try testing.expectEqualStrings("[1, 3]", fixture.planned("~/list.json"));
}

test "edit errors for no files, a missing capability and unwritable values" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.json", "{ \"enabled\": true, \"ratio\": 0.5 }" }});
    defer fixture.deinit();
    try testing.expectError(error.NoFile, fixture.output.edit(.{ .files = "~/nowhere/*.json" }));
    try testing.expectEqualStrings("matches no file; edit only changes files that exist", fixture.diagnostics.message());
    try testing.expectError(error.NoFile, fixture.output.edit(.{ .files = "~/*.json", .exclude = &.{"~/a.json"} }));

    var file = try fixture.output.edit(.{ .files = "~/a.json", .format = .{ .boolean = .yes_no } });
    try testing.expectError(error.UnsupportedValue, file.set("enabled", false));
    try testing.expectEqualStrings("path 'enabled': adapter 'json': JSON spells booleans only as true and false; leave format.boolean at .true_false", fixture.diagnostics.message());
    try testing.expectError(error.UnsupportedValue, file.set("ratio", std.math.inf(f64)));
    const nothing: ?u8 = null;
    try testing.expectError(error.UnsupportedValue, file.set("ratio", nothing));

    var blocks = fixture.output;
    blocks.adapters = &.{.{ .name = "json", .extensions = &.{".json"}, .format = format }};
    try testing.expectError(error.MissingCapability, blocks.edit(.{ .files = "~/a.json" }));
    try testing.expectEqualStrings("adapter 'json' cannot edit files (it has no parser)", fixture.diagnostics.message());
}

test "format escapes strings and spells floats in the file's precision" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.json", "{ \"text\": \"\", \"ratio\": 1, \"nested\": {} }" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/a.json", .format = .{ .float_precision = 2 } });
    try file.set("text", "a\\b\u{1}");
    try file.set("ratio", 0.125);
    try file.set("nested", .{ .on = true, .names = .{ "x", "y" } });
    try testing.expectEqualStrings("{ \"text\": \"a\\\\b\\u0001\", \"ratio\": 0.13, \"nested\": {\"on\": true, \"names\": [\"x\", \"y\"]} }", fixture.planned("~/a.json"));
}

test "a joined value is one JSON string, so text with a unit stays valid JSON" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a.json", "{ \"duration\": \"\" }" }});
    defer fixture.deinit();
    var file = try fixture.output.edit(.{ .files = "~/a.json" });
    try file.set("duration", kosm.Value{ .joined = &.{ .{ .float = 0.25 }, .{ .raw = "s" } } });
    try testing.expectEqualStrings("{ \"duration\": \"0.25s\" }", fixture.planned("~/a.json"));
}

test "generate writes a whole file indented, empty objects and arrays on one line" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{});
    defer fixture.deinit();
    try fixture.output.generate(.{ .file = "~/theme.json" }, .{
        .id = "kosm",
        .fg = kosm.hex("#a3c5cc"),
        .chrome = .{ .accent = kosm.hex("#2d8699"), .sizes = .{ 1, 2.5 } },
        .empty = kosm.Value{ .table = &.{} },
        .none = [0]u8{},
    });
    try testing.expectEqualStrings(
        \\{
        \\  "id": "kosm",
        \\  "fg": "#a3c5cc",
        \\  "chrome": {
        \\    "accent": "#2d8699",
        \\    "sizes": [
        \\      1,
        \\      2.5
        \\    ]
        \\  },
        \\  "empty": {},
        \\  "none": []
        \\}
        \\
    , fixture.planned("~/theme.json"));
}

/// Adds `key` with `value` to the top-level object of `text` as `lang`, returning the file planned.
fn insertTop(fixture: *Fixture, lang: []const u8, text: []const u8, key: []const u8, value: anytype) ![]const u8 {
    try fixture.init(&.{.{ "settings.json", text }});
    var settings = try fixture.output.edit(.{ .files = "~/settings.json", .lang = lang });
    try settings.insert((try settings.nodes(""))[0], key, value);
    return fixture.planned("~/settings.json");
}

test "insert puts a key on its own line after the last, keeping a comment on that line" {
    const cases = [_]struct { lang: []const u8, text: []const u8, expected: []const u8 }{
        .{
            .lang = "json",
            .text = "// Vicinae\n{\n   \"a\": 1,\n   \"b\": {\n      \"c\": 2\n   } // last\n}\n",
            .expected = "// Vicinae\n{\n   \"a\": 1,\n   \"b\": {\n      \"c\": 2\n   }, // last\n   \"imports\": [\"kosm.json\"]\n}\n",
        },
        .{
            .lang = "jsonc",
            .text = "{\n\t\"a\": 1,\n}\n",
            .expected = "{\n\t\"a\": 1,\n\t\"imports\": [\"kosm.json\"],\n}\n",
        },
        .{
            .lang = "json",
            .text = "{\"a\": 1 /* x */}",
            .expected = "{\"a\": 1, \"imports\": [\"kosm.json\"] /* x */}",
        },
        .{
            .lang = "jsonc",
            .text = "{\"a\": 1, }",
            .expected = "{\"a\": 1, \"imports\": [\"kosm.json\"], }",
        },
        .{ .lang = "json", .text = "{ }\n", .expected = "{\"imports\": [\"kosm.json\"]}\n" },
    };
    for (cases) |case| {
        var fixture: Fixture = undefined;
        defer fixture.deinit();
        try testing.expectEqualStrings(case.expected, try insertTop(&fixture, case.lang, case.text, "imports", &[_][]const u8{"kosm.json"}));
    }
}

test "append adds an element after the last, or first into a list holding only comments" {
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{
            .text = "{\n  \"imports\": [\n    \"a.json\"\n  ]\n}\n",
            .expected = "{\n  \"imports\": [\n    \"a.json\",\n    \"kosm.json\"\n  ]\n}\n",
        },
        .{ .text = "{\"imports\": [\"a.json\"]}", .expected = "{\"imports\": [\"a.json\", \"kosm.json\"]}" },
        .{
            .text = "{\n\t\"imports\": [\n\t\t// \"./keybinds.json\"\n\t],\n}\n",
            .expected = "{\n\t\"imports\": [\n\t\t\"kosm.json\"\n\t\t// \"./keybinds.json\"\n\t],\n}\n",
        },
    };
    for (cases) |case| {
        var fixture: Fixture = undefined;
        try fixture.init(&.{.{ "settings.json", case.text }});
        defer fixture.deinit();
        var settings = try fixture.output.edit(.{ .files = "~/settings.json", .lang = "jsonc" });
        try settings.append((try settings.nodes("imports"))[0], "kosm.json");
        try testing.expectEqualStrings(case.expected, fixture.planned("~/settings.json"));
    }
}

test "insert refuses a key the table has and a value that is no table, and append a non-list" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "settings.json", "{\"imports\": [], \"a\": 1}" }});
    defer fixture.deinit();
    var settings = try fixture.output.edit(.{ .files = "~/settings.json" });
    const top = (try settings.nodes(""))[0];
    try testing.expectError(error.KeyExists, settings.insert(top, "imports", 1));
    try testing.expectEqualStrings("the table on line 1 already has 'imports'; set it instead", fixture.diagnostics.message());
    try testing.expectError(error.NotATable, settings.insert((try settings.nodes("a"))[0], "b", 1));
    try testing.expectError(error.NotAList, settings.append(top, 1));
    try testing.expectEqualStrings("{\"imports\": [], \"a\": 1}", fixture.planned("~/settings.json"));
}
