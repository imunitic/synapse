//! Versioned Vault-note schema validation.
//!
//! The schema document is parsed by `schema_yaml`; this module validates the
//! v1 DSL itself and interprets it against a Markdown note. Note frontmatter
//! is read independently of `frontmatter.parseTags`: declared fields accept
//! both flow and block YAML lists, while undeclared fields and body sections
//! remain open-world and are ignored.

const std = @import("std");
const schema_yaml = @import("schema_yaml.zig");
const schema_pattern = @import("schema_pattern.zig");

const Allocator = std.mem.Allocator;
const Value = schema_yaml.Value;

pub const Mode = enum { create, update, migration };

pub const Context = struct {
    mode: Mode,
    existing: ?[]const u8 = null,
    /// The already-existing identity found by the adapter's creation or
    /// migration-only vault scan, or null when the identity is unique.
    duplicate_identity: ?[]const u8 = null,
    projects_vocabulary: ?[]const u8 = null,
    tags_vocabulary: ?[]const u8 = null,
};

pub const FieldValue = union(enum) {
    string: []u8,
    integer: i64,
    boolean: bool,
    list: []const []u8,
    invalid,

    pub fn deinit(self: FieldValue, gpa: Allocator) void {
        switch (self) {
            .string => |s| gpa.free(s),
            .list => |items| {
                for (items) |item| gpa.free(item);
                gpa.free(items);
            },
            else => {},
        }
    }
};

pub const Lookup = struct {
    found: bool = false,
    duplicate: bool = false,
    value: FieldValue = .invalid,

    pub fn deinit(self: Lookup, gpa: Allocator) void {
        if (self.found) self.value.deinit(gpa);
    }
};

/// A zero-allocation root-frontmatter lookup used before a schema file is
/// known. Quoted and unquoted scalar identifiers are accepted; a list or
/// nested value is not a schema identifier.
pub fn schemaId(note: []const u8) ?[]const u8 {
    const bounds = frontmatterBounds(note) orelse return null;
    var lines = std.mem.splitScalar(u8, note[bounds.start..bounds.end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), "schema")) continue;
        const value = std.mem.trim(u8, stripTrailingComment(line[colon + 1 ..]), " ");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
            return value[1 .. value.len - 1];
        if (value.len == 0 or value[0] == '[' or value[0] == '{') return null;
        return value;
    }
    return null;
}

/// Checks the parsed schema document before it is allowed to interpret a
/// note. An unsupported key is an explicit schema error, never silently
/// skipped as though the validator understood it.
pub fn validateSchema(gpa: Allocator, root: *const Value, expected_id: []const u8) !?[]u8 {
    const top = switch (root.*) {
        .map => root,
        else => return try diag(gpa, "schema: document root must be a mapping", .{}),
    };
    if (try validateHeader(gpa, top, expected_id)) |message| return message;
    if (try validateFrontmatterRules(gpa, top)) |message| return message;
    if (try validateBodyRules(gpa, top)) |message| return message;
    if (try validateChecksRules(gpa, top)) |message| return message;
    return null;
}

fn validateHeader(gpa: Allocator, top: *const Value, expected_id: []const u8) !?[]u8 {
    const language = stringAt(top, "schema") orelse
        return try diag(gpa, "schema.schema: required string is missing", .{});
    if (!std.mem.eql(u8, language, "synapse-note-schema/v1"))
        return try diag(gpa, "schema.schema: unsupported language '{s}'", .{language});
    const id = stringAt(top, "id") orelse return try diag(gpa, "schema.id: required string is missing", .{});
    if (!std.mem.eql(u8, id, expected_id))
        return try diag(gpa, "schema.id: expected '{s}', found '{s}'", .{ expected_id, id });
    return null;
}

fn validateFrontmatterRules(gpa: Allocator, top: *const Value) !?[]u8 {
    const frontmatter = mapAt(top, "frontmatter") orelse
        return try diag(gpa, "schema.frontmatter: required mapping is missing", .{});
    if (unknownKey(frontmatter, &.{"fields"})) |key|
        return try diag(gpa, "schema.frontmatter.{s}: unsupported v1 key", .{key});
    const fields = mapAt(frontmatter, "fields") orelse
        return try diag(gpa, "schema.frontmatter.fields: required mapping is missing", .{});
    for (fields.map) |field| {
        if (try validateFieldRule(gpa, field.key, field.value)) |message| return message;
    }
    return null;
}

