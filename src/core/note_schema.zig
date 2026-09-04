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
    if (try validateLintsRules(gpa, top)) |message| return message;
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
    if (unknownKey(frontmatter, &.{ "fields", "field_order" })) |key|
        return try diag(gpa, "schema.frontmatter.{s}: unsupported v1 key", .{key});
    if (frontmatter.get("field_order")) |v| {
        const order = v.asString() orelse
            return try diag(gpa, "schema.frontmatter.field_order: must be string", .{});
        if (!std.mem.eql(u8, order, "relative"))
            return try diag(gpa, "schema.frontmatter.field_order: unsupported value '{s}'", .{order});
    }
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
    if (!oneOf(type_name, &.{ "string", "timestamp", "list", "integer", "boolean", "any" }))
        return try diag(gpa, "schema.frontmatter.fields.{s}.type: unsupported type '{s}'", .{ field, type_name });
    if (rule.get("required")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.frontmatter.fields.{s}.required: must be boolean", .{field});
    if (rule.get("mutable")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.frontmatter.fields.{s}.mutable: must be boolean", .{field});
    if (rule.get("min_length")) |v| {
        const bound = v.asInteger() orelse
            return try diag(gpa, "schema.frontmatter.fields.{s}.min_length: must be integer", .{field});
        if (bound < 1)
            return try diag(gpa, "schema.frontmatter.fields.{s}.min_length: must be at least 1", .{field});
    }
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
    if (h1.get("count")) |v| {
        const count = v.asInteger() orelse
            return try diag(gpa, "schema.body.h1.count: must be integer", .{});
        if (count < 1) return try diag(gpa, "schema.body.h1.count: must be at least 1", .{});
    }
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
        if (lead.get("required")) |v| if (v.asBool() == null)
            return try diag(gpa, "schema.body.lead.required: must be boolean", .{});
    }
    if (body.get("checklist")) |checklist| {
        if (unknownKey(checklist, &.{ "required", "min_items", "position", "nested_items", "allowed_children" })) |key|
            return try diag(gpa, "schema.body.checklist.{s}: unsupported v1 key", .{key});
        if (checklist.get("required")) |v| if (v.asBool() == null)
            return try diag(gpa, "schema.body.checklist.required: must be boolean", .{});
        if (checklist.get("min_items")) |v| {
            const min = v.asInteger() orelse
                return try diag(gpa, "schema.body.checklist.min_items: must be integer", .{});
            if (min < 0) return try diag(gpa, "schema.body.checklist.min_items: must not be negative", .{});
        }
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

/// Unlike `checks`, optional: a schema with nothing worth linting declares
/// no `lints:` key at all, rather than an empty list.
fn validateLintsRules(gpa: Allocator, top: *const Value) !?[]u8 {
    const lints = top.get("lints") orelse return null;
    const list = switch (lints.*) {
        .list => |v| v,
        else => return try diag(gpa, "schema.lints: must be a list", .{}),
    };
    for (list, 0..) |rule, i| {
        if (try validateLintRule(gpa, rule, i)) |message| return message;
    }
    return null;
}

/// Only the two field references this v1 lint pass actually knows how to
/// read (`body.prose`, and `frontmatter.title`/`frontmatter.task_id`/
/// `frontmatter.note_id` for the id-prefix check) are accepted -- an
/// unsupported reference is refused at schema-load time rather than
/// silently matching nothing at lint time.
fn validateLintRule(gpa: Allocator, rule: *const Value, index: usize) !?[]u8 {
    if (unknownKey(rule, &.{ "no_hard_wrap", "no_id_prefix_in_title", "severity" })) |key|
        return try diag(gpa, "schema.lints[{d}].{s}: unsupported v1 key", .{ index, key });
    var operators: usize = 0;
    for ([_][]const u8{ "no_hard_wrap", "no_id_prefix_in_title" }) |name| {
        if (rule.get(name) != null) operators += 1;
    }
    if (operators != 1) return try diag(gpa, "schema.lints[{d}]: exactly one lint operator is required", .{index});
    const severity = stringAt(rule, "severity") orelse
        return try diag(gpa, "schema.lints[{d}].severity: required string is missing", .{index});
    // `error` is a real future value per the design (a rule promoted off
    // `warn` once real use shows zero false positives), but that promotion
    // moves a rule into the blocking `checks:` path entirely rather than
    // changing what this lint pass itself does with it -- accepting `error`
    // here today would silently do nothing differently, which is worse than
    // refusing it until the promotion mechanism actually exists.
    if (!std.mem.eql(u8, severity, "warn"))
        return try diag(gpa, "schema.lints[{d}].severity: unsupported value '{s}'", .{ index, severity });
    if (rule.get("no_hard_wrap")) |v| {
        const ref = v.asString() orelse
            return try diag(gpa, "schema.lints[{d}].no_hard_wrap: must be a field reference", .{index});
        if (!std.mem.eql(u8, ref, "body.prose"))
            return try diag(gpa, "schema.lints[{d}].no_hard_wrap: unsupported field reference '{s}'", .{ index, ref });
    }
    if (rule.get("no_id_prefix_in_title")) |cfg| {
        if (unknownKey(cfg, &.{ "title", "id" })) |key|
            return try diag(gpa, "schema.lints[{d}].no_id_prefix_in_title.{s}: unsupported v1 key", .{ index, key });
        const title_ref = stringAt(cfg, "title") orelse
            return try diag(gpa, "schema.lints[{d}].no_id_prefix_in_title.title: required field reference is missing", .{index});
        if (!std.mem.eql(u8, title_ref, "frontmatter.title"))
            return try diag(gpa, "schema.lints[{d}].no_id_prefix_in_title.title: unsupported field reference '{s}'", .{ index, title_ref });
        const id_ref = stringAt(cfg, "id") orelse
            return try diag(gpa, "schema.lints[{d}].no_id_prefix_in_title.id: required field reference is missing", .{index});
        if (!std.mem.eql(u8, id_ref, "frontmatter.task_id") and !std.mem.eql(u8, id_ref, "frontmatter.note_id"))
            return try diag(gpa, "schema.lints[{d}].no_id_prefix_in_title.id: unsupported field reference '{s}'", .{ index, id_ref });
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
    const bounds = frontmatterBounds(note) orelse
        return try diag(gpa, "frontmatter: opening and closing delimiters are required", .{});
    const frontmatter_rule = schema.get("frontmatter").?;
    const fields = frontmatter_rule.get("fields").?;
    const field_order_relative = if (frontmatter_rule.get("field_order")) |v|
        if (v.asString()) |s| std.mem.eql(u8, s, "relative") else false
    else
        false;

    var positions: ?[]FieldPos = null;
    defer if (positions) |p| gpa.free(p);
    var prev_line: usize = 0;
    var have_prev = false;

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
            if (rule.get("min_length")) |v| {
                const bound: usize = @intCast(v.integer);
                if (value.len < bound)
                    return try diag(gpa, "frontmatter.{s}: must be at least {d} characters", .{ field.key, bound });
            }
            if (stringAt(rule, "pattern")) |pattern| if (!try schema_pattern.isMatch(pattern, value))
                return try diag(gpa, "frontmatter.{s}: does not match required pattern", .{field.key});
            if (rule.get("enum")) |v| if (!stringInValueList(value, v))
                return try diag(gpa, "frontmatter.{s}: value '{s}' is not allowed", .{ field.key, value });
            if (std.mem.eql(u8, type_name, "timestamp") and !validTimestamp(value))
                return try diag(gpa, "frontmatter.{s}: expected YYYY-MM-dd HH:mm:ss TZ in local time", .{field.key});
        }

        if (context.existing) |existing| if (context.mode != .create and boolAt(rule, "mutable") == false) {
            var old = try lookupField(gpa, existing, field.key);
            defer old.deinit(gpa);
            if (!old.found or !fieldValuesEqual(old.value, lookup.value))
                return try diag(gpa, "frontmatter.{s}: field is immutable", .{field.key});
        };

        if (field_order_relative) {
            if (positions == null) positions = try collectFrontmatterFields(gpa, note, bounds);
            if (findFieldLine(positions.?, field.key)) |line_start| {
                if (have_prev and line_start < prev_line)
                    return try diag(gpa, "frontmatter.{s}: declared fields are out of relative order", .{field.key});
                prev_line = line_start;
                have_prev = true;
            }
        }
    }

    if (try validateBody(gpa, schema.get("body").?, note, path)) |message| return message;
    if (try validateChecks(gpa, schema.get("checks").?, note, path, context)) |message| return message;
    return null;
}

/// Advisory only: unlike `validateNote`, never returns an error that blocks
/// a write -- every finding is collected, none stop the pass early. Called
/// only after `validateNote` has already passed (a rejected write never
/// reaches lint), and only for a schema that declares `lints:` at all -- a
/// schema with none returns an empty slice, the same "nothing to say" shape
/// as a clean note.
pub fn lintNote(gpa: Allocator, schema: *const Value, note: []const u8, path: []const u8) ![]const []u8 {
    _ = path; // no rule needs it yet; kept for parity with validateNote and any future rule that does
    var findings: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (findings.items) |f| gpa.free(f);
        findings.deinit(gpa);
    }

    const lints = schema.get("lints") orelse return findings.toOwnedSlice(gpa);
    const bounds = frontmatterBounds(note) orelse return findings.toOwnedSlice(gpa);

    for (lints.list) |rule| {
        if (rule.get("no_hard_wrap")) |_| {
            const wrap_findings = try lintNoHardWrap(gpa, note, bounds.after);
            defer gpa.free(wrap_findings);
            for (wrap_findings) |f| try findings.append(gpa, f);
        }
        if (rule.get("no_id_prefix_in_title")) |cfg| {
            const id_ref = stringAt(cfg, "id").?;
            const id_field = id_ref["frontmatter.".len..];
            if (try lintNoIdPrefixInTitle(gpa, note, id_field)) |msg| try findings.append(gpa, msg);
        }
    }
    return findings.toOwnedSlice(gpa);
}

