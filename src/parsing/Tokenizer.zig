const std = @import("std");
const zul = @import("zul");
const iter_z = @import("iter_z");
const root = @import("root.zig");
const Iter = iter_z.Iter;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ResetMode = ArenaAllocator.ResetMode;
const LineIterator = root.LineIterator;
const ArrayList = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;
const ParseConfig = root.ParseConfig;
const testing = std.testing;
const log = std.log.scoped(.tokenizer);
const assert = std.debug.assert;

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
    UnexpectedToken,
    InvalidEscapeSequence,
    ReadFileError,
    InvalidIndentation,
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

    /// Determine if a token is a specific syntax marker
    pub fn isSyntax(self: Token, syntax: SyntaxToken) bool {
        return switch (self) {
            .syntax => |syn| syn == syntax,
            else => false,
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
    if ((@import("builtin").is_test and testing.log_level != .debug) or !std.log.logEnabled(.debug, .tokenizer)) {
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

    std.debug.print("{s}\n", .{dump.items});
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
    /// Newlines are ommitted from the block and replaced with spaces (indicated by '>')
    folded,
    /// Newlines are included (indicated by '|')
    literal,
};

/// In multi-line value blocks, how are trailing newlines handled?
const ChompStyle = enum {
    /// single newline at the end (indicated without any character)
    clip,
    /// no newlines at the end (indicidated by '-')
    strip,
    /// all newlines are included at the end (indicated by '+')
    keep,
};

/// Which kind of quotes we're dealing with if the value is in quotes (this is relevant for escape sequences)
const QuoteType = enum { single, double };

fn isNonWhitespace(byte: u8) bool {
    return !std.ascii.isWhitespace(byte);
}

fn isValidKeyChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '$' or byte == '_';
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
        var moved: usize = 0;
        return self.inner.filterNext(isParsableToken, &moved);
    }

    /// Peek at the next token (excludes EOF and comments)
    pub fn peek(self: *TokenIterator) ?Token {
        return self.inner.any(isParsableToken);
    }

    /// Expect the next token to be a specific syntax symbol
    pub fn expectSyntax(self: *TokenIterator, syntax: SyntaxToken) error{ EOF, UnexpectedToken }!Token {
        if (self.peek()) |tok| {
            try tok.expectSyntax(syntax);
            _ = self.next();
            return tok;
        }
        return error.EOF;
    }

    /// Expect a specific indent level
    pub fn expectIndentLevel(self: *TokenIterator, indents: u16) error{ EOF, UnexpectedToken }!void {
        var i: u16 = 1;
        while (i < indents) : (i += 1) {
            _ = try self.expectSyntax(.indent);
            if (i == indents) {
                break;
            }
        }
    }

    /// Get the current indent level, consuming each tab token we encounter (assuming that we've consumed a newline token)
    pub fn getIndentLevel(self: *TokenIterator) u16 {
        var i: u16 = 0;
        while (self.peek()) |next_tok| {
            if (next_tok.isSyntax(.indent)) {
                _ = self.next();
                i += 1;
                continue;
            }
            break;
        }
        return i;
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
                switch (try self.tokenizeLine(&tokens, tokenize_next, &indent_level)) {
                    // Break and tokenize next line
                    .key_value_pair => break,
                    // append newline and keep parsing
                    .array_or_obj => {
                        try tokens.append(self.arena.allocator(), Token{ .syntax = .newline });
                        break;
                    },
                    // Parse block value (which is multi-line)
                    .block_value => |block_value| {
                        var out_next_line: ?[]const u8 = null;
                        var word: ArrayList(u8) = .empty;
                        try self.tokenizeBlock(
                            iter,
                            &word,
                            block_value.@"0",
                            block_value.@"1",
                            indent_level,
                            &out_next_line,
                            null,
                        );

                        // evaluate chomp style
                        switch (block_value.@"1") {
                            .clip => {
                                while (word.getLastOrNull() == '\n') {
                                    _ = word.pop();
                                }
                                try word.append(self.arena.allocator(), '\n');
                            },
                            .strip => {
                                while (word.getLastOrNull() == '\n') {
                                    _ = word.pop();
                                }
                            },
                            .keep => {
                                if (block_value.@"0" == .folded) {
                                    // kind of a naive solution, but if we encounter a bunch of trailing newlines in a folded block, they'd get replaced with n-1 spaces
                                    var i: usize = 0;
                                    while (word.getLastOrNull() == ' ') {
                                        _ = word.pop();
                                        i += 1;
                                    }
                                    for (0..i) |_| {
                                        try word.append(self.arena.allocator(), '\n');
                                    }
                                    try word.append(self.arena.allocator(), '\n');
                                }
                            },
                        }
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
                            continue;
                        }
                        break;
                    },
                }
                break;
            }
        }
    }
    try tokens.append(self.arena.allocator(), .eof);
    return try tokens.toOwnedSlice(self.arena.allocator());
}