fn validateFieldRule(gpa: Allocator, field: []const u8, rule: *const Value) !?[]u8 {
    if (rule.* != .map)
        return try diag(gpa, "schema.frontmatter.fields.{s}: must be a mapping", .{field});
    if (unknownKey(rule, &.{
        "type",     "required",  "const", "min_length", "pattern", "mutable", "format",
        "timezone", "update_on", "items", "enum",
    })) |key| return try diag(gpa, "schema.frontmatter.fields.{s}.{s}: unsupported v1 key", .{ field, key });
    const type_name = stringAt(rule, "type") orelse
        return try diag(gpa, "schema.frontmatter.fields.{s}.type: required string is missing", .{field});
    if (!oneOf(type_name, &.{ "string", "timestamp", "list", "integer", "boolean" }))
        return try diag(gpa, "schema.frontmatter.fields.{s}.type: unsupported type '{s}'", .{ field, type_name });
    if (rule.get("required")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.frontmatter.fields.{s}.required: must be boolean", .{field});
    if (rule.get("mutable")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.frontmatter.fields.{s}.mutable: must be boolean", .{field});
    if (rule.get("min_length")) |v| if (v.asInteger() == null)
        return try diag(gpa, "schema.frontmatter.fields.{s}.min_length: must be integer", .{field});
    if (rule.get("pattern")) |v| {
        const pattern = v.asString() orelse
            return try diag(gpa, "schema.frontmatter.fields.{s}.pattern: must be string", .{field});
        schema_pattern.validate(pattern) catch |err|
            return try diag(gpa, "schema.frontmatter.fields.{s}.pattern: {s}", .{ field, @errorName(err) });
    }
    if (rule.get("enum")) |v| if (!isStringList(v))
        return try diag(gpa, "schema.frontmatter.fields.{s}.enum: must be a string list", .{field});
    if (std.mem.eql(u8, type_name, "list")) {
        const items = stringAt(rule, "items") orelse
            return try diag(gpa, "schema.frontmatter.fields.{s}.items: required string is missing", .{field});
        if (!std.mem.eql(u8, items, "string"))
            return try diag(gpa, "schema.frontmatter.fields.{s}.items: only string is supported in v1", .{field});
    }
    return null;
}

fn validateBodyRules(gpa: Allocator, top: *const Value) !?[]u8 {
    const body = mapAt(top, "body") orelse return try diag(gpa, "schema.body: required mapping is missing", .{});
    if (unknownKey(body, &.{ "h1", "preamble", "sections", "section_order", "lead", "checklist" })) |key|
        return try diag(gpa, "schema.body.{s}: unsupported v1 key", .{key});
    const h1 = mapAt(body, "h1") orelse return try diag(gpa, "schema.body.h1: required mapping is missing", .{});
    if (unknownKey(h1, &.{ "required", "count", "equals" })) |key|
        return try diag(gpa, "schema.body.h1.{s}: unsupported v1 key", .{key});
    if (body.get("sections")) |sections| {
        const list = switch (sections.*) {
            .list => |v| v,
            else => return try diag(gpa, "schema.body.sections: must be a list", .{}),
        };
        for (list, 0..) |section, i| if (try validateSectionRule(gpa, section, i)) |message| return message;
    }
    if (body.get("preamble")) |preamble| {
        if (!isMapList(preamble)) return try diag(gpa, "schema.body.preamble: must be a list of mappings", .{});
        for (preamble.list, 0..) |rule, i| {
            if (unknownKey(rule, &.{ "type", "required", "position", "pattern" })) |key|
                return try diag(gpa, "schema.body.preamble[{d}].{s}: unsupported v1 key", .{ i, key });
            if (stringAt(rule, "pattern")) |pattern| schema_pattern.validate(pattern) catch |err|
                return try diag(gpa, "schema.body.preamble[{d}].pattern: {s}", .{ i, @errorName(err) });
        }
    }
    if (body.get("lead")) |lead| {
        if (unknownKey(lead, &.{ "type", "required", "position" })) |key|
            return try diag(gpa, "schema.body.lead.{s}: unsupported v1 key", .{key});
    }
    if (body.get("checklist")) |checklist| {
        if (unknownKey(checklist, &.{ "required", "min_items", "position", "nested_items", "allowed_children" })) |key|
            return try diag(gpa, "schema.body.checklist.{s}: unsupported v1 key", .{key});
        if (checklist.get("allowed_children")) |allowed| if (!isStringList(allowed))
            return try diag(gpa, "schema.body.checklist.allowed_children: must be a string list", .{});
    }
    return null;
}

fn validateChecksRules(gpa: Allocator, top: *const Value) !?[]u8 {
    const checks = switch ((top.get("checks") orelse return try diag(gpa, "schema.checks: required list is missing", .{})).*) {
        .list => |v| v,
        else => return try diag(gpa, "schema.checks: must be a list", .{}),
    };
    for (checks, 0..) |check, i| {
        if (try validateCheckRule(gpa, check, i)) |message| return message;
    }
    return null;
}

fn validateCheckRule(gpa: Allocator, check: *const Value, index: usize) !?[]u8 {
    if (unknownKey(check, &.{ "equals", "unique", "when", "vocabulary", "not_before", "const" })) |key|
        return try diag(gpa, "schema.checks[{d}].{s}: unsupported v1 key", .{ index, key });
    var operators: usize = 0;
    for ([_][]const u8{ "equals", "unique", "vocabulary", "not_before", "const" }) |name| {
        if (check.get(name) != null) operators += 1;
    }
    if (operators != 1) return try diag(gpa, "schema.checks[{d}]: exactly one check operator is required", .{index});
    if (check.get("when")) |when| if (when.asString() == null)
        return try diag(gpa, "schema.checks[{d}].when: must be string", .{index});
    if (check.get("unique")) |unique| if (unique.asString() == null)
        return try diag(gpa, "schema.checks[{d}].unique: must be a field reference", .{index});
    if (check.get("not_before")) |refs| if (!isStringList(refs) or refs.list.len != 2)
        return try diag(gpa, "schema.checks[{d}].not_before: must contain two field references", .{index});
    if (check.get("vocabulary")) |vocabulary| {
        if (unknownKey(vocabulary, &.{ "field", "source", "projection" })) |key|
            return try diag(gpa, "schema.checks[{d}].vocabulary.{s}: unsupported v1 key", .{ index, key });
        if (stringAt(vocabulary, "field") == null or stringAt(vocabulary, "source") == null)
            return try diag(gpa, "schema.checks[{d}].vocabulary: field and source strings are required", .{index});
    }
    if (check.get("equals")) |equals| switch (equals.*) {
        .list => if (!isStringList(equals) or equals.list.len < 2)
            return try diag(gpa, "schema.checks[{d}].equals: must contain at least two references", .{index}),
        .map => {
            if (unknownKey(equals, &.{ "values", "when" })) |key|
                return try diag(gpa, "schema.checks[{d}].equals.{s}: unsupported v1 key", .{ index, key });
            const values = equals.get("values") orelse
                return try diag(gpa, "schema.checks[{d}].equals.values: required list is missing", .{index});
            if (!isStringList(values) or values.list.len < 2)
                return try diag(gpa, "schema.checks[{d}].equals.values: must contain at least two references", .{index});
        },
        else => return try diag(gpa, "schema.checks[{d}].equals: must be a list or mapping", .{index}),
    };
    if (check.get("const")) |constant| {
        if (unknownKey(constant, &.{ "field", "value", "when" })) |key|
            return try diag(gpa, "schema.checks[{d}].const.{s}: unsupported v1 key", .{ index, key });
        if (stringAt(constant, "field") == null or stringAt(constant, "value") == null)
            return try diag(gpa, "schema.checks[{d}].const: field and value strings are required", .{index});
    }
    return null;
}

pub fn validateNote(
    gpa: Allocator,
    schema: *const Value,
    note: []const u8,
    path: []const u8,
    context: Context,
) !?[]u8 {
    if (frontmatterBounds(note) == null) return try diag(gpa, "frontmatter: opening and closing delimiters are required", .{});
    const fields = schema.get("frontmatter").?.get("fields").?;

    for (fields.map) |field| {
        const rule = field.value;
        var lookup = try lookupField(gpa, note, field.key);
        defer lookup.deinit(gpa);
        if (lookup.duplicate) return try diag(gpa, "frontmatter.{s}: field occurs more than once", .{field.key});
        const required = boolAt(rule, "required") orelse false;
        if (!lookup.found) {
            if (required) return try diag(gpa, "frontmatter.{s}: required field is missing", .{field.key});
            continue;
        }
        const type_name = stringAt(rule, "type").?;
        if (!fieldHasType(lookup.value, type_name))
            return try diag(gpa, "frontmatter.{s}: expected {s}", .{ field.key, type_name });
        if (scalarString(lookup.value)) |value| {
            if (stringAt(rule, "const")) |want| if (!std.mem.eql(u8, value, want))
                return try diag(gpa, "frontmatter.{s}: expected '{s}'", .{ field.key, want });
            if (rule.get("min_length")) |v| if (value.len < @as(usize, @intCast(v.integer)))
                return try diag(gpa, "frontmatter.{s}: must not be empty", .{field.key});
            if (stringAt(rule, "pattern")) |pattern| if (!try schema_pattern.isMatch(pattern, value))
                return try diag(gpa, "frontmatter.{s}: does not match required pattern", .{field.key});
            if (rule.get("enum")) |v| if (!stringInValueList(value, v))
                return try diag(gpa, "frontmatter.{s}: value '{s}' is not allowed", .{ field.key, value });
            if (std.mem.eql(u8, type_name, "timestamp") and !validTimestamp(value))
                return try diag(gpa, "frontmatter.{s}: expected YYYY-MM-dd HH:mm:ss TZ in local time", .{field.key});
        }
        if (std.mem.eql(u8, type_name, "list")) switch (lookup.value) {
            .list => {},
            else => unreachable,
        };

        if (context.existing) |existing| if (context.mode != .create and boolAt(rule, "mutable") == false) {
            var old = try lookupField(gpa, existing, field.key);
            defer old.deinit(gpa);
            if (!old.found or !fieldValuesEqual(old.value, lookup.value))
                return try diag(gpa, "frontmatter.{s}: field is immutable", .{field.key});
        };
    }

    if (try validateBody(gpa, schema.get("body").?, note, path)) |message| return message;
    if (try validateChecks(gpa, schema.get("checks").?, note, path, context)) |message| return message;
    return null;
}

fn validateSectionRule(gpa: Allocator, section: *const Value, index: usize) !?[]u8 {
    if (unknownKey(section, &.{
        "title",      "level",         "required", "non_empty", "max_occurs", "content", "children",
        "repeatable", "title_pattern",
    })) |key| return try diag(gpa, "schema.body.sections[{d}].{s}: unsupported v1 key", .{ index, key });
    if (section.get("title") == null and section.get("title_pattern") == null)
        return try diag(gpa, "schema.body.sections[{d}]: title or title_pattern is required", .{index});
    if (section.get("level")) |v| if (v.asInteger() == null)
        return try diag(gpa, "schema.body.sections[{d}].level: must be integer", .{index});
    if (section.get("title_pattern")) |v| {
        const pattern = v.asString() orelse
            return try diag(gpa, "schema.body.sections[{d}].title_pattern: must be string", .{index});
        schema_pattern.validate(pattern) catch |err|
            return try diag(gpa, "schema.body.sections[{d}].title_pattern: {s}", .{ index, @errorName(err) });
    }
    if (section.get("content")) |content| {
        if (unknownKey(content, &.{ "type", "enum" })) |key|
            return try diag(gpa, "schema.body.sections[{d}].content.{s}: unsupported v1 key", .{ index, key });
        if (content.get("enum")) |allowed| if (!isStringList(allowed))
            return try diag(gpa, "schema.body.sections[{d}].content.enum: must be a string list", .{index});
    }
    if (section.get("children")) |children| {
        const list = switch (children.*) {
            .list => |v| v,
            else => return try diag(gpa, "schema.body.sections[{d}].children: must be a list", .{index}),
        };
        for (list, 0..) |child, child_i| if (try validateSectionRule(gpa, child, child_i)) |message| return message;
    }
    return null;
}

const Heading = struct {
    level: usize,
    title: []const u8,
    line_start: usize,
    content_start: usize,
    content_end: usize,
};

fn validateBody(gpa: Allocator, body_rule: *const Value, note: []const u8, path: []const u8) !?[]u8 {
    const bounds = frontmatterBounds(note).?;
    const markdown = note[bounds.after..];
    const headings = try collectHeadings(gpa, markdown);
    defer gpa.free(headings);

    var h1_count: usize = 0;
    var h1: ?Heading = null;
    for (headings) |heading| if (heading.level == 1) {
        h1_count += 1;
        if (h1 == null) h1 = heading;
    };
    const h1_rule = body_rule.get("h1").?;
    const wanted_count: usize = @intCast(integerAt(h1_rule, "count") orelse 1);
    if (h1_count != wanted_count) return try diag(gpa, "body.h1: expected {d}, found {d}", .{ wanted_count, h1_count });
    if (h1 == null) return try diag(gpa, "body.h1: required heading is missing", .{});
    const title = try requiredScalar(gpa, note, "title");
    defer gpa.free(title);
    if (!std.mem.eql(u8, h1.?.title, title))
        return try diag(gpa, "body.h1: must equal frontmatter.title", .{});

    if (body_rule.get("preamble")) |preamble| {
        for (preamble.list) |rule| {
            if (try validatePreamble(gpa, rule, markdown, h1.?)) |message| return message;
        }
    }

    var previous_known: usize = 0;
    var have_previous = false;
    if (body_rule.get("sections")) |sections_value| for (sections_value.list) |section_rule| {
        const title_rule = stringAt(section_rule, "title") orelse continue;
        const level: usize = @intCast(integerAt(section_rule, "level") orelse 2);
        var found: ?Heading = null;
        var count: usize = 0;
        for (headings) |heading| if (heading.level == level and std.mem.eql(u8, heading.title, title_rule)) {
            count += 1;
            if (found == null) found = heading;
        };
        if ((boolAt(section_rule, "required") orelse false) and count == 0)
            return try diag(gpa, "body.section.{s}: required heading is missing", .{title_rule});
        const max_occurs: usize = @intCast(integerAt(section_rule, "max_occurs") orelse 1);
        if (count > max_occurs) return try diag(gpa, "body.section.{s}: occurs {d} times; maximum is {d}", .{ title_rule, count, max_occurs });
        if (found) |heading| {
            if (have_previous and heading.line_start < previous_known)
                return try diag(gpa, "body.section.{s}: declared sections are out of relative order", .{title_rule});
            previous_known = heading.line_start;
            have_previous = true;
            const content = std.mem.trim(u8, markdown[heading.content_start..heading.content_end], " \t\r\n");
            if ((boolAt(section_rule, "non_empty") orelse false) and content.len == 0)
                return try diag(gpa, "body.section.{s}: must not be empty", .{title_rule});
            if (section_rule.get("content")) |content_rule| if (content_rule.get("enum")) |allowed| {
                if (!stringInValueList(content, allowed))
                    return try diag(gpa, "body.section.{s}: content '{s}' is not allowed", .{ title_rule, content });
            };
            if (section_rule.get("children")) |children| {
                for (children.list) |child| if (try validateChildRule(gpa, child, headings, markdown, heading)) |message| return message;
            }
        }
    };

    if (body_rule.get("lead") != null or body_rule.get("checklist") != null) {
        if (try validateTaskLeadAndChecklist(gpa, body_rule, markdown, h1.?)) |message| return message;
    }

    _ = path;
    return null;
}

fn validatePreamble(gpa: Allocator, rule: *const Value, markdown: []const u8, h1: Heading) !?[]u8 {
    const pattern = stringAt(rule, "pattern") orelse return null;
    var first_nonempty: ?[]const u8 = null;
    var offset = h1.content_start;
    while (offset < h1.content_end) {
        const end = std.mem.indexOfScalarPos(u8, markdown, offset, '\n') orelse markdown.len;
        const line = std.mem.trim(u8, markdown[offset..end], " \t\r");
        if (line.len != 0) {
            first_nonempty = line;
            break;
        }
        offset = @min(end + 1, markdown.len);
    }
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "> Compiled task:")) continue;
        if (first_nonempty == null or !std.mem.eql(u8, line, first_nonempty.?))
            return try diag(gpa, "body.preamble: compiled-task backlink must immediately follow H1", .{});
        if (!try schema_pattern.isMatch(pattern, line))
            return try diag(gpa, "body.preamble: compiled-task backlink is malformed", .{});
    }
    return null;
}