/// 1-based line number of `offset` within `note` -- a plain newline count,
/// cheap enough at lint-pass scale (one note, once per write) to not need
/// caching the way a hot path would.
fn lineNumber(note: []const u8, offset: usize) usize {
    var n: usize = 1;
    for (note[0..offset]) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

/// A line that never counts toward a hard-wrapped-paragraph run: blank, a
/// heading, a blockquote, a table row, a list item (ordered or unordered),
/// or indented (a list item's own continuation paragraph, or anything else
/// deliberately nested). Excludes exactly what the design's own
/// paragraph-boundary caveat names -- table rows, list continuations --
/// plus headings and blockquotes, which are single-line by construction and
/// would otherwise flush a run right before this line starts a wrong one.
fn isExcludedProseLine(raw_line: []const u8) bool {
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    if (line.len == 0) return true;
    if (line[0] == ' ' or line[0] == '\t') return true; // indented: nested/continuation content
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed[0] == '#' or trimmed[0] == '>' or trimmed[0] == '|') return true;
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ "))
        return true;
    if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) return true;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    if (i > 0 and i < trimmed.len and (trimmed[i] == '.' or trimmed[i] == ')') and
        i + 1 < trimmed.len and trimmed[i + 1] == ' ') return true; // ordered list item
    return false;
}