fn tokenizeLine(
    self: *Tokenizer,
    tokens: *ArrayList(Token),
    line: []const u8,
    indent_level: *u16,
) Error!TokenizeLineResult {
    defer {
        // Advance line number and reset position to 0
        self.pos = 0;
        self.line_no += 1;
    }

    log.debug("From tokenizeLine()-->{s}", .{line});
    // tokenize the key first
    const lh_index: usize = try self.tokenizeKey(tokens, line, indent_level);
    // start reading the value
    log.debug("Finished reading key-->{s}\n    Now reading value-->{s}", .{ tokens.items[tokens.items.len - 2].asString(), line[lh_index..] });

    var iter: Iter(u8) = .from(line[lh_index..]);
    var moved: usize = 0;
    // consume whitespace after the ':'
    const next: ?u8 = iter.filterNext(isNonWhitespace, &moved);
    self.pos += moved;

    // this scenario means that we have a "key: \n" situation, which indicates this has to be an object or array
    if (next == null) {
        log.debug("Encountered early line termination. Determining this must be an array or object: Line {d}, pos {d}\n\t'{s}'", .{ self.line_no, self.pos, line });
        return .array_or_obj;
    }
    // is this a multi-line value block or just a single line value?
    switch (next.?) {
        '|' => {
            const block_tok: ?u8 = iter.filterNext(isNonWhitespace, &moved);
            log.debug("Encountered block value indicator '|', following by chomp style ({?c})", .{block_tok});
            try dumpTokens(self.arena.allocator(), tokens.items);
            indent_level.* += 1;
            if (block_tok) |tok| {
                return switch (tok) {
                    '+' => .{ .block_value = .{ BlockStyle.literal, ChompStyle.keep } },
                    '-' => .{ .block_value = .{ BlockStyle.literal, ChompStyle.strip } },
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
            return .{ .block_value = .{ BlockStyle.literal, ChompStyle.clip } };
        },
        '>' => {
            const block_tok: ?u8 = iter.filterNext(isNonWhitespace, &moved);
            log.debug("Encountered block value indicator '>', following by chomp style ({?c})", .{block_tok});
            try dumpTokens(self.arena.allocator(), tokens.items);
            indent_level.* += 1;
            if (block_tok) |tok| {
                return switch (tok) {
                    '+' => .{ .block_value = .{ BlockStyle.folded, ChompStyle.keep } },
                    '-' => .{ .block_value = .{ BlockStyle.folded, ChompStyle.strip } },
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
            return .{ .block_value = .{ BlockStyle.folded, ChompStyle.clip } };
        },
        // parse normally
        else => iter.scroll(-1),
    }

    log.debug("Not a block value-->{s}", .{line});
    // get the rest of the line
    var word: ArrayList(u8) = try .initCapacity(self.arena.allocator(), line.len);
    var first: bool = true;
    var quote_type: ?QuoteType = null;
    var start_escape: bool = false;
    while (iter.next()) |byte| {
        defer self.pos += 1;

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

        if (byte == ':' and quote_type == null and tokens.getLast().isSyntax(.dash)) {
            // could be an array of objects
            log.debug("Determined this array is an array of objects, line {d}, pos {d}", .{ self.line_no, self.pos });
            try dumpTokens(self.arena.allocator(), tokens.items);
            try tokens.append(self.arena.allocator(), Token{ .string = try word.toOwnedSlice(self.arena.allocator()) });
            try tokens.append(self.arena.allocator(), Token{ .syntax = .colon });
            try dumpTokens(self.arena.allocator(), tokens.items);

            word = try .initCapacity(self.arena.allocator(), line.len);

            moved = 0;
            if (iter.filterNext(isNonWhitespace, &moved)) |n| {
                word.append(self.arena.allocator(), n) catch unreachable;
            }
            self.pos += moved;

            first = true;
            continue;
        }

        word.append(self.arena.allocator(), byte) catch unreachable;
    }

    if (quote_type) |q| {
        var last_char: u8 = word.getLast();
        if (last_char == '\n') {
            last_char = word.items[word.items.len - 1];
        }
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
    const parsed: []const u8 = try word.toOwnedSlice(self.arena.allocator());
    if (parsed[parsed.len - 1] == '\n') {
        // Strip off newline and tokenize it instead.
        // If you truly want any newlines, then you need N+1 newlines.
        // Yes, we waste a byte, but that's what the arena is for.
        try tokens.append(self.arena.allocator(), Token{ .string = parsed[0 .. parsed.len - 1] });
        try tokens.append(self.arena.allocator(), Token{ .syntax = .newline });
    } else {
        try tokens.append(self.arena.allocator(), Token{ .string = parsed });
    }

    return .key_value_pair;
}

/// Tokenize key and return the offset after the `:`
fn tokenizeKey(
    self: *Tokenizer,
    tokens: *ArrayList(Token),
    line: []const u8,
    indent_level: *u16,
) Error!usize {
    var spaces: u8 = 0;
    var word: ArrayList(u8) = try .initCapacity(self.arena.allocator(), line.len);
    errdefer word.deinit(self.arena.allocator());

    var lh_index: usize = 0;
    var indents_encountered: u16 = 0;
    defer indent_level.* = indents_encountered;
    for (line) |byte| {
        defer {
            lh_index += 1;
            self.pos += 1;
        }
        switch (byte) {
            ' ' => {
                spaces += 1;
                if (spaces == self.config.tab_size) {
                    indents_encountered += 1;
                    spaces = 0;
                }
            },
            '\t' => indents_encountered += 1,
            ':' => {
                // append indents, key, and colon
                try dumpTokens(self.arena.allocator(), tokens.items);
                log.debug("Appending {d} indents", .{indents_encountered});
                for (0..indents_encountered) |_| {
                    try tokens.append(self.arena.allocator(), Token{ .syntax = .indent });
                }
                const word_slice: []const u8 = try word.toOwnedSlice(self.arena.allocator());
                log.debug("Appending key '{s}' and colon character.", .{word_slice});
                try tokens.append(self.arena.allocator(), Token{ .string = word_slice });
                try tokens.append(self.arena.allocator(), Token{ .syntax = .colon });
                try dumpTokens(self.arena.allocator(), tokens.items);
                break;
            },
            '-' => {
                // append indents and dash
                for (0..indents_encountered) |_| {
                    try tokens.append(self.arena.allocator(), Token{ .syntax = .indent });
                }
                try tokens.append(self.arena.allocator(), Token{ .syntax = .dash });
                break;
            },
            else => {
                if (!isValidKeyChar(byte)) {
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

    if (spaces > 0) {
        log.err("Expecting consistent indentation but found indentation that does not match the configured tabsize, line {d}: {s}", .{ self.line_no, line });
        return error.InvalidIndentation;
    }

    return lh_index;
}

/// Tokenize block values
/// For reference: https://yaml-multiline.info/
fn tokenizeBlock(
    self: *Tokenizer,
    lines: *LineIterator,
    value: *ArrayList(u8),
    block_style: BlockStyle,
    chomp_style: ChompStyle,
    indent_level: u16,
    out_next_line: *?[]const u8,
    previous: ?BlockSegment,
) Error!void {
    defer {
        self.line_no += 1;
        self.pos = 0;
    }

    var len: usize = 0;
    var prev_cpy: ?BlockSegment = previous;
    if (block_style == .folded and previous != null) {
        // Before we even do anything, if we're a folded-style block that encountered a double-newline, we'll append a newline at the beginning.
        // Otherwise, we append a space since newlines are all turned into spaces.
        if (prev_cpy.?.folded_newline) {
            try value.append(self.arena.allocator(), '\n');
        } else {
            try value.append(self.arena.allocator(), ' ');
        }
        // rather than add the length, we'll simply append this to the length of the last line since technically represents the previous chunk
        prev_cpy.?.len += 1;
    }

    // start parsing next line...
    const next_line: []const u8 = lines.next() catch |err| {
        log.err("Failed to read next line: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
        return error.ReadFileError;
    } orelse return;
    log.debug("From tokenizeBlock()-->{s}", .{next_line});
    var next_line_iter: Iter(u8) = .from(next_line);
    var indent_count: u16 = 0;
    var space_count: u16 = 0;
    while (next_line_iter.next()) |byte| {
        defer self.pos += 1;
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
        if (block_style == .folded and value.getLastOrNull() == ' ') {
            // pop off trailing space that's an artifact of this tokenization strategy
            _ = value.pop();
        }
        log.debug("Encountered next line while parsing block. Block is complete. New line-->{s}", .{next_line});
        out_next_line.* = next_line;
        return;
    }

    var should_esc_newline: bool = false;
    switch (block_style) {
        .folded => {
            while (next_line_iter.next()) |byte| {
                defer self.pos += 1;
                assert(should_esc_newline != true);

                switch (byte) {
                    '\n' => {},
                    '\t' => log.debug("    Appending '\\t' to block", .{}),
                    else => log.debug("    Appending '{c}' to block", .{byte})
                }
                if (byte != '\n') {
                    try value.append(self.arena.allocator(), byte);
                    len += 1;
                } else {
                    // Lines with extra indentation do not get their newlines folded.
                    if (prev_cpy) |p| {
                        if (p.segment(value.items).len > 0 and p.segment(value.items)[0] == '\t') {
                            try value.append(self.arena.allocator(), byte);
                            len += 1;
                        }
                    } else if (next_line.len == 1) {
                        // this scenario indicates this line is simply a newline character, which we interpret as a quasi escape sequence for newlines
                        should_esc_newline = true;
                    }
                }
            }
        },
        .literal => {
            while (next_line_iter.next()) |byte| {
                defer {
                    self.pos += 1;
                    len += 1;
                }
                switch (byte) {
                    '\n' => log.debug("    Appending '\\n' to block", .{}),
                    '\t' => log.debug("    Appending '\\t' to block", .{}),
                    else => log.debug("    Appending '{c}' to block", .{byte})
                }
                try value.append(self.arena.allocator(), byte);
            }
        },
    }

    return @call(
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
            BlockSegment{
                .len = len,
                .offset = if (prev_cpy) |p| p.len + p.offset else 0,
                .folded_newline = should_esc_newline,
            },
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

/// Instead of de-initializing everything, can reset the backing arena
pub fn reset(self: *Tokenizer, reset_mode: ResetMode) void {
    _ = self.arena.reset(reset_mode);
}

const TokenizeLineResult = union(enum) {
    /// Normal case: key-value pair
    key_value_pair,
    /// Value is a block
    block_value: struct { BlockStyle, ChompStyle },
    /// If we have a key, followed by a newline, then we've got an array or objection situation
    array_or_obj,
};

const BlockSegment = struct {
    offset: usize,
    len: usize,
    folded_newline: bool,

    fn segment(self: BlockSegment, slice: []const u8) []const u8 {
        log.debug("Value to segment (offset: {d}, len: {d}): {s}", .{ self.offset, self.len, slice });
        if (self.len == 0 or slice.len <= self.offset + self.len) {
            return &[_]u8{};
        }
        const ret: []const u8 = slice[self.offset .. self.offset + self.len];
        log.debug("    Returning segment-->{s}<--", .{ret});
        return ret;
    }
};

// test cases needed:
// Block values with all the various block/chomp styles
test "tokenize literal block, clip style" {
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
    try testing.expectEqualStrings("This is a block literal\nyay\nanother line\n", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize literal block, strip style" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: |-
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
    // strip style with no newline at the end
    try testing.expectEqualStrings("This is a block literal\nyay\nanother line", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize literal block, keep style" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: |+
        \\  This is a block literal
        \\  yay
        \\  another line
        \\  
        \\  
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
    // keep style with all newlines intact (this is looks funky as a multi-string literal, so I'm just ensuring there are 3 newlines as expected)
    try testing.expectEqualStrings("This is a block literal\nyay\nanother line\n\n\n", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize folded block, clip style" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: >
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
    try testing.expectEqualStrings("This is a block literal yay another line\n", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize folded block, strip style" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: >-
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
    // strip style with no newline at the end
    try testing.expectEqualStrings("This is a block literal yay another line", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize folded block, keep style" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: >+
        \\  This is a block literal
        \\  yay
        \\  another line
        \\  
        \\  
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
    // allowed to keep all newlines at the end
    try testing.expectEqualStrings("This is a block literal yay another line\n\n\n", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("next_thing", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("wow", tokens[6].asString());
    try testing.expectEqualStrings("<EOF>", tokens[7].asString());
}
test "tokenize array" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: this is a value
        \\arr:
        \\  - value1
        \\  - value2
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
    try testing.expectEqual(15, tokens.len);

    try dumpTokens(testing.allocator, tokens);

    try testing.expectEqualStrings("line", tokens[0].asString());
    try testing.expectEqualStrings(":", tokens[1].asString());
    try testing.expectEqualStrings("this is a value", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("arr", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("\\n", tokens[6].asString());
    try testing.expectEqualStrings("\\t", tokens[7].asString());
    try testing.expectEqualStrings("-", tokens[8].asString());
    try testing.expectEqualStrings("value1", tokens[9].asString());
    try testing.expectEqualStrings("\\n", tokens[10].asString());
    try testing.expectEqualStrings("\\t", tokens[11].asString());
    try testing.expectEqualStrings("-", tokens[12].asString());
    try testing.expectEqualStrings("value2", tokens[13].asString());
    try testing.expectEqualStrings("<EOF>", tokens[14].asString());
}
test "tokenize obj" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: this is a value
        \\obj:
        \\  prop: value1
        \\  other_prop: value2
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
    try testing.expectEqual(17, tokens.len);

    try dumpTokens(testing.allocator, tokens);

    try testing.expectEqualStrings("line", tokens[0].asString());
    try testing.expectEqualStrings(":", tokens[1].asString());
    try testing.expectEqualStrings("this is a value", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("obj", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("\\n", tokens[6].asString());
    try testing.expectEqualStrings("\\t", tokens[7].asString());
    try testing.expectEqualStrings("prop", tokens[8].asString());
    try testing.expectEqualStrings(":", tokens[9].asString());
    try testing.expectEqualStrings("value1", tokens[10].asString());
    try testing.expectEqualStrings("\\n", tokens[11].asString());
    try testing.expectEqualStrings("\\t", tokens[12].asString());
    try testing.expectEqualStrings("other_prop", tokens[13].asString());
    try testing.expectEqualStrings(":", tokens[14].asString());
    try testing.expectEqualStrings("value2", tokens[15].asString());
    try testing.expectEqualStrings("<EOF>", tokens[16].asString());
}
test "tokenize list of objects" {
    var tokenizer: Tokenizer = try .new(testing.allocator, .{});
    defer tokenizer.deinit();

    const yaml =
        \\line: this is a value
        \\list:
        \\  - prop: value1
        \\    other_prop: value2
        \\  - prop: value3
        \\    other_prop: value4
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
    testing.expectEqual(31, tokens.len) catch |err| {
        testing.log_level = .debug;
        try dumpTokens(testing.allocator, tokens);
        return err;
    };

    try dumpTokens(testing.allocator, tokens);

    try testing.expectEqualStrings("line", tokens[0].asString());
    try testing.expectEqualStrings(":", tokens[1].asString());
    try testing.expectEqualStrings("this is a value", tokens[2].asString());
    try testing.expectEqualStrings("\\n", tokens[3].asString());
    try testing.expectEqualStrings("list", tokens[4].asString());
    try testing.expectEqualStrings(":", tokens[5].asString());
    try testing.expectEqualStrings("\\n", tokens[6].asString());
    try testing.expectEqualStrings("\\t", tokens[7].asString());
    try testing.expectEqualStrings("-", tokens[8].asString());
    try testing.expectEqualStrings("prop", tokens[9].asString());
    try testing.expectEqualStrings(":", tokens[10].asString());
    try testing.expectEqualStrings("value1", tokens[11].asString());
    try testing.expectEqualStrings("\\n", tokens[12].asString());
    try testing.expectEqualStrings("\\t", tokens[13].asString());
    try testing.expectEqualStrings("\\t", tokens[14].asString());
    try testing.expectEqualStrings("other_prop", tokens[15].asString());
    try testing.expectEqualStrings(":", tokens[16].asString());
    try testing.expectEqualStrings("value2", tokens[17].asString());
    try testing.expectEqualStrings("\\n", tokens[18].asString());
    try testing.expectEqualStrings("\\t", tokens[19].asString());
    try testing.expectEqualStrings("-", tokens[20].asString());
    try testing.expectEqualStrings("prop", tokens[21].asString());
    try testing.expectEqualStrings(":", tokens[22].asString());
    try testing.expectEqualStrings("value3", tokens[23].asString());
    try testing.expectEqualStrings("\\n", tokens[24].asString());
    try testing.expectEqualStrings("\\t", tokens[25].asString());
    try testing.expectEqualStrings("\\t", tokens[26].asString());
    try testing.expectEqualStrings("other_prop", tokens[27].asString());
    try testing.expectEqualStrings(":", tokens[28].asString());
    try testing.expectEqualStrings("value4", tokens[29].asString());
    try testing.expectEqualStrings("<EOF>", tokens[30].asString());
}