fn validateChildRule(
    gpa: Allocator,
    rule: *const Value,
    headings: []const Heading,
    markdown: []const u8,
    parent: Heading,
) !?[]u8 {
    const level: usize = if (integerAt(rule, "level")) |configured| @intCast(configured) else parent.level + 1;
    const title = stringAt(rule, "title");
    const title_pattern = stringAt(rule, "title_pattern");
    var count: usize = 0;
    for (headings) |heading| {
        if (heading.line_start <= parent.line_start or heading.line_start >= parent.content_end or heading.level != level) continue;
        const matches = if (title) |want|
            std.mem.eql(u8, heading.title, want)
        else if (title_pattern) |pattern|
            try schema_pattern.isMatch(pattern, heading.title)
        else
            false;
        if (!matches) {
            if (title_pattern != null)
                return try diag(gpa, "body.section.{s}: child heading '{s}' has an invalid title", .{ parent.title, heading.title });
            continue;
        }
        count += 1;
        const content = std.mem.trim(u8, markdown[heading.content_start..heading.content_end], " \t\r\n");
        if ((boolAt(rule, "non_empty") orelse false) and content.len == 0)
            return try diag(gpa, "body.section.{s}.{s}: must not be empty", .{ parent.title, heading.title });
    }
    if ((boolAt(rule, "required") orelse false) and count == 0)
        return try diag(gpa, "body.section.{s}: required child heading is missing", .{parent.title});
    if (!(boolAt(rule, "repeatable") orelse false) and count > 1)
        return try diag(gpa, "body.section.{s}: child heading occurs more than once", .{parent.title});
    return null;
}

