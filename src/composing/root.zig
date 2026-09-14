/// Returned during composition
pub const ComposeError = Allocator.Error || yaml.Yaml.StringifyError || error{
    /// No schemas are defined in the YAML file
    MissingSchemas,
    /// YAML schema is invalid (details printed to console)
    InvalidSchema,
    /// Unrecognized type
    UnknownType,
    /// Unrecognized type format
    UnknownFormat,
    /// $ref points to some undefined type
    UndefinedReference,
    /// $ref is invalid (meaning it doesn't start with "#/componens/schemas/")
    InvalidReference,
    /// Returned when `allOf` elements contains the same property more than once
    RedundantProperty,
    /// Returned when a composite type is oneOf, allOf, anyOf with non-objects.
    /// Granted, this is allowed by some generators, but it does not translate well into C#.
    /// Taking the stance of disallowing this.
    InvalidVariant,
    /// If we have inline types, we assume the name is equal to the property name.
    /// However, this can result in type names colliding, which we need to flag.
    TypeNameCollision,
    /// Unsupported feature
    NotSupported,
};

const log = std.log.scoped(.compose);

pub const CsharpType = struct {
    /// The actual type name as it would appear in the C# file
    name: []const u8,
    /// The exact path of the $ref, which is used as the key
    user_defined_root_type: ?[]const u8 = null,
    /// Reference type (class) or value type (struct/enum)
    mem_type: enum { reference, value },

    pub fn referenceType(name: []const u8) CsharpType {
        return .{
            .name = name,
            .mem_type = .reference,
        };
    }

    pub fn valueType(name: []const u8) CsharpType {
        return .{
            .name = name,
            .mem_type = .value,
        };
    }

    /// Types that depend on $ref's in our schema.
    /// In the scenario of composite types (e.g. "MyType[]" or "Dictionary<string, MyType>"), we need to track the root-type that's a $ref alongside the full type name.
    pub fn userDefined(full_name: []const u8, user_defined_root_type: []const u8) CsharpType {
        return .{
            .name = full_name,
            .user_defined_root_type = user_defined_root_type,
            // assume reference type to start (will be retroactively corrected when the Composer validates $ref's)
            .mem_type = .reference,
        };
    }
};

pub const Class = struct {
    name: []const u8,
    description: []const u8,
    props: []const Property,
    deprecated: bool,
    discriminator: ?Property,
    extends: ?[]const u8,
    definition: DefinitionType,
    required: StringSet,

    pub fn empty(name: []const u8, definition: DefinitionType) Class {
        return .{
            .name = name,
            .description = "",
            .props = &.{},
            .deprecated = false,
            .extends = null,
            .discriminator = null,
            .definition = definition,
            .required = .empty,
        };
    }

    pub fn stylizeName(self: Class, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{f}", .{Casing.titleCase(self.name)});
    }
};

pub const Enum = struct {
    name: []const u8,
    description: []const u8,
    members: []const []const u8,
    is_flag: bool = false,
    deprecated: bool,

    pub fn stylizeName(self: Enum, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{f}", .{Casing.titleCase(self.name)});
    }
};

/// Assuming all properties are public
pub const Property = struct {
    /// Name will be stylized to idiomatic title-case
    /// If the stylized name is found to be different, then that will be assigned as a `[JsonProperty()]` attribute
    name: []const u8,
    description: []const u8,
    type: CsharpType,
    nullable: bool = false,
    deprecated: bool,
    data_annotations: []const DataAnnotations,

    pub fn stylizeName(self: Property, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{f}", .{Casing.titleCase(self.name)});
    }
};

pub const StringFormats = enum {
    @"date-time",
    datetime,
    uuid,
    uri,
};

pub const IntFormats = enum {
    byte,
    int16,
    int32,
    int64,
};

pub const NumberFormats = enum {
    float,
    double,
    decimal,
};

