const std = @import("std");
const zul = @import("zul");
const iter_z = @import("iter_z");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;
const ArrayHashMap = std.ArrayHashMapUnmanaged;
const Iter = iter_z.Iter;
const panic = std.debug.panicExtra;
const log = std.log.scoped(.parsing_root);

pub const Tokenizer = @import("Tokenizer.zig");
pub const Parser = @import("Parser.zig");
pub const Token = Tokenizer.Token;

pub const Error = error{ InvalidFileExtension, ReadFileError } || Tokenizer.Error || Parser.Error;

/// Configuration on parsing
pub const ParseConfig = struct {
    max_depth: usize = 1000,
    tab_size: u4 = 2,
};

/// Open a YAML file, parse it, and return `Parsed`
pub fn parseYaml(allocator: Allocator, file_path: []const u8, config: ParseConfig) Error!ParsedYml {
    if (!(mem.endsWith(u8, file_path, ".yml") or mem.endsWith(u8, file_path, ".yaml"))) {
        log.err("Cannot open non-YAML file '{s}'", .{file_path});
        return error.InvalidFileExtension;
    }

    var tokenizer: Tokenizer = .init(allocator, config);
    defer tokenizer.deinit(); // this deinit() call will destroy the resulting tokens as well

    var out_buf: [4096]u8 = undefined;
    var line_iter: LineIterator = .init(
        zul.fs.readLines(file_path, &out_buf, .{}) catch |err| {
            log.err("Encountered error {s} while reading lines from file {s} -> {?}", .{
                @errorName(err),
                file_path,
                @errorReturnTrace(),
            });
            return error.ReadFileError;
        },
    );
    defer line_iter.deinit();

    const tokens: []Token = try tokenizer.tokenize(&line_iter); // destroyed with the tokenizer
    var parser: Parser = .init;
    return try parser.parse(allocator, tokens);
}

