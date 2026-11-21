const std = @import("std");
const regex = @import("regex");

pub const Error = std.mem.Allocator.Error || error{
    UnknownRegexError,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Compiled),

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .map = .empty,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *Cache) void {
        self.map.clearRetainingCapacity();
    }

    pub fn get(
        self: *Cache,
        str: []const u8,
        diagnostic: *Diagnostic,
    ) Error!?*Compiled {
        const gop = try self.map.getOrPut(self.allocator, str);

        if (gop.found_existing) {
            return gop.value_ptr;
        }

        var diagnostic_: ?Diagnostic = null;

        gop.value_ptr.* = regex.Regex.compileWithFlagsDiagnostic(
            self.allocator,
            str,
            .{},
            &diagnostic_,
        ) catch |err| switch (err) {
            error.OutOfMemory => return @errorCast(err),
            else => {
                if (diagnostic_) |d| {
                    diagnostic.* = d;
                    return null;
                }
                return Error.UnknownRegexError;
            },
        };
        return gop.value_ptr;
    }
};

pub const Diagnostic = regex.CompileErrorReason;

pub const Compiled = regex.Regex;

pub fn diagnosticMessage(diagnostic: Diagnostic) []const u8 {
    return switch (diagnostic) {
        .missing_closing_parenthesis => "missing closing parenthesis",
        .missing_character_class_terminator => "missing ']' to close the character class",
        .quantifier_numbers_out_of_order => "numbers out of order in {} quantifier",
        .nothing_to_repeat => "nothing to repeat",
        .trailing_backslash => "backslash at end of pattern",
        .invalid_group_specifier_name => "invalid group name",
        .range_out_of_order_in_character_class => "range out of order in character class",
        .duplicate_group_specifier_name => "duplicate group name",
        .invalid_named_backreference => "invalid named backreference",
        .invalid_property_expression => "invalid \\p{...} property",
        .invalid_escaped_character_for_unicode_pattern => "invalid escape in unicode pattern",
        .invalid_unicode_escape => "invalid \\u escape",
        .invalid_unicode_code_point_escape => "invalid \\u{...} code point escape",
        .invalid_octal_escape_for_unicode_pattern => "octal escapes are not allowed in unicode patterns",
        .invalid_range_in_character_class_for_unicode_pattern => "invalid range in character class",
        .invalid_backreference_for_unicode_pattern => "invalid backreference in unicode pattern",
        .unrecognized_character_after_group_start => "unrecognized character after '(?'",
        .unmatched_parentheses => "unmatched parentheses",
        .incomplete_quantifier_for_unicode_pattern => "incomplete quantifier for unicode pattern",
        .invalid_quantifier => "invalid quantifier",
        .unmatched_bracket_for_unicode_pattern => "unmatched bracket for unicode pattern",
    };
}