pub const FileGen = union(enum) {
    composite: CompositeType,
    class: Class,
    @"enum": Enum,

    pub fn format(self: FileGen, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("/// {s}\n{t} ", .{ switch (self) {
            inline else => |x| x.description,
        }, self });
        switch (self) {
            .class => |c| {
                try c.stylizeName(writer);
                if (c.extends) |ex| try writer.print(" : {s}", .{ex});
                try writer.print(" [{t}]", .{c.definition});
                try writer.writeAll(" {\n");
                for (c.props) |prop| {
                    try writer.print("    {f}: {s}\n", .{ Casing.titleCase(prop.name), prop.type.name });
                }
                try writer.writeByte('}');
            },
            .@"enum" => |e| {
                try e.stylizeName(writer);
                try writer.writeAll(": [\n");
                for (e.members) |val| {
                    try writer.print("    {s}\n", .{val});
                }
                try writer.writeByte(']');
            },
            .composite => |comp| {
                try writer.print("type {s} ({t}): [\n", .{ comp.name, comp.strategy });
                for (comp.types) |t| {
                    try writer.print("    {s}\n", .{t});
                }
                try writer.writeByte(']');
            },
        }
    }

    pub fn fileName(self: FileGen, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .composite => |comp| {
                log.debug("Skipping file name for composite type {s}. Composite types are assumed to be intermediary and not meant to make it to the final contracts.", .{comp.name});
                return;
            },
            inline else => |x| try x.stylizeName(writer),
        }
        try writer.writeAll(".cs");
    }
};

pub const CompositeStrategy = enum { allOf, anyOf, oneOf };

pub const DefinitionType = enum { contract, intermediate };

pub const DataAnnotations = union(enum) {
    maxLength: usize,
    minLength: usize,
    url,

    pub fn format(self: DataAnnotations, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .maxLength, .minLength => |len, tag| {
                try writer.print("[{f}({d})]", .{ Casing.titleCase(@tagName(tag)), len });
            },
            .url => |_, tag| {
                try writer.print("[{f}]", .{Casing.titleCase(@tagName(tag))});
            }
        }
    }
};

