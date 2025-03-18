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
const ArrayList = std.ArrayList;

pub const Error = error{ EOF, UnexpectedToken, InvalidKey } || Allocator.Error;

/// Parse tokens, resulting in a `Parsed` structure
pub fn parse(allocator: Allocator, tokens: []Token) Error!Parsed {
    var parsed: Parsed = try .new(allocator);
    var iter = TokenIterator{ .inner = Iter(Token).from(tokens) };

    try parseObj(parsed.arena.allocator(), parsed.root.asObjPtr().?, &iter, null, 0);

    return parsed;
}

fn parseObj(
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    ext_key: ?[]const u8,
    indent_depth: u16,
) Error!void {
    var key: ?[]const u8 = ext_key;
    var colon_found: bool = false;
    try tokens.expectedIndentLevel(indent_depth);
    while (tokens.next()) |tok| {
        switch (tok) {
            .string => |s| {
                if (key == null) {
                    key = s;
                } else if (!colon_found) {
                    return error.UnexpectedToken;
                } else {
                    // key-value
                    try node.put(allocator, key.?, Node{ .value = try allocator.dupe(u8, s) });
                    key = null;
                    colon_found = false;
                }
            },
            .syntax => {
                if (key != null) {
                    try tok.expectSyntax(.colon);
                    colon_found = true;
                }
                return error.UnexpectedToken;
            },
            else => unreachable,
        }
    }
}

fn parseObjOrArray(
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    key: []const u8,
    indent_depth: u16,
) Error!void {
    if (tokens.next()) |tok| {
        switch (tok) {
            .syntax => {
                try tok.expectSyntax(.dash);
                const nodes: []Node = try parseArray(allocator, tokens, indent_depth + 1);
                errdefer allocator.free(nodes);

                try node.put(allocator, key, Node{ .arr = nodes });
            },
            .string => |s| {
                var new_obj: NodeMap = .init(allocator);
                // indicate tail recursion
                try @call(.always_tail, parseObj, .{ allocator, &new_obj, tokens, s, indent_depth + 1 });
                try node.put(allocator, key, Node{ .obj = new_obj });
            },
            else => return error.UnexpectedToken,
        }
    } else {
        return error.EOF;
    }
}

fn parseArray(allocator: Allocator, tokens: *TokenIterator, indent_depth: u16) Error![]Node {
    var nodes: ArrayList(Node) = .init(allocator);
    while (tokens.peek()) |_| {
        if (tokens.getIndentLevel(indent_depth) == indent_depth) {
            _ = try tokens.expectSyntax(.dash);
            try nodes.append(allocator, try parseNode(allocator, tokens, indent_depth));
        } else break;
    }

    return try nodes.toOwnedSlice();
}

fn parseNode(allocator: Allocator, tokens: *TokenIterator, indent_depth: u16) Error!Node {
    if (tokens.next()) |tok| {
        switch (tok) {
            .string => |str| return Node{ .value = str },
            .syntax => |syn| switch (syn) {
                .newline => {
                    try tokens.expectedIndentLevel(indent_depth + 1);
                    switch (tokens.peek() orelse return error.EOF) {
                        .string => |_| {
                            var obj: NodeMap = .empty;
                            try @call(.always_tail, parseObj, .{ allocator, &obj, tokens, null, indent_depth + 1 });
                            return Node{ .obj = obj };
                        },
                        .syntax => |x| switch (x) {
                            .dash => {
                                return Node{ .arr = try @call(.always_tail, parseArray, .{ allocator, tokens, indent_depth + 1 }) };
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
