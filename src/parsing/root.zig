const std = @import("std");
const zul = @import("zul");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const LineIterator = zul.fs.LineIterator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.StringArrayHashMap;
const AutoArrayHashMap = std.AutoArrayHashMap;
const panic = std.debug.panicExtra;

pub const Tokenizer = @import("Tokenizer.zig");
pub const parser = @import("parser.zig");
pub const Token = Tokenizer.Token;

pub const Error = error{ InvalidFileExtension, ReadFileError } || Tokenizer.Error || parser.Error;

/// Configuration on parsing
pub const ParseConfig = struct {
    max_depth: usize = 1000,
    tab_size: u8 = 2,
};

/// Open a YAML file, parse it, and return `Parsed`
pub fn parseYaml(allocator: Allocator, file_path: []const u8, config: ParseConfig) Error!Parsed {
    if (!mem.endsWith(u8, ".yml", file_path) or !mem.endsWith(u8, ".yaml", file_path)) {
        return error.InvalidFileExtension;
    }

    var tokenizer: Tokenizer = try .new(allocator, config);
    defer tokenizer.deinit(); // this deinit() call will destroy the resulting tokens as well

    var out_buf: [4096]u8 = undefined;
    var line_iter: LineIterator = zul.fs.readLines(file_path, &out_buf, .{}) catch |err| {
        std.log.err("Encountered error {s} while reading lines from file {s} -> {?}", .{
            @errorName(err),
            file_path,
            @errorReturnTrace(),
        });
        return error.ReadFileError;
    };
    defer line_iter.deinit();

    const tokens: []Token = try tokenizer.tokenize(&line_iter); // destroyed with the tokenizer
    return try parser.parse(allocator, tokens);
}