/// Closes the currently-open prose run, if any: a run of 2+ consecutive
/// non-excluded lines is exactly one paragraph split across lines -- the
/// hard-wrap shape this rule exists to catch. A run of exactly 1 line is
/// the correct, unwrapped shape and produces nothing.
fn flushProseRun(gpa: Allocator, findings: *std.ArrayListUnmanaged([]u8), note: []const u8, run_start: *?usize, run_lines: *usize) !void {
    if (run_lines.* > 1) {
        const msg = try std.fmt.allocPrint(
            gpa,
            "no_hard_wrap: paragraph wrapped across {d} lines starting at line {d}",
            .{ run_lines.*, lineNumber(note, run_start.*.?) },
        );
        try findings.append(gpa, msg);
    }
    run_start.* = null;
    run_lines.* = 0;
}

fn lintNoHardWrap(gpa: Allocator, note: []const u8, body_start: usize) ![]const []u8 {
    var findings: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (findings.items) |f| gpa.free(f);
        findings.deinit(gpa);
    }

    var in_fence = false;
    var run_start: ?usize = null;
    var run_lines: usize = 0;

    var offset = body_start;
    while (offset <= note.len) {
        const end = std.mem.indexOfScalarPos(u8, note, offset, '\n') orelse note.len;
        const line = note[offset..end];
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
        const is_fence_delimiter = std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");

        if (is_fence_delimiter) {
            try flushProseRun(gpa, &findings, note, &run_start, &run_lines);
            in_fence = !in_fence;
        } else if (in_fence) {
            try flushProseRun(gpa, &findings, note, &run_start, &run_lines);
        } else if (isExcludedProseLine(line)) {
            try flushProseRun(gpa, &findings, note, &run_start, &run_lines);
        } else {
            if (run_start == null) run_start = offset;
            run_lines += 1;
        }

        if (end == note.len) break;
        offset = end + 1;
    }
    try flushProseRun(gpa, &findings, note, &run_start, &run_lines);
    return findings.toOwnedSlice(gpa);
}

