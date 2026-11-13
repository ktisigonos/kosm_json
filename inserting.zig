//! Adding an entry at the end of a JSON object or array, for the adapters' `insert`: the entry
//! goes on a line of its own after the last one, indented like it, or after it on the same
//! line when the last one shares its line with the closing bracket. Comments stay where they
//! are, and a trailing comma after the last entry is kept after the new one.

const std = @import("std");
const kosm = @import("kosm");
const Node = kosm.Adapter.Node;
const Insertion = kosm.Adapter.Insertion;

/// Indentation of one level when the file has no indented line to copy it from.
const default_indent = "  ";

/// The changes adding `entry`, already spelled (`"key": value`, or a value), to `parent`.
pub fn insert(allocator: std.mem.Allocator, source: []const u8, parent: *const Node, entry: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.InsertError![]const Insertion {
    const range = parent.value.?;
    if (range.end - range.start < 2) return context.unsupported("the file holds no object or array to add to", .{});
    const open = range.start;
    const close = range.end - 1;
    if (parent.children.len == 0) return intoEmpty(allocator, source, open, close, entry);

    const last_end = parent.children[parent.children.len - 1].value.?.end;
    var position = skipInline(source, last_end, close);
    const comma: ?usize = if (source[position] == ',') position else null;
    const has_comma = comma != null;
    if (comma) |at| position = skipInline(source, at + 1, close);
    if (std.mem.startsWith(u8, source[position..close], "//")) position = lineEnd(source, position, close);

    if (source[position] == '\n' or source[position] == '\r') {
        const indent = indentOf(source, parent.children[parent.children.len - 1].position);
        const line = try std.mem.concat(allocator, u8, &.{ "\n", indent, entry, if (has_comma) "," else "" });
        if (has_comma) return allocator.dupe(Insertion, &.{.{ .start = position, .end = position, .content = line }});
        return allocator.dupe(Insertion, &.{
            .{ .start = last_end, .end = last_end, .content = "," },
            .{ .start = position, .end = position, .content = line },
        });
    }
    if (comma) |at| {
        return allocator.dupe(Insertion, &.{.{ .start = at + 1, .end = at + 1, .content = try std.mem.concat(allocator, u8, &.{ " ", entry, "," }) }});
    }
    return allocator.dupe(Insertion, &.{.{ .start = last_end, .end = last_end, .content = try std.mem.concat(allocator, u8, &.{ ", ", entry }) }});
}

/// An empty object or array: holding only spaces, it becomes `[entry]`; holding comments, the
/// entry goes on its own line first, one level deeper than the bracket's line.
fn intoEmpty(allocator: std.mem.Allocator, source: []const u8, open: usize, close: usize, entry: []const u8) kosm.Adapter.InsertError![]const Insertion {
    const inside = source[open + 1 .. close];
    if (std.mem.trim(u8, inside, " \t\r\n").len == 0)
        return allocator.dupe(Insertion, &.{.{ .start = open + 1, .end = close, .content = entry }});
    const line = try std.mem.concat(allocator, u8, &.{ "\n", indentOf(source, open), indentUnit(source), entry });
    return allocator.dupe(Insertion, &.{.{ .start = open + 1, .end = open + 1, .content = line }});
}

/// The first byte from `start` that is neither a space, a tab nor inside a block comment;
/// `limit` when there is none before it.
fn skipInline(source: []const u8, start: usize, limit: usize) usize {
    var position = start;
    while (position < limit) {
        switch (source[position]) {
            ' ', '\t' => position += 1,
            '/' => {
                if (!std.mem.startsWith(u8, source[position..limit], "/*")) return position;
                const comment_end = std.mem.indexOfPos(u8, source[0..limit], position + 2, "*/") orelse return limit;
                position = comment_end + 2;
            },
            else => return position,
        }
    }
    return limit;
}

/// Where the line holding `start` ends: its line break, or `limit`.
fn lineEnd(source: []const u8, start: usize, limit: usize) usize {
    return std.mem.indexOfAnyPos(u8, source[0..limit], start, "\r\n") orelse limit;
}

/// The spaces and tabs starting the line that holds `position`.
fn indentOf(source: []const u8, position: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..position], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[line_start..end];
}

/// One level of the file's indentation: the shortest one starting a line, or `default_indent`.
fn indentUnit(source: []const u8) []const u8 {
    var shortest: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var end: usize = 0;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) end += 1;
        if (end == 0 or end == line.len) continue;
        if (shortest == null or end < shortest.?.len) shortest = line[0..end];
    }
    return shortest orelse default_indent;
}