/// Represents a parsed schema-less YAML file
pub const Parsed = struct {
    root: Node,
    arena: *ArenaAllocator,
    parent_alloc: Allocator,

    /// Initialize new `Parsed` structure with a new arena.
    pub fn new(allocator: Allocator) Allocator.Error!Parsed {
        const arena: *ArenaAllocator = try allocator.create(ArenaAllocator);
        arena.* = .init(allocator);

        return Parsed{
            // root node is always an object
            .root = Node{ .obj = NodeMap.init(arena.allocator()) },
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
    pub fn asObj(self: *Node) ?*NodeMap {
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
                                @compileLog("Value node type >> Slice type '" ++ @typeName(ptr.child) ++ "'");
                                if (ptr.child == u8) {
                                    @compileLog("Duplicating string value...");
                                    return try allocator.dupe(u8, v);
                                } else return null;
                            },
                            .arr => |a| {
                                const ElemType = ptr.child;
                                @compileLog("Array node type >> Slice type '" ++ @typeName(ElemType) ++ "'");
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
                    else => @compileError("Expected struct, slice, or array type. Found " ++ @typeName(T)),
                }
            },
            .array => |array_info| {
                switch (self) {
                    .arr => |a| {
                        if (a.len != array_info.len) {
                            return null;
                        }

                        const ElemType = array_info.child;
                        var arr: [array_info.len]ElemType = .{undefined} ** array_info.len;
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
            else => @compileError("Expected struct, slice, or array type. Found " ++ @typeName(T)),
        }
    }
};

/// Custom structure that represents an "object", where each member is a string key and a node value
pub const NodeMap = struct {
    /// Literally all keys smooshed into a single dynamic byte array, separated by null characters.
    keys_compressed: ArrayList(u8),
    /// Map of values, where the key is a u32 hash of the string-valued key to avoid allocations on copying the keys.
    /// Using CityHash32 as the hashing algo.
    value_map: AutoArrayHashMap(u32, Value),

    const Value = struct {
        node: Node,
        offset: usize,
    };

    /// Iterator over the key-value pairs of the `NodeMap`
    pub const Iterator = struct {
        inner: AutoArrayHashMap(u32, Value).Iterator,
        map: NodeMap,

        /// Get next key-value pair or null if at the end of the collection
        pub fn next(self: *Iterator) ?struct { []const u8, Node } {
            const next_node_primitive: ?AutoArrayHashMap(u32, Value).Entry = self.inner.next();
            if (next_node_primitive) |n| {
                const key: []const u8 = mem.sliceTo(self.map.keys_compressed.items[n.value_ptr.offset..], 0);
                return .{ key, n.value_ptr.node };
            }
            return null;
        }

        /// Get the length of the iterator
        pub fn len(self: Iterator) u32 {
            return self.inner.len;
        }
    };

    /// Initialize this structure with an allocator
    pub fn init(allocator: Allocator) NodeMap {
        return .{
            .keys_compressed = .init(allocator),
            .value_map = .init(allocator),
        };
    }

    /// Put a new node (overwrites previous entry if a collision occurs)
    pub fn put(self: *NodeMap, k: []const u8, v: Node) !void {
        for (k) |byte| {
            try self.keys_compressed.append(byte);
        }
        try self.keys_compressed.append(0);

        const next_idx: usize = self.keys_compressed.items.len;
        try self.value_map.put(hash(k), .{ .node = v, .offset = next_idx });
    }

    /// Get a node by its key, if it exists
    pub fn get(self: NodeMap, k: []const u8) ?Node {
        if (self.value_map.get(hash(k))) |node_value| {
            return node_value.node;
        }
        return null;
    }

    /// Get an iterator for all key-value pairs in this map
    pub fn iter(self: *const NodeMap) Iterator {
        return .{ .inner = self.value_map.iterator(), .map = self.* };
    }

    fn hash(k: []const u8) u32 {
        return std.hash.CityHash32.hash(k);
    }

    /// Convert to a structure
    /// Note that string and array fields are duplicated and will need to be freed.
    pub fn projectTo(self: NodeMap, comptime T: type, allocator: Allocator) Allocator.Error!?T {
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                var x: T = undefined;
                inline for (struct_info.fields) |field| {
                    const FieldType = field.type;
                    @compileLog("Projecting for field '" ++ field.name ++ "', which is type: " ++ @typeName(FieldType));
                    if (self.get(mem.sliceTo(field.name, 0))) |val| {
                        switch (val) {
                            .obj => |o| {
                                @compileLog("Node map field '" ++ field.name ++ "' projecting to object type.");
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
                                @compileLog("Node map field '" ++ field.name ++ "' projecting to string type.");
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
                                        @compileLog("Node map field '" ++ field.name ++ "' projecting to slice type: " ++ @typeName(ElementType));
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
            else => @compileError("Expected struct type. Found " ++ @typeName(T)),
        }
    }

    /// Free memory owned by this map
    pub fn deinit(self: *NodeMap) void {
        self.keys_compressed.deinit();
        self.value_map.deinit();
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
test "NodeMap" {
    var map: NodeMap = .init(testing.allocator);
    defer map.deinit();

    var iter: NodeMap.Iterator = map.iter();
    try testing.expectEqual(null, iter.next());

    try map.put("key", Node{ .value = "value" });
    try testing.expectEqualStrings("value", map.get("key").?.value);

    iter = map.iter();
    const kvp = iter.next();
    try testing.expect(kvp != null);
    try testing.expectEqualStrings("key", kvp.?.@"0");
    try testing.expectEqualStrings("value", kvp.?.@"1".value);
    try testing.expectEqual(null, iter.next());

    const X = struct {
        key: []const u8,
    };
    const x: ?X = try map.projectTo(X, testing.allocator);
    try testing.expect(x != null);
    try testing.expectEqualStrings("value", x.?.key);
}
test "Node projectTo()" {
    var obj: NodeMap = .init(testing.allocator);
    defer obj.deinit();

    try obj.put("static_field", Node{ .value = "static value" });
    try obj.put("arr", Node{
        .arr = &[_]Node{
            .{ .value = "val_0" },
            .{ .value = "val_1" },
            .{ .value = "val_2" },
        },
    });
    try obj.put("nested_obj", Node{ .obj = NodeMap.init(testing.allocator) });
    var nested: NodeMap = obj.get("nested_obj").?.obj;
    try nested.put("nested_value", Node{ .value = "nested value" });

    const Schema = struct {
        static_field: []const u8,
        arr: []const []const u8,
        nested_obj: struct {
            nested_value: []const u8,
        },
    };
    const x: ?Schema = try obj.projectTo(Schema, testing.allocator);
    defer {
        testing.allocator.free(x.?.static_field);
        for (x.?.arr) |word| {
            testing.allocator.free(word);
        }
        testing.allocator.free(x.?.nested_obj.nested_value);
    }

    try testing.expect(x != null);
}