fn lintNoIdPrefixInTitle(gpa: Allocator, note: []const u8, id_field: []const u8) !?[]u8 {
    var title_lookup = try lookupField(gpa, note, "title");
    defer title_lookup.deinit(gpa);
    const title = scalarString(title_lookup.value) orelse return null;

    var id_lookup = try lookupField(gpa, note, id_field);
    defer id_lookup.deinit(gpa);
    const id = scalarString(id_lookup.value) orelse return null;
    if (id.len == 0) return null;

    if (!std.mem.startsWith(u8, title, id)) return null;
    return try std.fmt.allocPrint(gpa, "no_id_prefix_in_title: title starts with its own id '{s}'", .{id});
}

fn validateSectionRule(gpa: Allocator, section: *const Value, index: usize) !?[]u8 {
    if (unknownKey(section, &.{
        "title",      "level",         "required", "non_empty", "max_occurs", "content", "children",
        "repeatable", "title_pattern",
    })) |key| return try diag(gpa, "schema.body.sections[{d}].{s}: unsupported v1 key", .{ index, key });
    if (section.get("title") == null and section.get("title_pattern") == null)
        return try diag(gpa, "schema.body.sections[{d}]: title or title_pattern is required", .{index});
    if (section.get("level")) |v| {
        const level = v.asInteger() orelse
            return try diag(gpa, "schema.body.sections[{d}].level: must be integer", .{index});
        if (level < 1) return try diag(gpa, "schema.body.sections[{d}].level: must be at least 1", .{index});
    }
    if (section.get("max_occurs")) |v| {
        const max = v.asInteger() orelse
            return try diag(gpa, "schema.body.sections[{d}].max_occurs: must be integer", .{index});
        if (max < 1) return try diag(gpa, "schema.body.sections[{d}].max_occurs: must be at least 1", .{index});
    }
    if (section.get("required")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.body.sections[{d}].required: must be boolean", .{index});
    if (section.get("non_empty")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.body.sections[{d}].non_empty: must be boolean", .{index});
    if (section.get("repeatable")) |v| if (v.asBool() == null)
        return try diag(gpa, "schema.body.sections[{d}].repeatable: must be boolean", .{index});
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
        if (try validateTaskLeadAndChecklist(gpa, body_rule, markdown, headings, h1.?)) |message| return message;
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

fn validateTaskLeadAndChecklist(gpa: Allocator, body_rule: *const Value, markdown: []const u8, headings: []const Heading, h1: Heading) !?[]u8 {
    // The checklist now lives under a named `## Checklist` heading, not under
    // "everything before the first `##`". `lead` stays as prose directly
    // under the H1, before that heading.
    var checklist_heading: ?Heading = null;
    for (headings) |heading| {
        if (heading.level == 2 and std.mem.eql(u8, heading.title, "Checklist")) {
            checklist_heading = heading;
            break;
        }
    }

    var have_lead = false;
    const lead_end = if (checklist_heading) |h| h.line_start else h1.content_end;
    {
        var lines = std.mem.splitScalar(u8, markdown[h1.content_start..lead_end], '\n');
        while (lines.next()) |raw_with_cr| {
            const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
            const trimmed = std.mem.trimStart(u8, raw, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '>') continue;
            have_lead = true;
        }
    }

    var checklist_count: usize = 0;
    if (checklist_heading) |h| {
        var lines = std.mem.splitScalar(u8, markdown[h.content_start..h.content_end], '\n');
        var in_fence = false;
        while (lines.next()) |raw_with_cr| {
            const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
            const trimmed = std.mem.trimStart(u8, raw, " \t");
            if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
                in_fence = !in_fence;
                continue;
            }
            if (in_fence or trimmed.len == 0) continue;
            if (isChecklistLine(trimmed)) {
                if (raw.len != trimmed.len)
                    return try diag(gpa, "body.checklist: nested checklist items are not allowed", .{});
                checklist_count += 1;
            }
        }
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
            if (left.len < 19 or right.len < 19)
                return try diag(gpa, "{s}: must not precede {s} — a value is missing or malformed", .{ values.list[0].string, values.list[1].string });
            if (std.mem.lessThan(u8, left[0..19], right[0..19]))
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

/// Deliberately its own scan, not `query.FrontmatterIterator` plus
/// `query.topLevelKeyValue`: schema validation needs strictly more than
/// either gives -- trailing-comment stripping, block-style (indented `- `)
/// list values alongside flow `[a, b]` ones, typed values (`boolean`/
/// `integer`/`string`, not just string), explicit-invalid detection for a
/// malformed quote or bracket, and duplicate-key detection. Nothing else in
/// this codebase needs any of that, so folding it into the shared scanner
/// would either weaken this or grow every other caller's surface for a
/// capability only this one uses.
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
                    // A nested mapping under a list item (`- path: x` then an
                    // indented `hash: y`) lands here -- every item already
                    // duped into `items` up to this point must be freed, not
                    // just the list spine, or the invalid return leaks them.
                    for (items.items) |it| gpa.free(it);
                    items.deinit(gpa);
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

const FieldPos = struct { key: []const u8, line_start: usize };

/// Every top-level frontmatter key in file order, first occurrence only --
/// `lookupField`'s own duplicate detection already covers a repeated key, so
/// a second occurrence here would only ever be redundant with that error.
/// Byte offset (`line_start`), not a line number: enough to order two keys
/// against each other, and cheaper than counting newlines.
fn collectFrontmatterFields(gpa: Allocator, note: []const u8, bounds: Bounds) ![]FieldPos {
    var out: std.ArrayListUnmanaged(FieldPos) = .empty;
    errdefer out.deinit(gpa);
    var offset = bounds.start;
    while (offset < bounds.end) {
        const end = std.mem.indexOfScalarPos(u8, note, offset, '\n') orelse bounds.end;
        const raw = std.mem.trimEnd(u8, note[offset..end], "\r");
        if (raw.len != 0 and raw[0] != ' ' and raw[0] != '\t' and raw[0] != '#') {
            if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
                const key = std.mem.trim(u8, raw[0..colon], " ");
                var seen = false;
                for (out.items) |f| {
                    if (std.mem.eql(u8, f.key, key)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.append(gpa, .{ .key = key, .line_start = offset });
            }
        }
        offset = end + 1;
    }
    return out.toOwnedSlice(gpa);
}

fn findFieldLine(positions: []const FieldPos, key: []const u8) ?usize {
    for (positions) |p| if (std.mem.eql(u8, p.key, key)) return p.line_start;
    return null;
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
    // Present and required/order-checkable, but its content is outside what v1's other four
    // types can express -- a list of mappings (`sources: [{path, hash}, ...]`), for instance.
    // No scalar check (`const`/`pattern`/`enum`/...) ever fires for one: `scalarString` returns
    // null for anything but `.string`, `any` included.
    if (std.mem.eql(u8, type_name, "any")) return true;
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

// --- sb-082: per-check negative coverage ----------------------------------

fn expectNoteMessage(source: []const u8, note: []const u8, path: []const u8, context: Context, want: []const u8) !void {
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateNote(testing.allocator, doc.root, note, path, context)).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings(want, message);
}

fn expectNoteOk(source: []const u8, note: []const u8, path: []const u8, context: Context) !void {
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(?[]u8, null), try validateNote(testing.allocator, doc.root, note, path, context));
}

test "min_length below 1 is rejected at schema-validation time" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      min_length: -1\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.frontmatter.fields.title.min_length: must be at least 1", message);
}

test "min_length diagnostics carry the configured bound" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "      min_length: 5\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    try expectNoteMessage(source, "---\ntitle: Hi\n---\n# Hi\n", "x.md", .{ .mode = .create }, "frontmatter.title: must be at least 5 characters");
}

test "not_before diagnoses a missing field instead of passing silently" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks:\n" ++
        "  - not_before: [frontmatter.updated, frontmatter.created]\n";
    try expectNoteMessage(source, "---\ntitle: Example\n---\n# Example\n", "x.md", .{ .mode = .create }, "frontmatter.updated: must not precede frontmatter.created — a value is missing or malformed");
}

test "not_before rejects a timestamp that precedes its pair and accepts the reverse" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks:\n" ++
        "  - not_before: [frontmatter.updated, frontmatter.created]\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\nupdated: '2026-08-30 01:00:00 CEST'\ncreated: '2026-08-30 02:00:00 CEST'\n---\n# Example\n",
        "x.md", .{ .mode = .create }, "frontmatter.updated: must not precede frontmatter.created");
    try expectNoteOk(source,
        "---\ntitle: Example\nupdated: '2026-08-30 02:00:00 CEST'\ncreated: '2026-08-30 01:00:00 CEST'\n---\n# Example\n",
        "x.md", .{ .mode = .create });
}

