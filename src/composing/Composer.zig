//! Handles the composition of the file schemas to be generation
const Composer = @This();

/// Arena allocator
arena: ArenaAllocator,
/// Tracking usage of $ref types to 1) validate at the end 2) use their descriptions on $ref-typed properties
ref_map: RefMap,
/// Whether or not nullable reference types are enabled
enable_nullable: bool,
/// Stringifies YAML elements in the event of an error
err_writer: Io.Writer.Allocating,

/// A map of type names to their definitions
pub const RefMap = std.StringArrayHashMapUnmanaged(FileGen);

const Def = struct {
    name: []const u8,
    schema: SchemaPath,
    type_def: enum { monomorphic, composite },
};

pub fn init(gpa: Allocator, enable_nullable: bool) Composer {
    return .{
        .arena = .init(gpa),
        .ref_map = .empty,
        .enable_nullable = enable_nullable,
        .err_writer = undefined,
    };
}

/// Compose all the files from the YAML file
/// The resulting slice of generated files is owned by the `ArenaAllocator`
pub fn compose(self: *Composer, file: Yaml) ComposeError!void {
    // new error writer
    self.err_writer = .init(self.arena.allocator());

    var schemas: ?Map = null;
    if (file.rootObject().get("components")) |components|
        if (components.asMap()) |components_map|
            if (components_map.get("schemas")) |s| {
                schemas = s.asMap();
            };
    if (schemas) |component_schemas| {
        try self.parseSchemas(component_schemas);
    } else {
        log.err("Unable to find path '{s}' in YAML file or the path was not an object.", .{root.schema_section});
        return error.MissingSchemas;
    }

    var refs: RefMap.Iterator = self.ref_map.iterator();
    while (refs.next()) |ref| {
        const file_gen: FileGen = ref.value_ptr.*;
        switch (file_gen) {
            .class => |class| {
                // @constCast() is almost always naughty, but this is memory we created that we're okay with modifying
                for (@constCast(class.props)) |*p| {
                    const prop: *Property = p;
                    if (prop.type.user_defined_root_type) |ref_type| {
                        log.debug("Evaluating prop {s}.{s} of type {s} ($ref: {s})", .{ class.name, prop.name, prop.type.name, ref_type });
                        if (self.ref_map.get(ref_type)) |r| switch (r) {
                            .class => |cl| {
                                if (prop.description.len == 0) {
                                    prop.description = cl.description;
                                }
                                if (mem.find(u8, prop.type.name, ref_type)) |_| {
                                    log.debug("Property {s} on class {s} refers to its reference {s}. Replacing with {s}.", .{ prop.name, class.name, prop.type.name, cl.name });
                                    prop.type.name = try mem.replaceOwned(u8, self.arena.allocator(), prop.type.name, ref_type, cl.name);
                                }
                            },
                            .@"enum" => |e| {
                                if (prop.description.len == 0) {
                                    prop.description = e.description;
                                }
                                // enums are value types, but we initially assume that $ref's are all reference types until this point
                                prop.type.mem_type = .value;
                                // we're also gonna say that nullable enums are not allowed since we don't define 0
                                // making enums nullable on top of that is redundant and annoying
                                prop.nullable = false;
                                if (mem.find(u8, prop.type.name, ref_type)) |_| {
                                    log.debug("Property {s} on class {s} refers to its reference {s}. Replacing with {s}.", .{ prop.name, class.name, prop.type.name, e.name });
                                    prop.type.name = try mem.replaceOwned(u8, self.arena.allocator(), prop.type.name, ref_type, e.name);
                                }
                            },
                            .composite => |comp| {
                                const resolved: FileGen = try comp.resolve(self.ref_map);
                                if (prop.description.len == 0) {
                                    prop.description = switch (resolved) {
                                        inline else => |x| x.description,
                                    };
                                }
                                if (mem.find(u8, prop.type.name, ref_type)) |_| {
                                    const type_name: []const u8 = switch (resolved) {
                                        inline else => |x| x.name,
                                    };
                                    log.debug("Property {s} on class {s} refers to its reference {s}. Replacing with {s}.", .{ prop.name, class.name, prop.type.name, type_name });
                                    prop.type.name = try mem.replaceOwned(u8, self.arena.allocator(), prop.type.name, ref_type, type_name);
                                }
                            },
                        } else {
                            log.err("Reference to type '{s}' is undefined", .{ref_type});
                            var iter: RefMap.Iterator = self.ref_map.iterator();
                            log.err("Defined maps are:", .{});
                            while (iter.next()) |kvp| log.info("$ref: {s} -> {f}", .{ kvp.key_ptr.*, kvp.value_ptr.* });
                            return error.UndefinedReference;
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (comptime @import("builtin").mode == .Debug) {
        log.info("Finished composing all types:", .{});
        var print_iter: RefMap.Iterator = self.ref_map.iterator();
        while (print_iter.next()) |kvp| log.info("$ref: {s} ->\n{f}", .{ kvp.key_ptr.*, kvp.value_ptr.* });
    }
}

pub fn deinit(self: Composer) void {
    self.arena.deinit();
}

fn parseSchemas(self: *Composer, schemas: Map) ComposeError!void {
    var composite_map: CompositeMap = .empty;

    var iter: Map.Iterator = schemas.iterator();
    while (iter.next()) |s| {
        const name: []const u8 = s.key_ptr.*;
        const schema: Map = s.value_ptr.asMap() orelse {
            try s.value_ptr.stringify(&self.err_writer.writer, .{});
            log.err("Schema for type '{s}/{s}' was not defined as an object:\n'{s}'", .{ root.schema_section, name, self.err_writer.written() });
            return error.InvalidSchema;
        };

        const path: SchemaPath = .componentsSchemas(schema, &.{name}, &self.err_writer);
        const def: Def = .{ .name = name, .schema = path, .type_def = .monomorphic };
        try self.parseTypeDefinition(def, &composite_map);
    }

    // add actual class types for the composite types
    var composite_iter: CompositeMap.Iterator = composite_map.iterator();
    while (composite_iter.next()) |c| {
        try c.value_ptr.addType(self.arena.allocator(), &self.ref_map);
    }
}

/// Parse a type definition from a schema
fn parseTypeDefinition(self: *Composer, def: Def, composite_map: *CompositeMap) ComposeError!void {
    const @"type": ?[]const u8 =
        try def.schema.readString("type", .null) orelse
        try def.schema.readString("x-type", .null) orelse
        try def.schema.readString("$ref", .null);

    if (@"type") |t| {
        const file: FileGen =
            if (mem.eql(u8, t, "object")) .{
                .class = try self.parseClass(def, composite_map),
            } else if (mem.eql(u8, t, "string") and def.type_def == .monomorphic) .{
                .@"enum" = try self.parseEnum(def),
            } else {
                log.err("{t} schema '{f}' has incorrect type: '{s}'", .{ def.type_def, def.schema, t });
                return error.UnknownType;
            };
        var key_stream: Io.Writer.Allocating = .init(self.arena.allocator());
        def.schema.format(&key_stream.writer) catch return error.OutOfMemory;

        // can assume no-clobber because the schema is already a hash map
        try self.ref_map.putNoClobber(self.arena.allocator(), key_stream.written(), file);
    } else {
        try self.parseCompositeType(def, composite_map);
    }
}

fn parseCompositeType(self: *Composer, def: Def, composite_map: *CompositeMap) ComposeError!void {
    const composite_type_list: Yaml.List, const composite_strategy: CompositeStrategy =
        if (try def.schema.readList("allOf", .null)) |list| .{
            list, .allOf,
        } else if (try def.schema.readList("anyOf", .null)) |list| .{
            list, .anyOf,
        } else if (try def.schema.readList("oneOf", .null)) |list| .{
            list, .oneOf,
        } else {
            log.err("Required field 'type', 'x-type', '$ref', 'allOf', 'anyOf', or 'oneOf' was not found in '{f}'", .{def.schema});
            return error.InvalidSchema;
        };

    var refs: ArrayList([]const u8) = .empty;
    for (composite_type_list, 0..) |c, i| {
        const ref_map: Map = c.asMap() orelse {
            log.err("Field '{f}/{t}[{d}]' was not an object as expected.", .{ def.schema, composite_strategy, i });
            return error.InvalidSchema;
        };
        if (ref_map.get("$ref")) |ref| {
            try refs.append(self.arena.allocator(), ref.asScalar() orelse {
                try ref.stringify(&self.err_writer.writer, .{});
                log.err("$ref property '{f}/{t}[{d}]' was not a scalar: '{s}'.", .{ def.schema, composite_strategy, i, self.err_writer.written() });
                return error.InvalidSchema;
            });
        } else {
            // We're dealing with an anonymous type here, being defined as a part of the composite type.
            // These anonymous types should not become a contract.
            var stream: Io.Writer.Allocating = .init(self.arena.allocator());

            stream.writer.print("{t}[{d}]", .{ composite_strategy, i }) catch return error.OutOfMemory;
            const composite_def: Def = .{
                .name = stream.written(),
                .schema = try def.schema.pushLocation(self.arena.allocator(), ref_map, &.{stream.written()}),
                .type_def = .composite,
            };
            try self.parseTypeDefinition(composite_def, composite_map);

            var ref_stream: Io.Writer.Allocating = .init(self.arena.allocator());
            composite_def.schema.format(&ref_stream.writer) catch return error.OutOfMemory;
            try refs.append(self.arena.allocator(), ref_stream.written());
        }
    }
    var key_stream: Io.Writer.Allocating = .init(self.arena.allocator());
    def.schema.format(&key_stream.writer) catch return error.OutOfMemory;

    // it's already a hash map, so we don't have to worry about clobbering
    const composite_type: CompositeType = .{
        .name = def.name,
        .description = try def.schema.readString("description", .{ .default_value = "" }),
        .deprecated = try def.schema.readBool("deprecated", .{ .default_value = false }),
        .types = try refs.toOwnedSlice(self.arena.allocator()),
        .strategy = composite_strategy,
    };
    try composite_map.putNoClobber(self.arena.allocator(), key_stream.written(), composite_type);
    try self.ref_map.putNoClobber(self.arena.allocator(), key_stream.written(), .{ .composite = composite_type });
}

fn parseEnum(self: *Composer, def: Def) ComposeError!Enum {
    if (def.schema.map.get("enum")) |e|
        if (e.asList()) |enum_list| {
            var members: ArrayList([]const u8) = .empty;
            defer members.deinit(self.arena.allocator());

            for (enum_list, 0..) |val, i| try members.append(
                self.arena.allocator(),
                val.asScalar() orelse {
                    log.err("Item {d} was not a scalar in '{f}/enum'", .{ i, def.schema });
                    return error.InvalidSchema;
                },
            );

            const bit_flag: bool = try def.schema.readBool("bit-flag", .{ .default_value = false });
            const description: []const u8 = try def.schema.readString("description", .{ .default_value = "" });
            const deprecated: bool = try def.schema.readBool("deprecated", .{ .default_value = false });

            const @"enum": Enum = .{
                .name = def.name,
                .members = try members.toOwnedSlice(self.arena.allocator()),
                .is_flag = bit_flag,
                .description = description,
                .deprecated = deprecated,
            };
            return @"enum";
        };
    log.err("Expected 'enum' property with list of enum values in '{f}'", .{def.schema});
    return error.InvalidSchema;
}

fn parseClass(self: *Composer, def: Def, composite_map: *CompositeMap) ComposeError!Class {
    var class: Class = .empty(def.name, switch (def.type_def) {
        .monomorphic => .contract,
        .composite => .intermediate,
    });

    const path: SchemaPath = .componentsSchemas(def.schema.map, &.{def.name}, &self.err_writer);
    class.description = try path.readString("description", .{ .default_value = "" });

    const properties: Map = if (path.map.get("properties")) |props|
        props.asMap() orelse {
            try props.stringify(&self.err_writer.writer, .{});
            log.err("Schema for type '{f}/properties' was not defined as an object:\n'{s}'", .{ path, self.err_writer.written() });
            return error.InvalidSchema;
        }
    else
        // I guess zero properties is allowed?
        .empty;

    if (path.map.get("required")) |req| {
        if (req.asList()) |list| {
            for (list) |x| try class.required.put(self.arena.allocator(), x.asScalar() orelse {
                try req.stringify(&self.err_writer.writer, .{});
                log.err("Schema for type '{f}/required' was not defined as an array of scalars:\n'{s}'", .{ path, self.err_writer.written() });
                return error.InvalidSchema;
            }, {});
        } else {
            try req.stringify(&self.err_writer.writer, .{});
            log.err("Schema for type '{f}/required' was not defined as an array of scalars:\n'{s}'", .{ path, self.err_writer.written() });
            return error.InvalidSchema;
        }
    }

    class.deprecated = try path.readBool("deprecated", .{ .default_value = false });
    class.props = try self.parseClassProperties(properties, def, composite_map, class.required);

    return class;
}

fn parseClassProperties(
    self: *Composer,
    properties: Map,
    def: Def,
    composite_map: *CompositeMap,
    required: StringSet,
) ComposeError![]const Property {
    var props: ArrayList(Property) = try .initCapacity(self.arena.allocator(), properties.count());
    var prop_iter: Map.Iterator = properties.iterator();
    while (prop_iter.next()) |prop| {
        const property_def: Map = prop.value_ptr.asMap() orelse {
            try prop.value_ptr.stringify(&self.err_writer.writer, .{});
            log.err("Property '{f}/properties/{s}' is not defined as an object:\n'{s}'", .{
                def.schema,
                prop.key_ptr.*,
                self.err_writer.written(),
            });
            return error.InvalidSchema;
        };
        const prop_name: []const u8 = prop.key_ptr.*;
        log.debug("Parsing property '{f}/properties/{s}'", .{ def.schema, prop_name });

        const path: SchemaPath = .componentsSchemas(property_def, &.{ def.name, "properties", prop_name }, &self.err_writer);
        const @"type": ?[]const u8 =
            try path.readString("type", .null) orelse
            try path.readString("x-type", .null) orelse
            try path.readString("$ref", .null);

        const format: ?[]const u8 = try path.readString("format", .null);
        const description: []const u8 = try path.readString("description", .{ .default_value = "" });
        const deprecated: bool = try path.readBool("deprecated", .{ .default_value = false });
        var nullable: bool = try path.readBool("nullable", .{ .default_value = false });
        var data_annotations: ArrayList(DataAnnotations) = .empty;

        if (@"type") |t| {
            var csharp_type: CsharpType = undefined;

            // are we declaring an inline enum type?
            if (path.map.get("enum")) |_| {
                var stream: Io.Writer.Allocating = .init(self.arena.allocator());
                stream.writer.print("{f}", .{Casing.titleCase(prop_name)}) catch return error.OutOfMemory; // we're just gonna use the property name

                const inline_enum_name: []const u8 = stream.written();
                const @"enum": Enum = try self.parseEnum(.{ .schema = path, .name = inline_enum_name, .type_def = .monomorphic });
                // pop this into the `ref_map` so that we'll be sure to generate a file for it
                const gop: RefMap.GetOrPutResult = try self.ref_map.getOrPut(self.arena.allocator(), inline_enum_name);
                if (gop.found_existing) {
                    // this would be an unfortunate accident, but let's flag it so it doesn't go unnoticed
                    log.err("Already defined type with name '{s}'. This type name was derrived from the property found in {f}/{s}, which declares an inline type.", .{ inline_enum_name, path, prop_name });
                    return error.TypeNameCollision;
                }
                gop.value_ptr.* = .{ .@"enum" = @"enum" };

                // We know this is an enum, so we can be smart about this and save ourselves some work.
                csharp_type = .valueType(inline_enum_name);
                // No nullable enum properties: That's part of our opinionated generation rules.
                nullable = false;
            } else {
                // only relevant for array types
                const items: ?Map = if (path.map.get("items")) |i| i.asMap() else null;
                // only releveant for object types (dictionaries have this)
                const additional_properties: ?Map = if (path.map.get("additionalProperties")) |a| a.asMap() else null;

                csharp_type = self.interpretType(t, format, items, additional_properties, &data_annotations) catch |err| {
                    switch (err) {
                        error.UnknownType => log.err("Failed to interpret type of property '{f}': Type '{s}'", .{ path, t }),
                        error.UnknownFormat => log.err("Failed to interpret type of property '{f}': Format '{?s}' and type '{s}'", .{ path, format, t }),
                        else => log.err("Failed to interpret type of property '{f}'", .{path}),
                    }
                    return err;
                };

                if (csharp_type.mem_type == .reference) {
                    if (!self.enable_nullable) {
                        // disable nullable on all reference types
                        nullable = false;
                    } else {
                        nullable = required.get(prop_name) == null;
                    }
                }
            }
            try path.getDataAnnotations(self.arena.allocator(), &data_annotations);

            const property: Property = .{
                .name = prop_name,
                .type = csharp_type,
                .description = description,
                .nullable = nullable,
                .deprecated = deprecated,
                .data_annotations = data_annotations.items,
            };
            props.appendAssumeCapacity(property);
        } else {
            var stream: Io.Writer.Allocating = .init(self.arena.allocator());

            // we're assuming all composite-type properties are reference types
            if (!self.enable_nullable) {
                // disable nullable on all reference types
                nullable = false;
            } else {
                nullable = required.get(prop_name) == null;
            }

            try path.format(&stream.writer);
            const sub_def: Def = .{ .name = stream.written(), .schema = path, .type_def = .composite };
            try self.parseCompositeType(sub_def, composite_map);
            try path.getDataAnnotations(self.arena.allocator(), &data_annotations);
            const property: Property = .{
                .name = prop_name,
                .type = .userDefined(sub_def.name, sub_def.name),
                .description = description,
                .nullable = nullable,
                .deprecated = deprecated,
                .data_annotations = data_annotations.items,
            };
            props.appendAssumeCapacity(property);
        }
    }
    return try props.toOwnedSlice(self.arena.allocator());
}

fn interpretType(
    self: *Composer,
    t: []const u8,
    format: ?[]const u8,
    items: ?Map,
    additional_properties: ?Map,
    data_annotations: *ArrayList(DataAnnotations),
) ComposeError!CsharpType {
    const @"type" = if (std.meta.stringToEnum(enum {
        string,
        integer,
        number,
        boolean,
        array,
        object,
        dictionary,
    }, t)) |parsed| parsed else {
        const ref: []const u8 = try parseRefType(t);
        return .userDefined(ref, t);
    };

    return try switch (@"type") {
        .string => self.parseStringType(format, data_annotations),
        .integer => parseIntType(format),
        .number => parseNumberType(format),
        .boolean => CsharpType.valueType("bool"),
        .array => self.parseArrType(items, data_annotations),
        .object => self.parseObjType(additional_properties),
        .dictionary => self.parseDictionaryType(additional_properties),
    };
}

fn parseStringType(self: *Composer, format: ?[]const u8, data_annotations: *ArrayList(DataAnnotations)) ComposeError!CsharpType {
    return if (format) |f|
        if (meta.stringToEnum(StringFormats, f)) |s| switch (s) {
            .@"date-time", .datetime => .valueType("DateTime"),
            .uuid => .valueType("Guid"),
            .uri => uri: {
                try data_annotations.append(self.arena.allocator(), .url);
                break :uri .referenceType("Uri");
            },
        } else error.UnknownFormat
    else
        .referenceType("string");
}

fn parseIntType(format: ?[]const u8) ComposeError!CsharpType {
    return if (format) |f|
        if (meta.stringToEnum(IntFormats, f)) |i|
            .valueType(switch (i) {
                .byte => "byte",
                .int16 => "short",
                .int32 => "int",
                .int64 => "long",
            })
        else
            error.UnknownFormat
    else
        .valueType("int"); // defaulting to int
}

fn parseNumberType(format: ?[]const u8) ComposeError!CsharpType {
    return if (format) |f|
        if (meta.stringToEnum(NumberFormats, f)) |n|
            .valueType(@tagName(n))
        else
            error.UnknownFormat
    else
        .valueType(@tagName(NumberFormats.double)); // defaulting to double
}

fn parseArrType(self: *Composer, items: ?Map, data_annotations: *ArrayList(DataAnnotations)) ComposeError!CsharpType {
    if (items) |i| {
        const path: SchemaPath = .detachedSchema(i, &.{"items"}, &self.err_writer);
        if (try path.readString("$ref", .null)) |ref| {
            const parsed_ref: []const u8 = try parseRefType(ref);
            return .userDefined(
                try fmt.allocPrint(self.arena.allocator(), "{s}[]", .{parsed_ref}),
                ref,
            );
        } else if (try path.readString("type", .null)) |sub_type| {
            const sub_format: ?[]const u8 = try path.readString("format", .null);
            const sub_items: ?Map = if (path.map.get("items")) |x| x.asMap() else null;
            const sub_additional_props: ?Map = if (path.map.get("additionalProperties")) |x| x.asMap() else null;
            const recursed: CsharpType = try self.interpretType(sub_type, sub_format, sub_items, sub_additional_props, data_annotations);
            return .referenceType(
                try fmt.allocPrint(self.arena.allocator(), "{s}[]", .{recursed.name}),
            );
        } else {
            log.err("Array type specified, but could not determine sub_type. Specify a '$ref', 'type', or 'x-type' property.", .{});
            return error.InvalidSchema;
        }
    }
    log.err("Array type specified, but no items were found.", .{});
    return error.InvalidSchema;
}

fn parseDictionaryType(self: *Composer, additional_properties: ?Map) ComposeError!CsharpType {
    // This is a general assumption, but when we have a non-nullable value, it tends to bite our butts.
    // By default, let's assume it should be nullable.
    var nullable_value: bool = true;
    if (additional_properties) |props| {
        const path: SchemaPath = .detachedSchema(props, &.{"additionalProperties"}, &self.err_writer);
        // if we have additional properties, but no nullable, that means the value is not nullable
        nullable_value = try path.readBool("nullable", .{ .default_value = false });
        if (try path.readString("$ref", .null)) |ref| {
            const ref_type: []const u8 = if (mem.startsWith(u8, ref, root.schema_section ++ "/"))
                ref[root.schema_section.len + 1 ..]
            else {
                log.err("Invalid $ref value '{s}' in property {f}/{s}", .{ ref, path, "$ref" });
                return error.InvalidReference;
            };
            var stream: Io.Writer.Allocating = .init(self.arena.allocator());
            stream.writer.print("Dictionary<string, {s}{s}>", .{ ref_type, if (nullable_value) "?" else "" }) catch return error.OutOfMemory;

            return .userDefined(stream.written(), ref);
        }
    }

    return .referenceType(
        if (nullable_value)
            "Dictionary<string, string?>"
        else
            "Dictionary<string, string>",
    );
}

fn parseObjType(self: *Composer, additional_properties: ?Map) ComposeError!CsharpType {
    if (additional_properties) |a| {
        const path: SchemaPath = .detachedSchema(a, &.{"additionalProperties"}, &self.err_writer);
        const nullable: bool = try path.readBool("nullable", .{ .default_value = false });
        if (try path.readString("$ref", .null)) |ref| {
            const ref_type: []const u8 = if (mem.startsWith(u8, ref, root.schema_section ++ "/"))
                ref[root.schema_section.len + 1 ..]
            else {
                log.err("Invalid $ref value '{s}' in property {f}/{s}", .{ ref, path, "$ref" });
                return error.InvalidReference;
            };
            var stream: Io.Writer.Allocating = .init(self.arena.allocator());
            stream.writer.print("Dictionary<string, {s}{s}>", .{ ref_type, if (nullable) "?" else "" }) catch return error.OutOfMemory;

            return .userDefined(stream.written(), ref);
        }

        if (path.map.get("type")) |additional_t| {
            if (additional_t.asScalar()) |additional_t_scalar| {
                if (mem.eql(u8, additional_t_scalar, "string")) {
                    return .referenceType(
                        if (nullable)
                            "Dictionary<string, string?>"
                        else
                            "Dictionary<string, string>",
                    );
                }
                if (mem.eql(u8, additional_t_scalar, "object")) {
                    return .referenceType(
                        if (nullable)
                            "Dictionary<string, object?>"
                        else
                            "Dictionary<string, object>",
                    );
                }
                log.err("Unknown format for type '{s}' in {f}/type", .{ additional_t_scalar, path });
                return error.UnknownFormat;
            } else if (additional_t.asMap()) |additional_t_map| {
                const sub_path: SchemaPath = .detachedSchema(additional_t_map, &.{ "additionalProperties", "type" }, &self.err_writer);
                if (try sub_path.readString("$ref", .null)) |r| {
                    const ref: []const u8 = try parseRefType(r);
                    return .userDefined(try fmt.allocPrint(self.arena.allocator(), "Dictionary<string, {s}{s}", .{ ref, if (nullable) "?>" else ">" }), r);
                }
            }
        }
        log.warn("No 'type' property specified in {f}; assigning property 'object' type.", .{path});
    }
    return .referenceType("object");
}

fn parseRefType(ref: []const u8) ComposeError![]const u8 {
    if (mem.startsWith(u8, ref, root.schema_section ++ "/")) {
        return ref[root.schema_section.len + 1 ..];
    }
    log.err("Invalid reference: '{s}'", .{ref});
    return error.InvalidSchema;
}

const log = std.log.scoped(.compose);

const SchemaPath = struct {
    root: []const u8,
    path: []const []const u8,
    map: Map,
    err_writer: *Io.Writer.Allocating,

    /// Assigns '#/components/schemas' to root
    fn componentsSchemas(map: Map, path: []const []const u8, err_writer: *Io.Writer.Allocating) SchemaPath {
        return .{
            .root = root.schema_section,
            .path = path,
            .map = map,
            .err_writer = err_writer,
        };
    }

    /// Assigns '..' to root, knowing that this path is detached from the root
    /// Will have to rely on logging context for the user to figure out where we are
    fn detachedSchema(map: Map, path: []const []const u8, err_writer: *Io.Writer.Allocating) SchemaPath {
        return .{
            .root = "..",
            .path = path,
            .map = map,
            .err_writer = err_writer,
        };
    }

    /// Create a new `SchemaPath` from another, pushing the `path` onto `self.path`
    fn pushLocation(
        self: *const SchemaPath,
        gpa: Allocator,
        map: Map,
        path: []const []const u8,
    ) Allocator.Error!SchemaPath {
        const appended_path: [][]const u8 = try gpa.alloc([]const u8, path.len + self.path.len);
        @memcpy(appended_path[0..self.path.len], self.path);
        @memcpy(appended_path[self.path.len..], path);

        return .{
            .root = self.root,
            .path = appended_path,
            .map = map,
            .err_writer = self.err_writer,
        };
    }

    fn readBool(
        self: *const SchemaPath,
        property: []const u8,
        comptime default: union(enum) { default_value: bool, null, err },
    ) ComposeError!switch (default) {
        .null => ?bool,
        else => bool,
    } {
        if (self.map.get(property)) |p| {
            if (p.asScalar()) |x| {
                if (std.meta.stringToEnum(enum { true, false }, x)) |val| return switch (val) {
                    .true => true,
                    .false => false,
                } else {
                    log.err("Property {f}/{s} was not a boolean scalar value: '{s}'", .{ self, property, x });
                    return error.InvalidSchema;
                }
            } else {
                try p.stringify(&self.err_writer.writer, .{});
                defer self.err_writer.clearRetainingCapacity();
                log.err("Property {f}/{s} was not a scalar value:\n{s}", .{ self, property, self.err_writer.written() });
                return error.InvalidSchema;
            }
        } else switch (default) {
            .default_value => |v| return v,
            .null => return null,
            .err => {
                log.err("Required property {f}/{s} was not found", .{ self, property });
                return error.InvalidSchema;
            }
        }
    }

    fn readString(
        self: *const SchemaPath,
        property: []const u8,
        comptime default: union(enum) { default_value: []const u8, null, err },
    ) ComposeError!switch (default) {
        .null => ?[]const u8,
        else => []const u8,
    } {
        return if (self.map.get(property)) |p| p.asScalar() orelse {
            try p.stringify(&self.err_writer.writer, .{});
            defer self.err_writer.clearRetainingCapacity();
            log.err("Property {f}/{s} was not a scalar value:\n{s}", .{ self, property, self.err_writer.written() });
            return error.InvalidSchema;
        } else switch (default) {
            .default_value => |v| v,
            .null => null,
            .err => {
                log.err("Required property {f}/{s} was not found", .{ self, property });
                return error.InvalidSchema;
            }
        };
    }

    fn readList(
        self: *const SchemaPath,
        property: []const u8,
        comptime default: enum { err, null, empty },
    ) switch (default) {
        .null => ComposeError!?Yaml.List,
        else => ComposeError!Yaml.List,
    } {
        return if (self.map.get(property)) |p| p.asList() orelse {
            log.err("Property {f}/{s} was not a map value:\n{s}", .{ self, property, self.err_writer.written() });
            return error.InvalidSchema;
        } else switch (default) {
            .empty => &.{},
            .null => null,
            .err => {
                log.err("Required property {f}/{s} was not found", .{ self, property });
                return error.InvalidSchema;
            },
        };
    }

    fn getDataAnnotations(self: *const SchemaPath, arena: Allocator, list: *ArrayList(DataAnnotations)) ComposeError!void {
        var iter: Map.Iterator = self.map.iterator();
        while (iter.next()) |entry| {
            if (std.meta.stringToEnum(@typeInfo(DataAnnotations).@"union".tag_type.?, entry.key_ptr.*)) |data_annotation| switch (data_annotation) {
                inline .maxLength, .minLength => |tag| {
                    if (entry.value_ptr.asScalar()) |value| {
                        const int_value: usize = fmt.parseUnsigned(usize, value, 10) catch {
                            log.err("Property {f}/{s} was not an integer. Found: '{s}'", .{ self, entry.key_ptr.*, value });
                            return error.InvalidSchema;
                        };
                        try list.append(arena, @unionInit(DataAnnotations, @tagName(tag), int_value));
                    } else {
                        try entry.value_ptr.stringify(&self.err_writer.writer, .{});
                        log.err("Property {f}/{s} was not a scalar value. Found: {s}", .{ self, entry.key_ptr.*, self.err_writer.written() });
                        return error.InvalidSchema;
                    }
                },
                .url => log.warn(
                    \\Found property {f}/{t}.
                    \\For URL-formatted fields, we expect the following:
                    \\  type: string
                    \\  format: uri
                    \\
                    \\Ignoring...
                , .{ self, DataAnnotations.url }),
            };
        }
    }

    pub fn format(self: *const SchemaPath, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(self.root);
        for (self.path) |p| try writer.print("/{s}", .{p});
    }
};

const std = @import("std");
const yaml = @import("yaml");
const root = @import("root.zig");
const zutil = @import("zutil");
const mem = std.mem;
const fmt = std.fmt;
const meta = std.meta;
const debug = std.debug;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;
const FileGen = root.FileGen;
const Yaml = yaml.Yaml;
const Value = Yaml.Value;
const Node = yaml.Tree.Node;
const Map = Yaml.Map;
const ComposeError = root.ComposeError;
const Class = root.Class;
const Enum = root.Enum;
const Property = root.Property;
const CsharpType = root.CsharpType;
const IntFormats = root.IntFormats;
const NumberFormats = root.NumberFormats;
const StringFormats = root.StringFormats;
const CompositeStrategy = root.CompositeStrategy;
const CompositeType = root.CompositeType;
const DataAnnotations = root.DataAnnotations;
const CompositeMap = std.StringArrayHashMapUnmanaged(CompositeType);
const StringSet = std.StringHashMapUnmanaged(void);
const Casing = zutil.string.Casing;