fn validateTaskLeadAndChecklist(gpa: Allocator, body_rule: *const Value, markdown: []const u8, h1: Heading) !?[]u8 {
    var lines = std.mem.splitScalar(u8, markdown[h1.content_start..h1.content_end], '\n');
    var have_lead = false;
    var checklist_count: usize = 0;
    var seen_checklist = false;
    var in_fence = false;
    while (lines.next()) |raw_with_cr| {
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (raw.len == trimmed.len and std.mem.startsWith(u8, raw, "## ")) break;
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence or trimmed.len == 0) continue;
        const is_item = isChecklistLine(trimmed);
        if (is_item) {
            if (raw.len != trimmed.len)
                return try diag(gpa, "body.checklist: nested checklist items are not allowed", .{});
            checklist_count += 1;
            seen_checklist = true;
            continue;
        }
        if (!seen_checklist and !std.mem.startsWith(u8, trimmed, "#") and !std.mem.startsWith(u8, trimmed, ">"))
            have_lead = true;
    }
    if (body_rule.get("lead")) |lead| if ((boolAt(lead, "required") orelse false) and !have_lead)
        return try diag(gpa, "body.lead: prose before the checklist is required", .{});
    if (body_rule.get("checklist")) |checklist| {
        const min_items: usize = if (integerAt(checklist, "min_items")) |configured|
            @intCast(configured)
        else if (boolAt(checklist, "required") orelse false)
            1
        else
            0;
        if (checklist_count < min_items)
            return try diag(gpa, "body.checklist: expected at least {d} flat item(s), found {d}", .{ min_items, checklist_count });
    }
    return null;
}