test "const check applies on creation and skips on update" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks:\n" ++
        "  - const:\n" ++
        "      field: frontmatter.status\n" ++
        "      value: TODO\n" ++
        "      when: create\n";
    const note = "---\ntitle: Example\nstatus: DONE\n---\n# Example\n";
    try expectNoteMessage(source, note, "x.md", .{ .mode = .create }, "frontmatter.status: must equal 'TODO' on creation");
    try expectNoteOk(source, note, "x.md", .{ .mode = .update, .existing = "---\ntitle: Example\n---\n# Example\n" });
}

test "vocabulary check rejects a value outside the configured list" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "    tags:\n" ++
        "      type: list\n" ++
        "      required: true\n" ++
        "      items: string\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks:\n" ++
        "  - vocabulary:\n" ++
        "      field: frontmatter.tags\n" ++
        "      source: synapse-tag-vocabulary.conf\n";
    try expectNoteMessage(source, "---\ntitle: Example\ntags: [synapse, nope]\n---\n# Example\n", "x.md", .{
        .mode = .create,
        .tags_vocabulary = "synapse\narchitecture\n",
    }, "frontmatter.tags: 'nope' is not in synapse-tag-vocabulary.conf");
    try expectNoteOk(source, "---\ntitle: Example\ntags: [synapse]\n---\n# Example\n", "x.md", .{
        .mode = .create,
        .tags_vocabulary = "synapse\narchitecture\n",
    });
}

