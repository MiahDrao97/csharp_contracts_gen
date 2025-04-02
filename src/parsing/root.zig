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
pub fn parseYaml(allocator: Allocator, file_path: []const u8, config: ParseConfig) Error!Parsed {
    if (!mem.endsWith(u8, ".yml", file_path) or !mem.endsWith(u8, ".yaml", file_path)) {
        return error.InvalidFileExtension;
    }

    var tokenizer: Tokenizer = try .new(allocator, config);
    defer tokenizer.deinit(); // this deinit() call will destroy the resulting tokens as well

    var out_buf: [4096]u8 = undefined;
    var line_iter: LineIterator = .{
        .live = zul.fs.readLines(file_path, &out_buf, .{}) catch |err| {
            std.log.err("Encountered error {s} while reading lines from file {s} -> {?}", .{
                @errorName(err),
                file_path,
                @errorReturnTrace(),
            });
            return error.ReadFileError;
        },
    };
    defer line_iter.deinit();

    const tokens: []Token = try tokenizer.tokenize(&line_iter); // destroyed with the tokenizer
    var parser: Parser = .init;
    return try parser.parse(allocator, tokens);
}

/// Represents a parsed schema-less YAML file
pub const Parsed = struct {
    root: NodeMap,
    arena: *ArenaAllocator,
    parent_alloc: Allocator,

    /// Initialize new `Parsed` structure with a new arena.
    pub fn new(allocator: Allocator) Allocator.Error!Parsed {
        const arena: *ArenaAllocator = try allocator.create(ArenaAllocator);
        arena.* = .init(allocator);

        return Parsed{
            // root node is always an object
            .root = .empty,
            .arena = arena,
            .parent_alloc = allocator,
        };
    }

    /// Free associated memory
    pub fn deinit(self: Parsed) void {
        const arena_ptr: *ArenaAllocator = self.arena;
        const alloc: Allocator = self.parent_alloc;

        self.arena.deinit();
        alloc.destroy(arena_ptr);
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

        pub const Context = struct {
            pub fn hash(_: Context, k: StringHash) u32 {
                // this already repesents a hash, so just return the u32 value
                return @intFromEnum(k);
            }

            pub fn eql(_: Context, a: StringHash, b: StringHash, _: usize) bool {
                return a == b;
            }
        };

        pub fn from(k: []const u8) StringHash {
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

        self.value_map.put(
            allocator,
            StringHash.from(k),
            Value{ .node = v, .offset = next_idx },
        ) catch |err| switch (err) {
            Allocator.Error.OutOfMemory => |oom| return oom,
            else => unreachable,
        };
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
