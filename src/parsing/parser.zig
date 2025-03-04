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

pub const Error = error{ EOF, UnexpectedToken } || Allocator.Error;

/// Parse tokens, resulting in a `Parsed` structure
pub fn parse(allocator: Allocator, tokens: []Token) Error!Parsed {
    var parsed: Parsed = try .new(allocator);
    var iter = TokenIterator{ .inner = Iter(Token).from(tokens) };

    parseObj(parsed.arena.allocator(), &parsed.root.asObj().?, &iter, null, 0) catch |err| switch (err) {
        error.EOF => {},
        else => return err,
    };

    return parsed;
}

fn parseObj(
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    ext_key: ?[]const u8,
    indent_depth: usize,
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
                    try node.put(key.?, Node{ .value = try allocator.dupe(u8, s) });
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
    return error.EOF;
}

fn parseObjOrArray(
    allocator: Allocator,
    node: *NodeMap,
    tokens: *TokenIterator,
    key: []const u8,
    indent_depth: usize,
) Error!void {
    if (tokens.next()) |tok| {
        switch (tok) {
            .syntax => {
                try tok.expectSyntax(.dash);
                const nodes: []Node = try parseArray(allocator, tokens, indent_depth);
                errdefer allocator.free(nodes);

                try node.put(key, Node{ .arr = nodes });
            },
            .string => |s| {
                var new_obj: NodeMap = .init(allocator);

                try parseObj(allocator, &new_obj, tokens, s, indent_depth);
                try node.put(key, Node{ .obj = new_obj });
            },
            else => return error.UnexpectedToken,
        }
    } else {
        return error.EOF;
    }
}

fn parseArray(allocator: Allocator, tokens: *TokenIterator, indent_depth: usize) Error![]Node {
    var nodes: ArrayList(Node) = .init(allocator);
    while (tokens.peek()) {
        try tokens.expectedIndentLevel(indent_depth);
        _ = try tokens.expectSyntax(.dash);

        // parse node
    }

    return try nodes.toOwnedSlice();
}