test "declared sections are checked for relative order" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  sections:\n" ++
        "    - title: Z\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "    - title: A\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\n## A\ncontent\n\n## Z\ncontent\n",
        "x.md", .{ .mode = .create }, "body.section.A: declared sections are out of relative order");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\n## Z\ncontent\n\n## A\ncontent\n",
        "x.md", .{ .mode = .create });
}

test "schema.frontmatter.field_order rejects a value other than relative" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  field_order: strict\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.frontmatter.field_order: unsupported value 'strict'", message);
}

test "declared frontmatter fields are checked for relative order when field_order: relative" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  field_order: relative\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "    sources:\n" ++
        "      type: string\n" ++
        "      required: false\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\nsources: x\ntitle: Example\n---\n# Example\n",
        "x.md", .{ .mode = .create }, "frontmatter.sources: declared fields are out of relative order");
    try expectNoteOk(source,
        "---\ntitle: Example\nsources: x\n---\n# Example\n",
        "x.md", .{ .mode = .create });
    // A missing optional field is simply skipped, not treated as a position of 0.
    try expectNoteOk(source, "---\ntitle: Example\n---\n# Example\n", "x.md", .{ .mode = .create });
}

test "type: any accepts a field whose value is a list of mappings, no other v1 type can" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "    sources:\n" ++
        "      type: any\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    try expectNoteOk(source,
        "---\ntitle: Example\nsources:\n  - path: a.zig\n    hash: aa\n  - path: b.zig\n    hash: bb\n---\n# Example\n",
        "x.md", .{ .mode = .create });
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n",
        "x.md", .{ .mode = .create }, "frontmatter.sources: required field is missing");
}

test "field_order is unset by default, so any frontmatter order passes" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "    sources:\n" ++
        "      type: string\n" ++
        "      required: false\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks: []\n";
    try expectNoteOk(source,
        "---\nsources: x\ntitle: Example\n---\n# Example\n",
        "x.md", .{ .mode = .create });
}

fn lintFindings(gpa: Allocator, source: []const u8, note: []const u8, path: []const u8) ![]const []u8 {
    var doc = try schema_yaml.parse(gpa, source);
    defer doc.deinit();
    return lintNote(gpa, doc.root, note, path);
}

fn freeLintFindings(gpa: Allocator, findings: []const []const u8) void {
    for (findings) |f| gpa.free(f);
    gpa.free(findings);
}

const lint_test_frontmatter =
    "frontmatter:\n  fields:\n    title:\n      type: string\n    task_id:\n      type: string\n";

test "schema.lints rejects an unknown key" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap: body.prose\n    severity: warn\n    extra: 1\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0].extra: unsupported v1 key", message);
}

test "schema.lints requires exactly one operator" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - severity: warn\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0]: exactly one lint operator is required", message);
}

test "schema.lints.no_hard_wrap only accepts body.prose" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap: body.other\n    severity: warn\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0].no_hard_wrap: unsupported field reference 'body.other'", message);
}

test "schema.lints.severity only accepts warn for now" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap: body.prose\n    severity: error\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0].severity: unsupported value 'error'", message);
}

test "schema.lints.no_id_prefix_in_title only accepts a known id reference" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_id_prefix_in_title:\n      title: frontmatter.title\n      id: frontmatter.other\n    severity: warn\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0].no_id_prefix_in_title.id: unsupported field reference 'frontmatter.other'", message);
}

