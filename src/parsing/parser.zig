const std = @import("std");
const root = @import("root.zig");
const iter_z = @import("iter_z");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const SyntaxToken = Tokenizer.SyntaxToken;
const TokenIterator = Tokenizer.TokenIterator;
const Parsed = root.Parsed;
const Node = root.Node;
const Iter = iter_z.Iter;
const Allocator = std.mem.Allocator;
const NodeMap = root.NodeMap;
const ArrayList = std.ArrayListUnmanaged;
const testing = std.testing;
const log = std.log.scoped(.parser);

const Parser = @This();

tok_idx: usize,

pub const Error = error{ EOF, UnexpectedToken, InvalidKey } || Allocator.Error;

pub const init: Parser = .{ .tok_idx = 0 };

/// Parse tokens, resulting in a `Parsed` structure
pub fn parse(self: *Parser, allocator: Allocator, tokens: []const Token) Error!Parsed {
    self.tok_idx = 0;

    var parsed: Parsed = try .new(allocator);
    errdefer parsed.deinit();

    var iter = TokenIterator{ .inner = Iter(Token).from(tokens) };
    try self.parseObj(parsed.arena.allocator(), &parsed.root, &iter, null, 0);

    return parsed;
}

fn parseObj(
    self: *Parser,
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    ext_key: ?[]const u8,
    indent_depth: u16,
) Error!void {
    var key: ?[]const u8 = ext_key;
    var colon_found: bool = false;
    var expecting_newline_or_eof: bool = false;
    tokens.expectIndentLevel(indent_depth) catch |err| {
        log.err("Expected indent level {d} but found '{s}' (tokens[{d}])", .{
            indent_depth,
            if (tokens.peek()) |t| t.asString() else "<EOF>",
            self.tok_idx,
        });
        return err;
    };
    while (tokens.next()) |tok| {
        defer self.tok_idx += 1;
        log.debug("Next token while parsing object: '{s}' (tokens[{d}])", .{ tok.asString(), self.tok_idx });
        switch (tok) {
            .string => |s| {
                if (key == null) {
                    key = s;
                } else if (expecting_newline_or_eof) {
                    log.err("Expecting newline or EOF, but found string token '{s}' (token[{d}])", .{ s, self.tok_idx });
                    dumpNodeMap(node);
                    return error.UnexpectedToken;
                } else if (!colon_found) {
                    log.err("Expecting colon after key, but found string token '{s}' (token[{d}])", .{ s, self.tok_idx });
                    return error.UnexpectedToken;
                } else {
                    // key-value
                    try node.put(allocator, key.?, Node{ .value = try allocator.dupe(u8, s) });
                    key = null;
                    colon_found = false;
                    expecting_newline_or_eof = true;
                }
            },
            .syntax => |syn| {
                if (key != null and !colon_found) {
                    tok.expectSyntax(.colon) catch |err| switch (err) {
                        error.UnexpectedToken => {
                            log.err("Expected colon syntax but found {s} (token[{d}])", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                    colon_found = true;
                    log.debug("Colon found (tokens[{d}])", .{self.tok_idx});
                } else if (key != null and colon_found) {
                    tok.expectSyntax(.newline) catch |err| switch (err) {
                        error.UnexpectedToken => {
                            log.err("Expected newline or string after colon but found {s} (token[{d}])", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                    try self.parseObjOrArray(allocator, node, tokens, key.?, indent_depth + 1);
                    key = null;
                    colon_found = false;
                    expecting_newline_or_eof = true;
                    log.debug("Finished parsing array (tokens[{d}])", .{self.tok_idx});
                } else if (expecting_newline_or_eof) {
                    // EOF is not a parsable token and would not be returned from `TokenIterator`
                    tok.expectSyntax(.newline) catch |err| switch (err) {
                        error.UnexpectedToken => {
                            log.err("Expected newline or EOF but found {s} (token[{d}])", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                    expecting_newline_or_eof = false;
                } else {
                    log.err("Found unexpected syntax {s}. Was expecting string token (token[{d}])", .{ @tagName(syn), self.tok_idx });
                    return error.UnexpectedToken;
                }
            },
            else => unreachable,
        }
    }
    if (!expecting_newline_or_eof) {
        log.err("Encountered premature EOF.", .{});
        return error.EOF;
    }
}

fn parseObjOrArray(
    self: *Parser,
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    key: []const u8,
    indent_depth: u16,
) Error!void {
    tokens.expectIndentLevel(indent_depth) catch |err| {
        switch (err) {
            error.UnexpectedToken => log.err("Did not find indent level {d},", .{indent_depth}),
            error.EOF => log.err("Encountered EOF while expecting indent level {d}.", .{indent_depth}),
        }
        return err;
    };
    self.tok_idx += indent_depth;
    if (tokens.peek()) |tok| {
        switch (tok) {
            .syntax => |syn| {
                tok.expectSyntax(.dash) catch |err| switch (err) {
                    error.UnexpectedToken => {
                        log.err("Expected dash syntax but found {s} (token[{d}]). Next token: {s}", .{
                            @tagName(syn),
                            self.tok_idx,
                            if (tokens.peek()) |t| t.asString() else "<EOF>",
                        });
                        return err;
                    }
                };
                const nodes: []Node = try self.parseArray(allocator, tokens, indent_depth);
                errdefer allocator.free(nodes);

                try node.put(allocator, key, Node{ .arr = nodes });
            },
            .string => |s| {
                // consume the token
                _ = tokens.next();
                self.tok_idx += 1;

                var new_obj: NodeMap = .empty;
                // indicate tail recursion
                try self.parseObj(allocator, &new_obj, tokens, s, indent_depth);
                try node.put(allocator, key, Node{ .obj = new_obj });
            },
            else => unreachable,
        }
    } else {
        return error.EOF;
    }
}

fn parseArray(self: *Parser, allocator: Allocator, tokens: *TokenIterator, indent_depth: u16) Error![]Node {
    var nodes: ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);
    var first: bool = true;
    while (tokens.peek()) |_| {
        if (first) {
            first = false;
            _ = try tokens.expectSyntax(.dash);
            self.tok_idx += 1;
            try nodes.append(allocator, try self.parseNode(allocator, tokens, indent_depth));
            _ = try tokens.expectSyntax(.newline);
            self.tok_idx += 1;
            continue;
        }

        const actual_indent_level: u16 = tokens.getIndentLevel();
        self.tok_idx += actual_indent_level;
        if (actual_indent_level == indent_depth) {
            _ = try tokens.expectSyntax(.dash);
            self.tok_idx += 1;
            try nodes.append(allocator, try self.parseNode(allocator, tokens, indent_depth));
        } else break;
    }

    return try nodes.toOwnedSlice(allocator);
}

fn parseNode(self: *Parser, allocator: Allocator, tokens: *TokenIterator, indent_depth: u16) Error!Node {
    if (tokens.next()) |tok| {
        defer self.tok_idx += 1;
        switch (tok) {
            .string => |str| return Node{ .value = str },
            .syntax => |syn| switch (syn) {
                .newline => {
                    try tokens.expectIndentLevel(indent_depth + 1);
                    switch (tokens.peek() orelse return error.EOF) {
                        .string => |_| {
                            var obj: NodeMap = .empty;
                            try self.parseObj(allocator, &obj, tokens, null, indent_depth + 1);
                            return Node{ .obj = obj };
                        },
                        .syntax => |x| switch (x) {
                            .dash => {
                                return Node{ .arr = try self.parseArray(allocator, tokens, indent_depth + 1) };
                            },
                            else => return error.UnexpectedToken,
                        },
                        else => return error.UnexpectedToken,
                    }
                },
                else => return error.UnexpectedToken,
            },
            else => return error.UnexpectedToken,
        }
    }
    return error.EOF;
}

fn dumpNodeMap(obj: *const NodeMap) void {
    if ((@import("builtin").is_test and testing.log_level != .debug) or !std.log.logEnabled(.debug, .parser)) {
        return;
    }

    var buf: [4096]u8 = undefined;
    var stack_alloc: std.heap.FixedBufferAllocator = .init(&buf);

    const ctx = struct {
        fn innerDump(allocator: Allocator, inner_obj: *const NodeMap, level: u16) Allocator.Error![]const u8 {
            var str_arr: ArrayList(u8) = .empty;
            var inner_iter: NodeMap.Iterator = inner_obj.iter();
            while (inner_iter.next()) |inner_kvp| {
                if (level > 0) {
                    try str_arr.appendNTimes(allocator, ' ', level * 2);
                }
                try str_arr.appendSlice(allocator, inner_kvp.@"0");
                try str_arr.append(allocator, ':');
                switch (inner_kvp.@"1".*) {
                    .obj => |*o| {
                        try str_arr.append(allocator, '\n');
                        try str_arr.appendSlice(allocator, try innerDump(allocator, o, level + 1));
                    },
                    .value => |v| {
                        try str_arr.append(allocator, ' ');
                        try str_arr.appendSlice(allocator, v);
                    },
                    .arr => |a| {
                        try str_arr.append(allocator, '\n');
                        for (a) |elem| {
                            try str_arr.appendNTimes(allocator, ' ', (level + 1) * 2);
                            try str_arr.appendSlice(allocator, "- ");
                            try str_arr.appendSlice(allocator, try dumpNode(allocator, elem, level + 1));
                            try str_arr.append(allocator, '\n');
                        }
                    }
                }
                try str_arr.append(allocator, '\n');
            }
            return try str_arr.toOwnedSlice(allocator);
        }

        fn dumpNode(allocator: Allocator, inner_node: Node, level: u16) Allocator.Error![]const u8 {
            return switch (inner_node) {
                .obj => |*o| innerDump(allocator, o, level + 1),
                .value => |v| v,
                .arr => |a| blk: {
                    var str_arr: ArrayList(u8) = .empty;
                    for (a) |elem| {
                        try str_arr.appendSlice(allocator, try dumpNode(allocator, elem, level + 1));
                    }
                    break :blk try str_arr.toOwnedSlice(allocator);
                }
            };
        }
    };

    const result: []const u8 = ctx.innerDump(stack_alloc.allocator(), obj, 0) catch |err| {
        log.warn("Could not dump node map due to buffer overflow: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
        return;
    };
    log.debug("Dumped node map:\n{s}", .{result});
}

test "parse simple object" {
    const tokens = [_]Token{
        .{ .string = "key" },
        .{ .syntax = .colon },
        .{ .string = "value" },
        .eof,
    };
    var parser: Parser = .init;
    const parsed: Parsed = try parser.parse(testing.allocator, &tokens);
    defer parsed.deinit();

    try testing.expectEqualStrings("value", parsed.root.get("key").?.asValue().?);
}
test "parse array" {
    // arr:
    //   - item1
    //   - item2
    // key: value
    const tokens = [_]Token{
        .{ .string = "arr" },
        .{ .syntax = .colon },
        .{ .syntax = .newline },
        .{ .syntax = .indent },
        .{ .syntax = .dash },
        .{ .string = "item1" },
        .{ .syntax = .newline },
        .{ .syntax = .indent },
        .{ .syntax = .dash },
        .{ .string = "item2" },
        .{ .syntax = .newline },
        .{ .string = "key" },
        .{ .syntax = .colon },
        .{ .string = "value" },
        .eof,
    };

    var parser: Parser = .init;
    const parsed: Parsed = try parser.parse(testing.allocator, &tokens);
    defer parsed.deinit();

    try testing.expectEqualStrings("value", parsed.root.get("key").?.asValue().?);
    const arr: []const Node = parsed.root.get("arr").?.arr;
    try testing.expectEqual(2, arr.len);
    try testing.expectEqualStrings("item1", arr[0].asValue().?);
    try testing.expectEqualStrings("item2", arr[1].asValue().?);
}
test "parse object" {
    // obj:
    //   prop1: val1
    //   prop2: val2
    const tokens = [_]Token{
        .{ .string = "obj" },
        .{ .syntax = .colon },
        .{ .syntax = .newline },
        .{ .syntax = .indent },
        .{ .string = "prop1" },
        .{ .syntax = .colon },
        .{ .string = "val1" },
        .{ .syntax = .newline },
        .{ .syntax = .indent },
        .{ .string = "prop2" },
        .{ .syntax = .colon },
        .{ .string = "val2" },
        .eof,
    };

    var parser: Parser = .init;
    const parsed: Parsed = try parser.parse(testing.allocator, &tokens);
    defer parsed.deinit();

    var nested_obj: ?Node = parsed.root.get("obj");
    try testing.expect(nested_obj != null);
    try testing.expect(nested_obj.?.asObjPtr() != null);
    try testing.expectEqualStrings("val1", nested_obj.?.asObjPtr().?.get("prop1").?.value);
    try testing.expectEqualStrings("val2", nested_obj.?.asObjPtr().?.get("prop2").?.value);
}
