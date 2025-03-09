const std = @import("std");
const zul = @import("zul");
const iter_z = @import("iter_z");
const root = @import("root.zig");
const Iter = iter_z.Iter;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const LineIterator = root.LineIterator;
const ArrayList = std.ArrayListUnmanaged;
const ParseConfig = root.ParseConfig;
const testing = std.testing;
const log = std.log;

/// Which line number we're on
line_no: usize = 1,
/// Which position on the line we're on (0-indexed)
pos: usize = 0,
/// Configuration for parsing
config: ParseConfig,
/// Arena allocator
arena: *ArenaAllocator,
/// Parent of the arena allocator
parent_alloc: Allocator,

pub const Tokenizer = @This();

pub const Error = error{
    InvalidSyntax,
    UnterminatedQuotes,
    EarlyLineTermination,
    UnexpectedToken,
    InvalidEscapeSequence,
    ReadFileError,
} || Allocator.Error;

/// Token for the parser to intelligbly piece together what in the world we're doing
pub const Token = union(enum) {
    /// String token (basically a key or value)
    string: []const u8,
    /// Symbol, including newline and indents
    syntax: SyntaxToken,
    /// Comment (not parsable)
    comment,
    /// End of file
    eof,

    /// Expecting syntax for a specific token or return `error.UnexpectedToken`
    pub fn expectSyntax(self: Token, syntax: SyntaxToken) error{UnexpectedToken}!void {
        switch (self) {
            .syntax => |s| {
                if (s != syntax) {
                    return error.UnexpectedToken;
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    /// Get the string value of a token if it is a string
    pub fn isString(self: Token) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asString(self: Token) []const u8 {
        return switch (self) {
            .string => |str| str,
            .syntax => |syn| switch (syn) {
                .colon => ":",
                .dash => "-",
                .newline => "\\n",
                .indent => "\\t",
            },
            .comment => "#comment",
            .eof => "<EOF>",
        };
    }
};

fn dumpTokens(allocator: Allocator, tokens: []Token) Allocator.Error!void {
    if (!log.defaultLogEnabled(.debug)) {
        return;
    }
    var dump: ArrayList(u8) = .empty;
    defer dump.deinit(allocator);
    try dump.appendSlice(allocator, "Tokens: [ ");

    var first: bool = true;
    var buf: [256]u8 = undefined;
    for (tokens) |tok| {
        if (first) {
            try dump.appendSlice(allocator, std.fmt.bufPrint(&buf, "{s}", .{tok.asString()}) catch unreachable);
            first = false;
        } else {
            try dump.appendSlice(allocator, std.fmt.bufPrint(&buf, ", {s}", .{tok.asString()}) catch unreachable);
        }
    }
    try dump.appendSlice(allocator, " ]");

    log.debug("{s}\n", .{dump.items});
}

/// Various syntax tokens (symbols only, including newlines and indents)
pub const SyntaxToken = enum {
    /// :
    colon,
    /// -
    dash,
    /// new line character
    newline,
    /// indent, whether that is an explicit tab character or a series of spaces that equal our tab size (from `ParseConfig`)
    indent,
};

/// In multi-line value blocks, how are newlines handled?
const BlockStyle = enum {
    /// Newlines are ommitted from the block (indicated by '>')
    folded,
    /// Newlines are included (indicated by '|')
    literal,
};

/// In multi-line value blocks, how are trailing newlines handled?
const ChompStyle = enum {
    /// single newline at the end (indicated without any character processeding the '|' or '>')
    clip,
    /// no newlines at the end (indicidated by '-' after the '|' or '>')
    strip,
    /// all newlines are included at the end (indicated by '+' after the '|' or '>')
    keep,
};

/// Which kind of quotes we're dealing with if the value is in quotes (this is relevant for escape sequences)
const QuoteType = enum { single, double };

fn isNonWhitespace(byte: u8) bool {
    return !std.ascii.isWhitespace(byte);
}

/// Iterator for tokens, which includes helper methods.
/// The EOF token is excludeed on `next()` and `peek()`, so the caller may assume that a null result on either of methods means EOF.
pub const TokenIterator = struct {
    inner: Iter(Token),

    fn isParsableToken(token: Token) bool {
        return switch (token) {
            .eof, .comment => false,
            else => true,
        };
    }

    /// Next token (excludes EOF and comments)
    pub fn next(self: *TokenIterator) ?Token {
        return self.inner.any(isParsableToken, false);
    }

    /// Peek at the next token (excludes EOF and comments)
    pub fn peek(self: *TokenIterator) ?Token {
        return self.inner.any(isParsableToken, true);
    }

    /// Expect the next token to be a specific syntax symbol
    pub fn expectSyntax(self: *TokenIterator, syntax: SyntaxToken) error{UnexpectedToken}!Token {
        if (self.peek()) |tok| {
            try tok.expectSyntax(syntax);
            _ = self.next();
            return tok;
        }
        return error.UnexpectedToken;
    }

    /// Expect a specific indent level
    pub fn expectedIndentLevel(self: *TokenIterator, indents: u16) error{UnexpectedToken}!void {
        var i: u16 = 1;
        while (i < indents) : (i += 1) {
            _ = try self.expectSyntax(.indent);
            if (i == indents) {
                break;
            }
        }
    }

    /// De-initialize internal iterator, which results in this becoming empty
    pub fn deinit(self: *TokenIterator) void {
        self.inner.deinit();
    }
};

/// Initialize wew tokenizer
pub fn new(allocator: Allocator, config: ParseConfig) Allocator.Error!Tokenizer {
    const arena: *ArenaAllocator = try allocator.create(ArenaAllocator);
    arena.* = .init(allocator);

    return Tokenizer{
        .arena = arena,
        .parent_alloc = allocator,
        .config = config,
    };
}

/// Tokenize, using zul's `LineIterator`.
///
/// NOTE : The returned tokens are owned by this tokenizer's arena.
/// To free, call `deinit()` on this tokenizer.
pub fn tokenize(self: *Tokenizer, iter: *LineIterator) Error![]Token {
    var tokens: ArrayList(Token) = .empty;
    var indent_level: u16 = 0;
    // because we're using an arena, don't worry about errdefer (we'll put that burden on the caller)

    // zig fmt: off
    while (iter.next() catch |err| {
        log.err("Could not read next line ({d}): {s} -> {?}", .{ self.line_no, @errorName(err), @errorReturnTrace() });
        return error.ReadFileError;
    })

    |next_line| {
        // zig fmt: on
        const trimmed: []const u8 = std.mem.trim(u8, next_line, " \t");
        if (trimmed[0] == '#') {
            try tokens.append(self.arena.allocator(), .comment);
            self.line_no += 1;
        } else {
            var tokenize_next: []const u8 = next_line;
            while (true) {
                defer self.line_no += 1;
                if (try self.tokenizeLine(&tokens, tokenize_next, &indent_level)) |block_value| {
                    var out_next_line: ?[]const u8 = null;
                    var word: ArrayList(u8) = .empty;
                    try self.tokenizeBlock(
                        iter,
                        &word,
                        block_value.@"0",
                        block_value.@"1",
                        indent_level,
                        &out_next_line,
                    );
                    try tokens.append(self.arena.allocator(), Token{
                        .string = try word.toOwnedSlice(self.arena.allocator()),
                    });
                    // We're treating blocks as though the newline token is only at the end of the value, regardless of block/chomp style.
                    // Makes parsing easier to expect key, colon, value, newline
                    try tokens.append(self.arena.allocator(), Token{ .syntax = .newline });
                    // check if we overshot
                    if (out_next_line) |next| {
                        log.debug("Encountered next line while tokenizing block-->{s}", .{next});
                        tokenize_next = next;
                        indent_level -= 1;
                        continue;
                    }
                    break;
                }
                break;
            }
        }
        // do we need to manually append a newline to our tokens list or does that happen in `tokenizeLine`?
    }
    try tokens.append(self.arena.allocator(), .eof);

    return try tokens.toOwnedSlice(self.arena.allocator());
}

fn tokenizeLine(
    self: *Tokenizer,
    tokens: *ArrayList(Token),
    line: []const u8,
    indent_level: *u16,
) Error!?struct { BlockStyle, ChompStyle } {
    log.debug("From tokenizeLine()-->{s}", .{line});
    var spaces: u8 = 0;
    var word: ArrayList(u8) = try .initCapacity(self.arena.allocator(), line.len);
    errdefer word.deinit(self.arena.allocator());

    // reset position to 0
    defer self.pos = 0;

    var lh_index: usize = 0;
    for (line) |byte| {
        defer {
            lh_index += 1;
            self.pos += 1;
        }
        switch (byte) {
            ' ' => {
                spaces += 1;
                if (spaces == self.config.tab_size) {
                    indent_level.* += 1;
                    spaces = 0;
                }
            },
            '\t' => indent_level.* += 1,
            ':' => {
                // append key and colon
                try dumpTokens(self.arena.allocator(), tokens.items);
                const word_slice: []const u8 = try word.toOwnedSlice(self.arena.allocator());
                log.debug("Appending key '{s}' and colon character.", .{word_slice});
                try tokens.append(self.arena.allocator(), Token{ .string = word_slice });
                try tokens.append(self.arena.allocator(), Token{ .syntax = .colon });
                try dumpTokens(self.arena.allocator(), tokens.items);
                break;
            },
            '-' => {
                try tokens.append(self.arena.allocator(), Token{ .syntax = .dash });
                break;
            },
            else => {
                if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$') {
                    log.err("Encountered invalid character '{c}' on key name (LH-side of colon): Line {d}, pos {d}\n\t'{s}'", .{
                        byte,
                        self.line_no,
                        self.pos,
                        line,
                    });
                    return error.UnexpectedToken;
                }
                // shouldn't have OOM error since we initialized this capacity
                word.append(self.arena.allocator(), byte) catch unreachable;
            },
        }
    }

    log.debug("Finished reading key-->{s}\n    Now reading value-->{s}", .{ tokens.items[tokens.items.len - 2].asString(), line[lh_index..] });
    var iter: Iter(u8) = .from(line[lh_index..]);
    // consume whitespace
    const next: ?u8 = iter.any(isNonWhitespace, false);
    // this scenario means that we have a "key: \n" situation, which is invalid
    if (next == null) {
        log.err("Encountered early line termination: Line {d}, pos {d}\n\t'{s}'", .{ self.line_no, self.pos, line });
        return error.EarlyLineTermination;
    }
    // is this a multi-line value block or just a single line value?
    switch (next.?) {
        '|' => {
            const block_tok: ?u8 = iter.any(isNonWhitespace, false);
            log.debug("Encountered block value indicator '|', following by chomp style <{?}>", .{block_tok});
            try dumpTokens(self.arena.allocator(), tokens.items);
            indent_level.* += 1;
            if (block_tok) |tok| {
                return switch (tok) {
                    '+' => .{ BlockStyle.literal, ChompStyle.keep },
                    '-' => .{ BlockStyle.literal, ChompStyle.strip },
                    else => blk: {
                        log.err("Enountered invalid character '{c}' following '|': Line {d}, pos {d}\n\t'{s}'", .{
                            block_tok orelse 0,
                            self.line_no,
                            self.pos,
                            line,
                        });
                        break :blk error.UnexpectedToken;
                    },
                };
            }
            return .{ BlockStyle.literal, ChompStyle.clip };
        },
        '>' => {
            const block_tok: ?u8 = iter.any(isNonWhitespace, false);
            log.debug("Encountered block value indicator '>', following by chomp style {?}", .{block_tok});
            try dumpTokens(self.arena.allocator(), tokens.items);
            indent_level.* += 1;
            if (block_tok) |tok| {
                return switch (tok) {
                    '+' => .{ BlockStyle.folded, ChompStyle.keep },
                    '-' => .{ BlockStyle.folded, ChompStyle.strip },
                    else => blk: {
                        log.err("Enountered invalid character '{c}' following '>': Line {d}, pos {d}\n\t'{s}'", .{
                            block_tok orelse 0,
                            self.line_no,
                            self.pos,
                            line,
                        });
                        break :blk error.UnexpectedToken;
                    },
                };
            }
            return .{ BlockStyle.folded, ChompStyle.clip };
        },
        // parse normally
        else => iter.scroll(-1),
    }

    log.debug("Not a block value-->{s}", .{line});
    // get the rest of the line
    word = try .initCapacity(self.arena.allocator(), line.len);
    var first: bool = true;
    var quote_type: ?QuoteType = null;
    var start_escape: bool = false;
    while (iter.next()) |byte| {
        if (first and byte == '\'') {
            quote_type = .single;
        } else if (first and byte == '"') {
            quote_type = .double;
        }

        if (first) {
            first = false;
        }

        if (quote_type != null and byte == '\\') {
            if (start_escape) {
                word.append(self.arena.allocator(), '\\') catch unreachable;
                start_escape = false;
            } else {
                start_escape = true;
                continue;
            }
        }

        if (start_escape) {
            switch (byte) {
                '"' => {
                    switch (quote_type.?) {
                        .single => {
                            log.err("Invalid escape sequence: \\', line: {d}, pos: {d}", .{ self.line_no, self.pos });
                            return error.InvalidEscapeSequence;
                        },
                        .double => word.append(self.arena.allocator(), byte) catch unreachable,
                    }
                },
                '\'' => {
                    switch (quote_type.?) {
                        .single => word.append(self.arena.allocator(), byte) catch unreachable,
                        .double => {
                            log.err("Invalid escape sequence: \\\", line: {d}, pos: {d}", .{ self.line_no, self.pos });
                            return error.InvalidEscapeSequence;
                        },
                    }
                },
                else => {
                    log.err("Invalid escape sequence: \\{c}, line: {d}, pos: {d}", .{ byte, self.line_no, self.pos });
                    return error.InvalidEscapeSequence;
                },
            }
            start_escape = false;
            continue;
        }

        word.append(self.arena.allocator(), byte) catch unreachable;
    }

    if (quote_type) |q| {
        const last_char: u8 = word.getLast();
        switch (q) {
            .single => {
                if (word.items.len == 1 or last_char != '\'') {
                    log.err("Line not properly terminated. Expected single quote, but found {c}: line: {d}, pos: {d}", .{
                        last_char,
                        self.line_no,
                        self.pos,
                    });
                    return error.UnterminatedQuotes;
                }
            },
            .double => {
                if (word.items.len == 1 or last_char != '"') {
                    log.err("Line not properly terminated. Expected double quote, but found {c}: line: {d}, pos: {d}", .{
                        last_char,
                        self.line_no,
                        self.pos,
                    });
                    return error.UnterminatedQuotes;
                }
            },
        }
    }

    log.debug("Appending value-->{s}", .{word.items});
    try tokens.append(self.arena.allocator(), Token{ .string = try word.toOwnedSlice(self.arena.allocator()) });
    if (line[line.len - 1] == '\n') {
        try tokens.append(self.arena.allocator(), Token{ .syntax = .newline });
    }

    return null;
}

/// Tokenize block values
/// For reference: https://yaml-multiline.info/
fn tokenizeBlock(
    self: Tokenizer,
    lines: *LineIterator,
    value: *ArrayList(u8),
    block_style: BlockStyle,
    chomp_style: ChompStyle,
    indent_level: u16,
    out_next_line: *?[]const u8,
) Error!void {
    const next_line: []const u8 = lines.next() catch |err| {
        log.err("Failed to read next line: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
        return error.ReadFileError;
    } orelse return;
    log.debug("From tokenizeBlock()-->{s}", .{next_line});
    var next_line_iter: Iter(u8) = .from(next_line);
    var indent_count: u16 = 0;
    var space_count: u16 = 0;
    while (next_line_iter.next()) |byte| {
        switch (byte) {
            ' ' => {
                space_count += 1;
                if (space_count == self.config.tab_size) {
                    indent_count += 1;
                    space_count = 0;
                }
            },
            '\t' => indent_count += 1,
            else => {
                next_line_iter.scroll(-1);
                break;
            },
        }
    }
    log.debug("Indent count is {d} with indent level {d} on current line-->{s}", .{ indent_count, indent_level, next_line });
    if (indent_count < indent_level) {
        // ope, we're on the next line now
        log.debug("Encountered next line while parsing block. Block is complete. New line-->{s}", .{next_line});
        out_next_line.* = next_line;
        return;
    }

    switch (block_style) {
        .folded => {
            while (next_line_iter.next()) |byte| {
                if (byte != '\n') {
                    value.append(self.arena.allocator(), byte) catch unreachable;
                }
            }
        },
        .literal => {
            while (next_line_iter.next()) |byte| {
                value.append(self.arena.allocator(), byte) catch unreachable;
            }
        },
    }
    switch (chomp_style) {
        .clip => {
            while (value.getLastOrNull() == '\n') {
                _ = value.pop();
            }
            value.append(self.arena.allocator(), '\n') catch unreachable;
        },
        .strip => {
            while (value.getLastOrNull() == '\n') {
                _ = value.pop();
            }
        },
        .keep => {},
    }
    try @call(
        .always_tail,
        tokenizeBlock,
        .{
            self,
            lines,
            value,
            block_style,
            chomp_style,
            indent_level,
            out_next_line,
        },
    );
}

/// The returned tokens are owned by this tokenizer's arena.
/// Keep in mind that freeing this tokenizer's arena will result in the tokens being freed as well.
pub fn deinit(self: Tokenizer) void {
    const arena_ptr: *ArenaAllocator = self.arena;
    const alloc: Allocator = self.parent_alloc;

    self.arena.deinit();
    alloc.destroy(arena_ptr);
}

// test cases needed:
// Block values with all the various block/chomp styles
test "tokenize literal block" {
    // testing.log_level = .debug;

    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: |
        \\  This is a block literal
        \\  yay
        \\  another line
        \\next_thing: wow
    ;

    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var line_iter: LineIterator = .{
        .@"test" = .{
            .allocator = arena.allocator(),
            .iter = .from(yaml),
        },
    };
    defer line_iter.deinit();

    const tokens: []Token = try tokenizer.tokenize(&line_iter);
    try testing.expectEqual(8, tokens.len);

    try dumpTokens(testing.allocator, tokens);

    try testing.expectEqualStrings("line", tokens[0].asString());
    try testing.expectEqualStrings(":", tokens[1].asString());
    // clip style with single newline at the end
    try testing.expectEqualStrings(
        \\This is a block literal
        \\yay
        \\another line
        \\
    , tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