fn validateChecks(gpa: Allocator, checks: *const Value, note: []const u8, path: []const u8, context: Context) !?[]u8 {
    for (checks.list) |check| {
        if (check.get("unique")) |unique| {
            if ((context.mode == .create or context.mode == .migration) and context.duplicate_identity != null)
                return try diag(gpa, "{s}: identity '{s}' already exists", .{ unique.string, context.duplicate_identity.? });
            continue;
        }
        if (check.get("vocabulary")) |vocab| {
            const field_ref = stringAt(vocab, "field") orelse continue;
            const source = stringAt(vocab, "source") orelse continue;
            if (!std.mem.startsWith(u8, field_ref, "frontmatter.")) continue;
            const field_name = field_ref["frontmatter.".len..];
            var lookup = try lookupField(gpa, note, field_name);
            defer lookup.deinit(gpa);
            const vocabulary = if (std.mem.eql(u8, source, "synapse-projects.conf"))
                context.projects_vocabulary
            else if (std.mem.eql(u8, source, "synapse-tag-vocabulary.conf"))
                context.tags_vocabulary
            else
                null;
            if (vocabulary == null) return try diag(gpa, "{s}: vocabulary source '{s}' is unavailable", .{ field_ref, source });
            const projection_values = std.mem.eql(u8, stringAt(vocab, "projection") orelse "", "values");
            switch (lookup.value) {
                .string => |value| if (!vocabularyContains(vocabulary.?, value, projection_values))
                    return try diag(gpa, "{s}: '{s}' is not in {s}", .{ field_ref, value, source }),
                .list => |items| for (items) |item| if (!vocabularyContains(vocabulary.?, item, projection_values))
                    return try diag(gpa, "{s}: '{s}' is not in {s}", .{ field_ref, item, source }),
                else => {},
            }
            continue;
        }
        if (check.get("not_before")) |values| {
            const left = try resolveRef(gpa, note, path, values.list[0].string);
            defer gpa.free(left);
            const right = try resolveRef(gpa, note, path, values.list[1].string);
            defer gpa.free(right);
            if (left.len >= 19 and right.len >= 19 and std.mem.lessThan(u8, left[0..19], right[0..19]))
                return try diag(gpa, "{s}: must not precede {s}", .{ values.list[0].string, values.list[1].string });
            continue;
        }
        if (check.get("equals")) |equals| {
            const when = stringAt(check, "when") orelse if (equals.* == .map) stringAt(equals, "when") else null;
            if (when != null and std.mem.eql(u8, when.?, "create") and context.mode != .create) continue;
            const values = if (equals.* == .list) equals else equals.get("values") orelse continue;
            if (values.list.len < 2) continue;
            const first = try resolveRef(gpa, note, path, values.list[0].string);
            defer gpa.free(first);
            for (values.list[1..]) |ref| {
                const other = try resolveRef(gpa, note, path, ref.string);
                defer gpa.free(other);
                if (!std.mem.eql(u8, first, other))
                    return try diag(gpa, "{s}: must equal {s}", .{ values.list[0].string, ref.string });
            }
            continue;
        }
        if (check.get("const")) |constant| {
            const when = stringAt(check, "when") orelse stringAt(constant, "when");
            if (when != null and std.mem.eql(u8, when.?, "create") and context.mode != .create) continue;
            const field_ref = stringAt(constant, "field") orelse continue;
            const want = stringAt(constant, "value") orelse continue;
            const got = try resolveRef(gpa, note, path, field_ref);
            defer gpa.free(got);
            if (!std.mem.eql(u8, got, want)) return try diag(gpa, "{s}: must equal '{s}' on creation", .{ field_ref, want });
        }
    }
    return null;
}

