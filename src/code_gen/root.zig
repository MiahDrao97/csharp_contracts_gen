const std = @import("std");

pub const Property = struct {
    type: []const u8,
    format: ?[]const u8,
    description: ?[]const u8,
    @"enum": ?[]const []const u8,
};