test "a schema with no lints: key lints nothing, even on an obviously wrapped note" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n";
    const note = "---\ntitle: X\n---\n# X\n\n## Summary\nwrapped line one\nwrapped line two\n";
    const findings = try lintFindings(testing.allocator, source, note, "x.md");
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "no_hard_wrap fires on a wrapped paragraph and stays silent on a clean one" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap: body.prose\n    severity: warn\n";

    const wrapped = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a sentence that got\nhard-wrapped across two lines.\n";
    const findings = try lintFindings(testing.allocator, source, wrapped, "x.md");
    defer freeLintFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "no_hard_wrap") != null);
    try testing.expect(std.mem.indexOf(u8, findings[0], "line 7") != null);

    const clean = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is one continuous line, exactly as the convention wants.\n";
    const clean_findings = try lintFindings(testing.allocator, source, clean, "x.md");
    defer testing.allocator.free(clean_findings);
    try testing.expectEqual(@as(usize, 0), clean_findings.len);
}

test "no_hard_wrap excludes table rows, list continuations, and fenced code" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap: body.prose\n    severity: warn\n";

    const note = "---\ntitle: X\n---\n# X\n\n## Summary\n" ++
        "| a | b |\n| c | d |\n\n" ++
        "- item one\n  a continuation paragraph under it\n  and another line of it\n\n" ++
        "```\ncode line one\ncode line two\n```\n";
    const findings = try lintFindings(testing.allocator, source, note, "x.md");
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "no_id_prefix_in_title fires when the title starts with its own id" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_id_prefix_in_title:\n      title: frontmatter.title\n      id: frontmatter.task_id\n    severity: warn\n";

    const prefixed = "---\ntitle: \"sb-102 — Something\"\ntask_id: sb-102\n---\n# X\n";
    const findings = try lintFindings(testing.allocator, source, prefixed, "x.md");
    defer freeLintFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "sb-102") != null);

    const clean = "---\ntitle: Something\ntask_id: sb-102\n---\n# X\n";
    const clean_findings = try lintFindings(testing.allocator, source, clean, "x.md");
    defer testing.allocator.free(clean_findings);
    try testing.expectEqual(@as(usize, 0), clean_findings.len);
}

test "a compiled-task backlink must immediately follow the H1" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  preamble:\n" ++
        "    - type: blockquote\n" ++
        "      required: false\n" ++
        "      position: immediately_after_h1\n" ++
        "      pattern: '^> Compiled task: \\[\\[[^\\]]+\\]\\]$'\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\nlead paragraph\n\n> Compiled task: [[Task title]]\n",
        "x.md", .{ .mode = .create }, "body.preamble: compiled-task backlink must immediately follow H1");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\n> Compiled task: [[Task title]]\n\n## Summary\nrest\n",
        "x.md", .{ .mode = .create });
}

test "checklist minimum item count is enforced" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  lead:\n" ++
        "    required: true\n" ++
        "  checklist:\n" ++
        "    required: true\n" ++
        "    min_items: 2\n" ++
        "  sections:\n" ++
        "    - title: Checklist\n" ++
        "      level: 2\n" ++
        "      required: true\n" ++
        "    - title: Notes\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n- [ ] one\n\n## Notes\nrest\n",
        "x.md", .{ .mode = .create }, "body.checklist: expected at least 2 flat item(s), found 1");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n- [ ] one\n- [ ] two\n\n## Notes\nrest\n",
        "x.md", .{ .mode = .create });
}

test "checklist items are scoped to the Checklist heading, not parsed past Notes" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  lead:\n" ++
        "    required: true\n" ++
        "  checklist:\n" ++
        "    required: true\n" ++
        "    min_items: 1\n" ++
        "  sections:\n" ++
        "    - title: Checklist\n" ++
        "      level: 2\n" ++
        "      required: true\n" ++
        "    - title: Notes\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "checks: []\n";
    // A `- [ ]` inside ## Notes must not count toward the checklist minimum.
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n## Notes\n\n- [ ] not a checklist item\n",
        "x.md", .{ .mode = .create }, "body.checklist: expected at least 1 flat item(s), found 0");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n- [ ] one\n\n## Notes\n\n- [ ] not a checklist item\n",
        "x.md", .{ .mode = .create });
}

test "nested checklist items are rejected inside the Checklist heading" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  lead:\n" ++
        "    required: true\n" ++
        "  checklist:\n" ++
        "    required: true\n" ++
        "    nested_items: false\n" ++
        "  sections:\n" ++
        "    - title: Checklist\n" ++
        "      level: 2\n" ++
        "      required: true\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n- [ ] one\n  - [ ] sub\n",
        "x.md", .{ .mode = .create }, "body.checklist: nested checklist items are not allowed");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\nlead\n\n## Checklist\n\n- [ ] one\n",
        "x.md", .{ .mode = .create });
}