pub fn lookupField(gpa: Allocator, note: []const u8, wanted: []const u8) !Lookup {
    const bounds = frontmatterBounds(note) orelse return .{};
    var result: Lookup = .{};
    var lines = std.mem.splitScalar(u8, note[bounds.start..bounds.end], '\n');
    while (lines.next()) |raw_with_cr| {
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t' or raw[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const key = std.mem.trim(u8, raw[0..colon], " ");
        if (!std.mem.eql(u8, key, wanted)) continue;
        if (result.found) {
            result.duplicate = true;
            continue;
        }
        result.found = true;
        const raw_value = std.mem.trim(u8, stripTrailingComment(raw[colon + 1 ..]), " ");
        if (raw_value.len == 0) {
            var items: std.ArrayListUnmanaged([]u8) = .empty;
            while (lines.next()) |child_raw_with_cr| {
                const child_raw = std.mem.trimEnd(u8, child_raw_with_cr, "\r");
                if (child_raw.len == 0 or std.mem.trim(u8, child_raw, " ").len == 0) continue;
                if (child_raw[0] != ' ' and child_raw[0] != '\t') break;
                const child = std.mem.trim(u8, child_raw, " ");
                if (!std.mem.startsWith(u8, child, "- ")) {
                    result.value = .invalid;
                    return result;
                }
                try items.append(gpa, try dupeUnquoted(gpa, std.mem.trim(u8, stripTrailingComment(child[2..]), " ")));
            }
            result.value = .{ .list = try items.toOwnedSlice(gpa) };
            return result;
        }
        if (raw_value[0] == '[') {
            if (raw_value[raw_value.len - 1] != ']') {
                result.value = .invalid;
                continue;
            }
            result.value = .{ .list = try parseFlowStringList(gpa, raw_value) };
            continue;
        }
        if ((raw_value[0] == '\'' or raw_value[0] == '"') and
            (raw_value.len < 2 or raw_value[raw_value.len - 1] != raw_value[0]))
        {
            result.value = .invalid;
            continue;
        }
        if (std.mem.eql(u8, raw_value, "true")) {
            result.value = .{ .boolean = true };
        } else if (std.mem.eql(u8, raw_value, "false")) {
            result.value = .{ .boolean = false };
        } else if (parseDecimal(raw_value)) |number| {
            result.value = .{ .integer = number };
        } else {
            result.value = .{ .string = try dupeUnquoted(gpa, raw_value) };
        }
    }
    return result;
}

const Bounds = struct { start: usize, end: usize, after: usize };

fn frontmatterBounds(note: []const u8) ?Bounds {
    if (!std.mem.startsWith(u8, note, "---\n") and !std.mem.startsWith(u8, note, "---\r\n")) return null;
    const first_nl = std.mem.indexOfScalar(u8, note, '\n') orelse return null;
    var offset = first_nl + 1;
    while (offset <= note.len) {
        const end = std.mem.indexOfScalarPos(u8, note, offset, '\n') orelse note.len;
        const line = std.mem.trim(u8, note[offset..end], "\r");
        if (std.mem.eql(u8, line, "---")) return .{
            .start = first_nl + 1,
            .end = offset,
            .after = @min(end + 1, note.len),
        };
        if (end == note.len) break;
        offset = end + 1;
    }
    return null;
}

fn collectHeadings(gpa: Allocator, markdown: []const u8) ![]Heading {
    var headings: std.ArrayListUnmanaged(Heading) = .empty;
    var offset: usize = 0;
    var in_fence = false;
    while (offset <= markdown.len) {
        const end = std.mem.indexOfScalarPos(u8, markdown, offset, '\n') orelse markdown.len;
        const line = std.mem.trimEnd(u8, markdown[offset..end], "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
        } else if (!in_fence and line.len == trimmed.len) {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            if (level >= 1 and level <= 6 and level < line.len and line[level] == ' ') {
                try headings.append(gpa, .{
                    .level = level,
                    .title = std.mem.trim(u8, line[level + 1 ..], " \t"),
                    .line_start = offset,
                    .content_start = @min(end + 1, markdown.len),
                    .content_end = markdown.len,
                });
            }
        }
        if (end == markdown.len) break;
        offset = end + 1;
    }
    for (headings.items, 0..) |*heading, i| {
        for (headings.items[i + 1 ..]) |next| if (next.level <= heading.level) {
            heading.content_end = next.line_start;
            break;
        };
    }
    return headings.toOwnedSlice(gpa);
}