/// Represents a parsed schema-less YAML file
pub const ParsedYml = struct {
    // root node is always an object
    root: NodeMap,
    arena: ArenaAllocator,

    /// Initialize new `Parsed` structure with a new arena.
    pub fn init(allocator: Allocator) ParsedYml {
        return .{
            .root = .empty,
            .arena = ArenaAllocator.init(allocator),
        };
    }

    /// Free associated memory
    pub fn deinit(self: *ParsedYml) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A representation of a YAML node
pub const Node = union(enum) {
    /// This node is an array of nodes
    arr: []const Node,
    /// This node is an "object", containing other nodes
    obj: NodeMap,
    /// This node is a simple key-value structure
    value: []const u8,

    /// If this is an object, get the node at `key`.
    /// NOTE : If this is an array, we accept numeric keys (e.g. "0") and attempt to get by index
    pub fn tryGet(self: *const Node, key: []const u8) ?Node {
        switch (self.*) {
            .obj => |o| return o.get(key),
            .arr => {
                if (std.fmt.parseInt(usize, key, 10)) |idx| {
                    return self.tryGetAtIdx(idx);
                } else |_| return null;
            },
            .value => return null,
        }
    }

    /// If this is an array, get the node at index `idx`.
    /// Otherwise, if this an object, get the nth node from the object's nodes
    pub fn tryGetAtIdx(self: *const Node, idx: usize) ?Node {
        switch (self.*) {
            .arr => |a| {
                if (idx >= a.len) {
                    return null;
                }
                return a[idx];
            },
            .obj => |*o| {
                var iter: NodeMap.Iterator = o.iter();
                if (idx >= iter.len()) {
                    return null;
                }
                var i: usize = 0;
                while (iter.next()) |x| {
                    if (i == idx) {
                        return x.@"1";
                    }
                    i += 1;
                }
                return null;
            },
            .value => return null,
        }
    }

    /// If this is a simple key-value node, then get the value
    pub fn asValue(self: Node) ?[]const u8 {
        return switch (self) {
            .value => |v| v,
            else => null,
        };
    }

    /// If this is an object node, then return the corresponding `NodeMap`
    pub fn asObjPtr(self: *Node) ?*NodeMap {
        return switch (self.*) {
            .obj => |*o| o,
            else => null,
        };
    }

    /// Convert a node to either a string, structure, or slice/array
    /// Note that strings and arrays are duplicated and will need to be freed.
    pub fn projectTo(self: Node, comptime T: type, allocator: Allocator) Allocator.Error!?T {
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                switch (self) {
                    .obj => |o| return try o.projectTo(T, allocator),
                    .arr => |a| {
                        if (struct_info.is_tuple) {
                            var x: T = undefined;
                            inline for (struct_info.fields, 0..) |field, i| {
                                if (i >= a.len) {
                                    break;
                                }
                                @field(x, field.name) = switch (@typeInfo(field.type)) {
                                    .optional => try a[i].projectTo(field.type, allocator),
                                    else => (try a[i].projectTo(field.type, allocator)).?,
                                };
                            }
                            return x;
                        }
                        return null;
                    },
                    else => return null,
                }
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .slice => {
                        switch (self) {
                            .value => |v| {
                                if (ptr.child == u8) {
                                    return try allocator.dupe(u8, v);
                                } else return null;
                            },
                            .arr => |a| {
                                const ElemType = ptr.child;
                                const slice: []ElemType = try allocator.alloc(ElemType, a.len);
                                errdefer allocator.free(slice);
                                for (a, 0..) |node, i| {
                                    slice[i] = switch (@typeInfo(ElemType)) {
                                        .optional => try node.projectTo(ElemType, allocator),
                                        else => (try node.projectTo(ElemType, allocator)).?,
                                    };
                                }
                                return slice;
                            },
                            else => return null,
                        }
                    },
                    .many => {
                        switch (self) {
                            .value => |v| {
                                return if (ptr.child == u8)
                                    (try allocator.dupe(u8, v)).ptr
                                else
                                    null;
                            },
                            .arr => |a| {
                                const ElemType = ptr.child;
                                const slice: []ElemType = try allocator.alloc(ElemType, a.len);
                                errdefer allocator.free(slice);
                                for (a, 0..) |node, i| {
                                    slice[i] = switch (@typeInfo(ElemType)) {
                                        .optional => try node.projectTo(ElemType, allocator),
                                        else => (try node.projectTo(ElemType, allocator)).?,
                                    };
                                }
                                return slice.ptr;
                            },
                            else => return null,
                        }
                    },
                    else => return null,
                }
            },
            .array => |array_info| {
                switch (self) {
                    .arr => |a| {
                        if (a.len != array_info.len) {
                            return null;
                        }

                        const ElemType = array_info.child;
                        var arr: [array_info.len]ElemType = @splat(undefined);
                        for (a, 0..) |node, i| {
                            arr[i] = switch (@typeInfo(ElemType)) {
                                .optional => try node.projectTo(ElemType, allocator),
                                else => (try node.projectTo(ElemType, allocator)).?,
                            };
                        }
                        return arr;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }
};

/// Custom structure that represents an "object", where each member is a string key and a node value
pub const NodeMap = struct {
    /// Literally all keys smooshed into a single dynamic byte array, separated by null characters.
    keys_packed: ArrayList(u8),
    /// Map of values, where the key is a u32 hash of the string-valued key to avoid allocations on copying the keys.
    /// Using CityHash32 as the hashing algo.
    value_map: HashMap,

    const Value = struct {
        /// The actual node that we care about
        node: Node,
        /// The offset in `keys_packed` that the key is stored (up to the next null byte)
        offset: u32,
    };

    /// Just a u32 alias that represents a hash created from a string
    const StringHash = enum(u32) {
        _,

        const Context = struct {
            pub fn hash(_: Context, k: StringHash) u32 {
                // this already repesents a hash, so just return the u32 value
                return @intFromEnum(k);
            }

            pub fn eql(_: Context, a: StringHash, b: StringHash, _: usize) bool {
                return a == b;
            }
        };

        fn from(k: []const u8) StringHash {
            return @enumFromInt(std.hash.CityHash32.hash(k));
        }
    };

    const HashMap = ArrayHashMap(StringHash, Value, StringHash.Context, false);

    /// Iterator over the key-value pairs of the `NodeMap`
    pub const Iterator = struct {
        inner: HashMap.Iterator,
        map: NodeMap,

        /// Get next key-value pair or null if at the end of the collection
        pub fn next(self: *Iterator) ?struct { []const u8, *Node } {
            const next_node_primitive: ?HashMap.Entry = self.inner.next();
            if (next_node_primitive) |n| {
                const key: []const u8 = mem.sliceTo(self.map.keys_packed.items[n.value_ptr.offset..], 0);
                return .{ key, &n.value_ptr.node };
            }
            return null;
        }

        /// Get the length of the iterator
        pub fn len(self: Iterator) u32 {
            return self.inner.len;
        }
    };

    /// Simply an alias for `std.mem.SplitIterator(u8, .scalar)`.
    /// The keys are essentially a `splitScalar()` call on our packed array-list of keys
    pub const KeyIterator = std.mem.SplitIterator(u8, .scalar);

    pub const empty: NodeMap = .{
        .keys_packed = .empty,
        .value_map = .empty,
    };

    /// Put a new node (overwrites previous entry if a collision occurs).
    /// Returns `error.InvalidKey` if the key contains any null characters.
    pub fn put(self: *NodeMap, allocator: Allocator, k: []const u8, v: Node) (error{InvalidKey} || Allocator.Error)!void {
        for (k) |byte| {
            if (byte == 0) {
                return error.InvalidKey;
            }
        }

        var next_idx: u32 = @intCast(self.keys_packed.items.len);
        if (next_idx > 0) {
            // insert our separator beforehand if we're not the first key
            try self.keys_packed.append(allocator, 0);
            next_idx += 1;
        }
        try self.keys_packed.appendSlice(allocator, k);

        try self.value_map.put(
            allocator,
            StringHash.from(k),
            Value{ .node = v, .offset = next_idx },
        );
    }

    /// Get a node by its key, if it exists
    pub fn get(self: NodeMap, k: []const u8) ?Node {
        if (self.value_map.get(StringHash.from(k))) |value| {
            return value.node;
        }
        return null;
    }

    /// Get an iterator for all key-value pairs in this map
    pub fn iter(self: *const NodeMap) Iterator {
        return .{ .inner = self.value_map.iterator(), .map = self.* };
    }

    /// Iterator over all the keys in our map
    pub fn keys(self: *const NodeMap) KeyIterator {
        return std.mem.splitScalar(u8, self.keys_packed.items, 0);
    }

    /// Convert to a structure
    /// Note that string and array fields are duplicated and will need to be freed.
    pub fn projectTo(self: NodeMap, comptime T: type, allocator: Allocator) Allocator.Error!?T {
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                var x: T = undefined;
                inline for (struct_info.fields) |field| {
                    const FieldType = field.type;
                    if (self.get(mem.sliceTo(field.name, 0))) |val| {
                        switch (val) {
                            .obj => |o| {
                                @field(x, field.name) = switch (@typeInfo(FieldType)) {
                                    .optional => try o.projectTo(FieldType, allocator),
                                    else => (try o.projectTo(FieldType, allocator)).?,
                                };
                            },
                            .value => |v| {
                                switch (@typeInfo(FieldType)) {
                                    .pointer => |p| {
                                        if (p.child != u8) {
                                            return null;
                                        }
                                        switch (p.size) {
                                            .slice => {},
                                            else => return null,
                                        }
                                    },
                                    else => return null,
                                }
                                @field(x, field.name) = try allocator.dupe(u8, v);
                            },
                            .arr => |a| {
                                switch (@typeInfo(FieldType)) {
                                    .pointer => |p| {
                                        switch (p.size) {
                                            .slice => {},
                                            else => return null,
                                        }
                                        const ElementType = p.child;
                                        const slice: []ElementType = try allocator.alloc(ElementType, a.len);
                                        errdefer allocator.free(slice);
                                        for (a, 0..) |node, i| {
                                            slice[i] = switch (@typeInfo(ElementType)) {
                                                .optional => try node.projectTo(ElementType, allocator),
                                                else => (try node.projectTo(ElementType, allocator)).?,
                                            };
                                        }
                                        @field(x, field.name) = slice;
                                    },
                                    else => return null,
                                }
                            }
                        }
                    } else {
                        switch (@typeInfo(field.type)) {
                            .optional => {
                                // skip optional fields if we don't have a match
                            },
                            else => return null,
                        }
                    }
                }
                return x;
            },
            else => return null,
        }
    }

    pub fn dumpNodeMap(obj: *const NodeMap) void {
        if ((@import("builtin").is_test and testing.log_level != .debug) or !std.log.logEnabled(.debug, .parser)) {
            return;
        }

        var buf: [8192]u8 = undefined;
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
                    .obj => |*o| try innerDump(allocator, o, level + 1),
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

    /// Free memory owned by this map
    pub fn deinit(self: *NodeMap, allocator: Allocator) void {
        self.keys_packed.deinit(allocator);
        self.value_map.deinit(allocator);
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
test "NodeMap" {
    var map: NodeMap = .empty;
    defer map.deinit(testing.allocator);

    var iter: NodeMap.Iterator = map.iter();
    try testing.expectEqual(null, iter.next());

    try map.put(testing.allocator, "key", Node{ .value = "value" });
    try testing.expectEqualStrings("value", map.get("key").?.value);

    iter = map.iter();
    const kvp: ?struct { []const u8, *Node } = iter.next();
    try testing.expect(kvp != null);
    try testing.expectEqualStrings("key", kvp.?.@"0");
    try testing.expectEqualStrings("value", kvp.?.@"1".value);
    try testing.expectEqual(null, iter.next());

    const X = struct {
        key: []const u8,
    };
    const x: ?X = try map.projectTo(X, testing.allocator);
    try testing.expect(x != null);
    defer testing.allocator.free(x.?.key);
    try testing.expectEqualStrings("value", x.?.key);
}
test "Node projectTo()" {
    var obj: NodeMap = .empty;
    defer obj.deinit(testing.allocator);

    try obj.put(testing.allocator, "static_value", Node{ .value = "value" });
    try obj.put(testing.allocator, "arr", Node{
        .arr = &[_]Node{
            .{ .value = "val_0" },
            .{ .value = "val_1" },
            .{ .value = "val_2" },
        },
    });

    var nested: NodeMap = .empty;
    defer nested.deinit(testing.allocator);

    try nested.put(testing.allocator, "nested_value", Node{ .value = "nested" });
    try obj.put(testing.allocator, "nested_object", Node{ .obj = nested });

    const Schema = struct {
        static_value: []const u8,
        arr: []const []const u8,
        nested_object: struct {
            nested_value: []const u8,
        },
    };
    const x: ?Schema = try obj.projectTo(Schema, testing.allocator);
    try testing.expect(x != null);
    defer {
        testing.allocator.free(x.?.static_value);
        for (x.?.arr) |word| {
            testing.allocator.free(word);
        }
        testing.allocator.free(x.?.arr);
        testing.allocator.free(x.?.nested_object.nested_value);
    }

    try testing.expectEqualStrings("value", x.?.static_value);
    var buf: [8]u8 = undefined;
    for (0..3) |i| {
        try testing.expectEqualStrings(
            std.fmt.bufPrint(&buf, "val_{d}", .{i}) catch unreachable,
            x.?.arr[i],
        );
    }
    try testing.expectEqualStrings("nested", x.?.nested_object.nested_value);

    // check iterator
    var iter: NodeMap.Iterator = obj.iter();
    var next: ?struct { []const u8, *Node } = null;

    next = iter.next();
    try testing.expectEqualStrings("static_value", next.?.@"0");
    try testing.expectEqualStrings("value", next.?.@"1".value);

    next = iter.next();
    try testing.expectEqualStrings("arr", next.?.@"0");

    next = iter.next();
    try testing.expectEqualStrings("nested_object", next.?.@"0");

    next = iter.next();
    try testing.expectEqual(null, next);

    // check keys()
    var key_iter: NodeMap.KeyIterator = obj.keys();
    try testing.expectEqualStrings("static_value", key_iter.next().?);
    try testing.expectEqualStrings("arr", key_iter.next().?);
    try testing.expectEqualStrings("nested_object", key_iter.next().?);
    try testing.expectEqual(null, key_iter.next());
}

pub const LineIterator = union(enum) {
    live: zul.fs.LineIterator,
    @"test": struct { allocator: Allocator, iter: Iter(u8) },

    pub fn init(iter: zul.fs.LineIterator) LineIterator {
        return .{ .live = iter };
    }

    pub fn initTest(allocator: Allocator, iter: Iter(u8)) LineIterator {
        return .{
            .@"test" = .{ .allocator = allocator, .iter = iter },
        };
    }

    pub fn deinit(self: *LineIterator) void {
        switch (self.*) {
            .live => |l| l.deinit(),
            .@"test" => |*t| t.iter.deinit(),
        }
    }

    pub fn next(self: *LineIterator) !?[]const u8 {
        switch (self.*) {
            .live => |*l| return l.next(),
            .@"test" => |*t| {
                var line: ArrayList(u8) = .empty;
                errdefer line.deinit(t.allocator);

                while (t.iter.next()) |n| {
                    try line.append(t.allocator, n);
                    if (n == '\n') {
                        break;
                    }
                }

                if (line.items.len == 0) {
                    return null;
                }
                return try line.toOwnedSlice(t.allocator);
            }
        }
    }
};

test "parse with live file" {
    return error.SkipZigTest;
    // testing.log_level = .debug;
    // const file: []const u8 = "./fixtures/test.yaml";
    // var parsed: ParsedYml = try parseYaml(testing.allocator, file, .{});
    // defer parsed.deinit();

    // testing.log_level = .info;
}