test "lead prose must precede the Checklist heading when required" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  lead:\n" ++
        "    required: true\n" ++
        "  checklist:\n" ++
        "    required: true\n" ++
        "  sections:\n" ++
        "    - title: Checklist\n" ++
        "      level: 2\n" ++
        "      required: true\n" ++
        "checks: []\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\n---\n# Example\n\n## Checklist\n\n- [ ] one\n",
        "x.md", .{ .mode = .create }, "body.lead: prose before the checklist is required");
    try expectNoteOk(source,
        "---\ntitle: Example\n---\n# Example\n\nlead prose\n\n## Checklist\n\n- [ ] one\n",
        "x.md", .{ .mode = .create });
}

test "migration cannot introduce an immutable field" {
    var doc = try schema_yaml.parse(testing.allocator, bare_schema);
    defer doc.deinit();
    const existing = "---\ntitle: Example\n---\n# Example\n## Summary\nOld\n";
    const candidate =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\ncreated: '2026-08-30 10:00:00 CEST'\nupdated: '2026-08-30 10:00:00 CEST'\ntags: []\n---\n# Example\n## Summary\nNew\n";
    const message = (try validateNote(testing.allocator, doc.root, candidate, "research/Example.md", .{
        .mode = .migration,
        .existing = existing,
        .tags_vocabulary = "",
    })).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("frontmatter.note_id: field is immutable", message);
}

test "title_pattern child headings are strict; title children are lenient" {
    const strict_source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  sections:\n" ++
        "    - title: Notes\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "      children:\n" ++
        "        - level: 3\n" ++
        "          required: false\n" ++
        "          title_pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2} — .+$'\n" ++
        "checks: []\n";
    try expectNoteMessage(strict_source,
        "---\ntitle: Example\n---\n# Example\n\n## Notes\n\n### Not dated\n\ncontent\n",
        "x.md", .{ .mode = .create }, "body.section.Notes: child heading 'Not dated' has an invalid title");
    try expectNoteOk(strict_source,
        "---\ntitle: Example\n---\n# Example\n\n## Notes\n\n### 2026-08-30 — entry\n\ncontent\n",
        "x.md", .{ .mode = .create });

    const lenient_source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "  sections:\n" ++
        "    - title: Notes\n" ++
        "      level: 2\n" ++
        "      required: false\n" ++
        "      children:\n" ++
        "        - title: Wanted\n" ++
        "          level: 3\n" ++
        "          required: false\n" ++
        "checks: []\n";
    try expectNoteOk(lenient_source,
        "---\ntitle: Example\n---\n# Example\n\n## Notes\n\n### Unrelated\n\ncontent\n",
        "x.md", .{ .mode = .create });
}

fn expectSchemaMessage(source: []const u8, want: []const u8) !void {
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings(want, message);
}

test "negative and zero DSL counts are rejected at schema-validation time" {
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    count: -1\nchecks: []\n",
        "schema.body.h1.count: must be at least 1");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  sections:\n    - title: X\n      level: 0\nchecks: []\n",
        "schema.body.sections[0].level: must be at least 1");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  sections:\n    - title: X\n      max_occurs: 0\nchecks: []\n",
        "schema.body.sections[0].max_occurs: must be at least 1");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  checklist:\n    min_items: -1\nchecks: []\n",
        "schema.body.checklist.min_items: must not be negative");
}

test "non-boolean DSL rule keys are rejected at schema-validation time" {
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  sections:\n    - title: X\n      required: \"true\"\nchecks: []\n",
        "schema.body.sections[0].required: must be boolean");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  sections:\n    - title: X\n      non_empty: 1\nchecks: []\n",
        "schema.body.sections[0].non_empty: must be boolean");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  sections:\n    - title: X\n      repeatable: \"yes\"\nchecks: []\n",
        "schema.body.sections[0].repeatable: must be boolean");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  lead:\n    required: \"true\"\nchecks: []\n",
        "schema.body.lead.required: must be boolean");
    try expectSchemaMessage(
        "schema: synapse-note-schema/v1\nid: t/v1\nfrontmatter:\n  fields:\n    title:\n      type: string\nbody:\n  h1:\n    required: false\n  checklist:\n    required: 1\nchecks: []\n",
        "schema.body.checklist.required: must be boolean");
}