pub const CompositeType = struct {
    name: []const u8,
    description: []const u8,
    deprecated: bool,
    strategy: CompositeStrategy,
    types: []const []const u8,

    const PropertyMap = std.StringHashMapUnmanaged(Property);

    pub const AddTypeError = error{ RedundantProperty, UndefinedReference, InvalidVariant, NotSupported } || Allocator.Error;

    pub fn resolve(self: CompositeType, refs: Composer.RefMap) error{UndefinedReference}!FileGen {
        if (self.types.len > 1) {
            const s: FileGen = .{ .composite = self };
            log.debug(
                \\Composite type {s} is composed of {d} sub-types:
                \\{f}
                \\Be particularly scrutinous evaluating this output.
            , .{ self.name, self.types.len, s });
            return s;
        }
        var key: []const u8 = self.types[0];
        while (refs.get(key)) |ref| switch (ref) {
            .class => return ref,
            .@"enum" => return ref,
            .composite => |comp| if (!mem.startsWith(u8, comp.name, schema_section)) {
                return ref;
            } else {
                if (comp.types.len > 1) {
                    const s: FileGen = .{ .composite = comp };
                    log.debug(
                        \\Composite type {s} is composed of {d} sub-types:
                        \\{f}
                        \\Be particularly scrutinous evaluating this output.
                    , .{ comp.name, comp.types.len, s });
                    return s;
                }
                key = comp.types[0];
            },
        };
        return error.UndefinedReference;
    }

    pub fn addType(self: CompositeType, gpa: Allocator, refs: *Composer.RefMap) AddTypeError!void {
        if (self.types.len == 1) {
            if (refs.get(self.types[0])) |val| {
                const gop: Composer.RefMap.GetOrPutResult = try refs.getOrPut(gpa, self.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .class = .{
                            .name = self.name,
                            .description = if (self.description.len > 0) self.description else switch (val) {
                                inline else => |x| x.description,
                            },
                            .props = &.{},
                            .deprecated = self.deprecated or switch (val) {
                                inline else => |x| x.deprecated,
                            },
                            .definition = .contract,
                            .discriminator = null,
                            .extends = switch (val) {
                                .class => |cl| cl.name,
                                else => {
                                    log.err("Can't extend a non-class type. Found {f}.", .{val});
                                    return error.InvalidVariant;
                                }
                            },
                            .required = switch (val) {
                                .class => |cl| cl.required,
                                else => .empty,
                            },
                        },
                    };
                }
                return;
            } else {
                log.err("Reference to type '{s}' was not found. Defined types are:", .{self.types[0]});
                var iter: Composer.RefMap.Iterator = refs.iterator();
                while (iter.next()) |kvp| log.err("$ref: {s} -> {f}", .{ kvp.key_ptr.*, kvp.value_ptr.* });
                return error.UndefinedReference;
            }
        }

        var prop_map: PropertyMap = .empty;
        defer prop_map.deinit(gpa);

        var discriminator: ?Property = null;
        var deprecated: bool = self.deprecated;
        var description: []const u8 = self.description;
        var required: StringSet = .empty;
        errdefer required.deinit(gpa);
        for (self.types, 0..) |t, i| {
            const ref: FileGen = refs.get(t) orelse {
                log.err("Type {s} is not defined", .{t});
                return error.UndefinedReference;
            };
            switch (ref) {
                .class => |c| {
                    for (c.props) |prop| {
                        const gop: PropertyMap.GetOrPutResult = try prop_map.getOrPut(gpa, prop.name);
                        if (gop.found_existing) {
                            log.err("Property {s} of type {s} is already defined on class {s} (ref {d}).", .{ prop.name, gop.value_ptr.type.name, c.name, i });
                            return error.RedundantProperty;
                        }
                        gop.value_ptr.* = prop;
                        deprecated = deprecated or c.deprecated;
                        if (description.len == 0) description = c.description;
                    }
                    if (c.discriminator) |disc| {
                        if (discriminator) |existing_disc| {
                            if (!mem.eql(u8, disc.name, existing_disc.name)) {
                                log.err("Property {s} is already defined as a discriminator for composite type {s}.", .{ disc.name, self.name });
                                return error.RedundantProperty;
                            }
                        } else discriminator = disc;
                    }
                    var required_iter: StringSet.KeyIterator = c.required.keyIterator();
                    while (required_iter.next()) |key| try required.put(gpa, key.*, {});
                },
                .composite => |comp| {
                    log.err("We'll burn that bridge when we get there. Depends on composite type {s}", .{comp.name});
                    return error.NotSupported;
                },
                .@"enum" => {
                    log.err("Type {s} cannot be allOf with a non-object variant (found type {s}, which is an enum).", .{ self.name, t });
                    return error.InvalidVariant;
                },
            }
        }

        const props: []Property = try gpa.alloc(Property, prop_map.count() + @as(u32, if (discriminator) |_| 1 else 0));
        errdefer gpa.free(props);

        var iter: PropertyMap.ValueIterator = prop_map.valueIterator();
        var i: usize = 0;
        while (iter.next()) |n| : (i += 1) props[i] = n.*;
        if (discriminator) |d| {
            debug.assert(i == props.len - 1);
            props[i] = d;
        }

        const gop: Composer.RefMap.GetOrPutResult = try refs.getOrPut(gpa, self.name);
        if (gop.found_existing) {
            log.debug("Composite type '{s}' already exists. Skipping...", .{self.name});
            return;
        }
        switch (self.strategy) {
            .allOf => {
                gop.value_ptr.* = .{
                    .class = .{
                        .name = self.name,
                        .description = description,
                        .deprecated = deprecated,
                        .props = props,
                        .extends = null,
                        .discriminator = discriminator,
                        .definition = .contract,
                        .required = required,
                    },
                };
            },
            else => {
                log.err("{t} not supported yet (evaluating type {s}).", .{ self.strategy, self.name });
                return error.NotSupported;
                // TODO : Base class and stuff
                //
                // if (self.strategy == .anyOf) {
                //     log.warn("'anyOf' type '{s}' will be naively treated as a 'oneOf' type in C# generation since C# does not support algebraic data types.", .{self.name});
                // }
                // gop.value_ptr.* = .{
                //     .class = .{
                //         .name = self.name,
                //         .description = description,
                //         .deprecated = deprecated,
                //         .props = props,
                //         .extends = null,
                //         .discriminator = discriminator,
                //         .definition = .contract,
                //         .required = required,
                //     },
                // };
            }
        }
    }
};

pub const schema_section: []const u8 = "#/components/schemas";

/// public decls
pub const Composer = @import("Composer.zig");

const std = @import("std");
const yaml = @import("yaml");
const zutil = @import("zutil");
const Casing = zutil.string.Casing;
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;
const debug = std.debug;
const Io = std.Io;
const Allocator = mem.Allocator;
const StringSet = std.StringHashMapUnmanaged(void);