fn resolveRef(gpa: Allocator, note: []const u8, path: []const u8, ref: []const u8) ![]u8 {
    if (std.mem.eql(u8, ref, "filename.stem")) return gpa.dupe(u8, filenameStem(path));
    if (!std.mem.startsWith(u8, ref, "frontmatter.")) return gpa.dupe(u8, "");
    const field = ref["frontmatter.".len..];
    var lookup = try lookupField(gpa, note, field);
    defer lookup.deinit(gpa);
    return switch (lookup.value) {
        .string => |s| gpa.dupe(u8, s),
        else => gpa.dupe(u8, ""),
    };
}

fn requiredScalar(gpa: Allocator, note: []const u8, field: []const u8) ![]u8 {
    var lookup = try lookupField(gpa, note, field);
    defer lookup.deinit(gpa);
    return switch (lookup.value) {
        .string => |s| gpa.dupe(u8, s),
        else => gpa.dupe(u8, ""),
    };
}

fn filenameStem(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse 0;
    const base = if (slash == 0 and (path.len == 0 or (path[0] != '/' and path[0] != '\\'))) path else path[slash + 1 ..];
    return if (std.mem.endsWith(u8, base, ".md")) base[0 .. base.len - 3] else base;
}

fn parseFlowStringList(gpa: Allocator, raw: []const u8) ![]const []u8 {
    if (raw.len < 2 or raw[raw.len - 1] != ']') return gpa.alloc([]u8, 0);
    const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " ");
    var items: std.ArrayListUnmanaged([]u8) = .empty;
    if (inner.len == 0) return items.toOwnedSlice(gpa);
    var quote: ?u8 = null;
    var start: usize = 0;
    for (inner, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') quote = c else if (c == ',') {
            try items.append(gpa, try dupeUnquoted(gpa, std.mem.trim(u8, inner[start..i], " ")));
            start = i + 1;
        }
    }
    try items.append(gpa, try dupeUnquoted(gpa, std.mem.trim(u8, inner[start..], " ")));
    return items.toOwnedSlice(gpa);
}

fn dupeUnquoted(gpa: Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"') and raw[raw.len - 1] == raw[0])
        return gpa.dupe(u8, raw[1 .. raw.len - 1]);
    return gpa.dupe(u8, raw);
}

fn stripTrailingComment(raw: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (raw, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '#' and (i == 0 or std.ascii.isWhitespace(raw[i - 1]))) {
            return raw[0..i];
        }
    }
    return raw;
}

fn parseDecimal(raw: []const u8) ?i64 {
    if (raw.len == 0) return null;
    var i: usize = if (raw[0] == '-') 1 else 0;
    if (i == raw.len) return null;
    while (i < raw.len) : (i += 1) if (!std.ascii.isDigit(raw[i])) return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn validTimestamp(value: []const u8) bool {
    if (value.len < 23) return false;
    const digits = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (digits) |i| if (!std.ascii.isDigit(value[i])) return false;
    if (value[4] != '-' or value[7] != '-' or value[10] != ' ' or value[13] != ':' or value[16] != ':' or value[19] != ' ') return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return false;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return false;
    for (value[20..]) |c| if (!std.ascii.isAlphabetic(c) and c != '+' and c != '-' and !std.ascii.isDigit(c)) return false;
    return true;
}

fn vocabularyContains(text: []const u8, wanted: []const u8, projection_values: bool) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripTrailingComment(raw), " \t\r");
        if (line.len == 0) continue;
        const candidate = if (projection_values) blk: {
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            break :blk std.mem.trim(u8, line[equals + 1 ..], " \t");
        } else line;
        if (std.mem.eql(u8, candidate, wanted)) return true;
    }
    return false;
}

fn fieldHasType(value: FieldValue, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "string") or std.mem.eql(u8, type_name, "timestamp"))
        return value == .string;
    if (std.mem.eql(u8, type_name, "list")) return value == .list;
    if (std.mem.eql(u8, type_name, "integer")) return value == .integer;
    if (std.mem.eql(u8, type_name, "boolean")) return value == .boolean;
    return false;
}

fn fieldValuesEqual(a: FieldValue, b: FieldValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .integer => |n| n == b.integer,
        .boolean => |v| v == b.boolean,
        .list => |items| blk: {
            if (items.len != b.list.len) break :blk false;
            for (items, b.list) |left, right| if (!std.mem.eql(u8, left, right)) break :blk false;
            break :blk true;
        },
        .invalid => true,
    };
}

fn scalarString(value: FieldValue) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn isChecklistLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "- [ ] ") or std.mem.startsWith(u8, line, "- [x] ") or std.mem.startsWith(u8, line, "- [X] ");
}

