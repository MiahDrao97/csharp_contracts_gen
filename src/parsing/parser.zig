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
    try tokens.expectedIndentLevel(indent_depth);
    while (tokens.next()) |tok| {
        defer self.tok_idx += 1;
        switch (tok) {
            .string => |s| {
                if (key == null) {
                    key = s;
                } else if (expecting_newline_or_eof) {
                    log.err("Expecting newline or EOF, but found {s} (token {d})", .{ s, self.tok_idx });
                    return error.UnexpectedToken;
                } else if (!colon_found) {
                    log.err("Expecting colon after key, but found {s} (token {d})", .{ s, self.tok_idx });
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
                            log.err("Expected colon syntax but found {s} (token {d})", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                    colon_found = true;
                } else if (key != null and colon_found) {
                    tok.expectSyntax(.newline) catch |err| switch (err) {
                        error.UnexpectedToken => {
                            log.err("Expected newline or string after colon but found {s} (token {d})", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                    try self.parseObjOrArray(allocator, node, tokens, key.?, indent_depth + 1);
                    key = null;
                    colon_found = false;
                    expecting_newline_or_eof = true;
                } else if (expecting_newline_or_eof) {
                    // EOF is not a parsable token and would not be returned from `TokenIterator`
                    tok.expectSyntax(.newline) catch |err| switch (err) {
                        error.UnexpectedToken => {
                            log.err("Expected newline or EOF but found {s} (token {d})", .{ @tagName(syn), self.tok_idx });
                            return err;
                        },
                    };
                } else {
                    log.err("Found unexpected syntax {s}. Was expecting string token (token {d})", .{ @tagName(syn), self.tok_idx });
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
    if (tokens.next()) |tok| {
        defer self.tok_idx += 1;
        switch (tok) {
            .syntax => {
                try tok.expectSyntax(.dash);
                const nodes: []Node = try self.parseArray(allocator, tokens, indent_depth + 1);
                errdefer allocator.free(nodes);

                try node.put(allocator, key, Node{ .arr = nodes });
            },
            .string => |s| {
                var new_obj: NodeMap = .empty;
                // indicate tail recursion
                try self.parseObj(allocator, &new_obj, tokens, s, indent_depth + 1);
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
    while (tokens.peek()) |_| {
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
                    try tokens.expectedIndentLevel(indent_depth + 1);
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
}