fn unknownKey(value: *const Value, allowed: []const []const u8) ?[]const u8 {
    const entries = switch (value.*) {
        .map => |v| v,
        else => return "<non-mapping>",
    };
    for (entries) |entry| if (!oneOf(entry.key, allowed)) return entry.key;
    return null;
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn isStringList(value: *const Value) bool {
    return switch (value.*) {
        .list => |items| for (items) |item| {
            if (item.asString() == null) break false;
        } else true,
        else => false,
    };
}

fn isMapList(value: *const Value) bool {
    return switch (value.*) {
        .list => |items| for (items) |item| {
            if (item.* != .map) break false;
        } else true,
        else => false,
    };
}

fn mapAt(value: *const Value, key: []const u8) ?*const Value {
    const child = value.get(key) orelse return null;
    return if (child.* == .map) child else null;
}

fn stringAt(value: *const Value, key: []const u8) ?[]const u8 {
    return (value.get(key) orelse return null).asString();
}

fn boolAt(value: *const Value, key: []const u8) ?bool {
    return (value.get(key) orelse return null).asBool();
}

fn integerAt(value: *const Value, key: []const u8) ?i64 {
    return (value.get(key) orelse return null).asInteger();
}

fn stringInValueList(value: []const u8, list: *const Value) bool {
    return switch (list.*) {
        .list => |items| for (items) |item| {
            if (std.mem.eql(u8, value, item.asString() orelse continue)) break true;
        } else false,
        else => false,
    };
}

fn diag(gpa: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(gpa, fmt, args);
}

const testing = std.testing;

const bare_schema =
    "schema: synapse-note-schema/v1\n" ++
    "id: vault-note/v1\n" ++
    "frontmatter:\n" ++
    "  fields:\n" ++
    "    schema:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "      const: vault-note/v1\n" ++
    "    title:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "      min_length: 1\n" ++
    "    note_id:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "      pattern: '^[a-z][a-z0-9-]*-[0-9]{3,}$'\n" ++
    "      mutable: false\n" ++
    "    created:\n" ++
    "      type: timestamp\n" ++
    "      required: true\n" ++
    "      mutable: false\n" ++
    "    updated:\n" ++
    "      type: timestamp\n" ++
    "      required: true\n" ++
    "    tags:\n" ++
    "      type: list\n" ++
    "      required: true\n" ++
    "      items: string\n" ++
    "body:\n" ++
    "  h1:\n" ++
    "    required: true\n" ++
    "    count: 1\n" ++
    "    equals: frontmatter.title\n" ++
    "  sections:\n" ++
    "    - title: Summary\n" ++
    "      level: 2\n" ++
    "      required: true\n" ++
    "  section_order: relative\n" ++
    "checks:\n" ++
    "  - equals: [filename.stem, frontmatter.title]\n" ++
    "  - unique: frontmatter.note_id\n" ++
    "    when: create\n" ++
    "  - vocabulary:\n" ++
    "      field: frontmatter.tags\n" ++
    "      source: synapse-tag-vocabulary.conf\n" ++
    "  - not_before: [frontmatter.updated, frontmatter.created]\n" ++
    "  - equals:\n" ++
    "      values: [frontmatter.created, frontmatter.updated]\n" ++
    "      when: create\n";

test "validates a bare note with flow-style tags" {
    var doc = try schema_yaml.parse(testing.allocator, bare_schema);
    defer doc.deinit();
    try testing.expectEqual(@as(?[]u8, null), try validateSchema(testing.allocator, doc.root, "vault-note/v1"));
    const note =
        "---\n" ++
        "schema: vault-note/v1\n" ++
        "title: Example\n" ++
        "note_id: sb-081\n" ++
        "created: '2026-08-30 10:00:00 CEST'\n" ++
        "updated: '2026-08-30 10:00:00 CEST'\n" ++
        "tags: [synapse, architecture]\n" ++
        "extra: preserved\n" ++
        "---\n\n# Example\n\n## Summary\nUseful.\n";
    try testing.expectEqual(@as(?[]u8, null), try validateNote(testing.allocator, doc.root, note, "research/Example.md", .{
        .mode = .create,
        .tags_vocabulary = "synapse\narchitecture\n",
    }));
}

test "block-style tags preserve empty versus missing" {
    const note = "---\ntags:\n  - synapse\n  - architecture\n---\n";
    var got = try lookupField(testing.allocator, note, "tags");
    defer got.deinit(testing.allocator);
    try testing.expect(got.found);
    try testing.expectEqual(@as(usize, 2), got.value.list.len);

    var empty = try lookupField(testing.allocator, "---\ntags:\n---\n", "tags");
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.found);
    try testing.expectEqual(@as(usize, 0), empty.value.list.len);

    var missing = try lookupField(testing.allocator, "---\ntitle: x\n---\n", "tags");
    defer missing.deinit(testing.allocator);
    try testing.expect(!missing.found);
}

test "immutable identity changes are rejected without a vault scan" {
    var doc = try schema_yaml.parse(testing.allocator, bare_schema);
    defer doc.deinit();
    const existing =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\ncreated: '2026-08-30 10:00:00 CEST'\nupdated: '2026-08-30 10:00:00 CEST'\ntags: []\n---\n# Example\n## Summary\nOld\n";
    const changed =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-999\ncreated: '2026-08-30 10:00:00 CEST'\nupdated: '2026-08-30 11:00:00 CEST'\ntags: []\n---\n# Example\n## Summary\nNew\n";
    const message = (try validateNote(testing.allocator, doc.root, changed, "research/Example.md", .{
        .mode = .update,
        .existing = existing,
        .tags_vocabulary = "",
    })).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("frontmatter.note_id: field is immutable", message);
}
