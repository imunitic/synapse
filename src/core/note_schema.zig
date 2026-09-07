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
const vault_query = @import("vault_query.zig");
const jsonlogic = @import("jsonlogic.zig");
const core_query = @import("query.zig");
const schema_rules = @import("schema_rules.zig");

const Allocator = std.mem.Allocator;
const Value = schema_yaml.Value;

pub const Mode = enum { create, update, migration };

/// A `lints:` rule's own `severity:` value. `ignore` skips the rule
/// entirely (never even runs it, not just discards its finding); `warn` is
/// today's existing advisory-only behavior (`lintNote`'s finding never
/// blocks a write); `error` blocks the write the same way `checks:`
/// already does, checked by `SchemaValidationStore.write` after `lintNote`
/// returns.
pub const Severity = enum {
    ignore,
    warn,
    @"error",

    fn parse(text: []const u8) ?Severity {
        return std.meta.stringToEnum(Severity, text);
    }
};

pub const Context = struct {
    mode: Mode,
    existing: ?[]const u8 = null,
    /// The already-existing identity found by the adapter's creation or
    /// migration-only vault scan, or null when the identity is unique.
    duplicate_identity: ?[]const u8 = null,
    /// Conf-file content for `checks:`/`lints:`'s `vocabularies.<stem>`
    /// data-tree map. The caller populates this from whichever files
    /// `neededVocabularyStems` says a schema's `checks:`/`lints:` actually
    /// reference -- not every conf file that exists, and not a fixed pair.
    vocabularies: []const VocabularySource = &.{},
};

pub const VocabularySource = struct {
    /// The conf file's own stem, no extension -- `synapse-tag-vocabulary`,
    /// not `synapse-tag-vocabulary.conf`. `var`'s dotted-path resolution
    /// has no way to escape a `.` inside a key, so a literal extension in
    /// the key would split into an extra, wrong path segment.
    stem: []const u8,
    content: []const u8,
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

/// A `checks:`/`lints:` list entry's shape: exactly one rule-defining key
/// (any operator name -- built-in, custom, or a word alias), plus the
/// optional siblings every entry may carry alongside it. Shared by
/// schema-load-time validation (`validateCheckRule`/`validateLintRule`)
/// and note-time evaluation (`validateChecks`/`lintNote`), so the two
/// never drift on what counts as "the rule" versus "a sibling".
const CheckShape = struct {
    key: []const u8,
    value: *Value,
    message: ?[]const u8,
    /// `message:` was present but wasn't a string -- schema-load-time
    /// validation rejects this; note-time evaluation never sees it (a
    /// malformed schema never gets this far).
    message_present_but_invalid: bool,
};

fn checkShape(entry: *const Value) ?CheckShape {
    if (entry.* != .map) return null;
    var rule_entry: ?schema_yaml.Entry = null;
    var message: ?[]const u8 = null;
    var message_invalid = false;
    for (entry.map) |e| {
        if (std.mem.eql(u8, e.key, "message")) {
            switch (e.value.*) {
                .string => |s| message = s,
                else => message_invalid = true,
            }
            continue;
        }
        if (std.mem.eql(u8, e.key, "severity")) continue;
        if (rule_entry != null) return null; // more than one rule-shaped key -- ambiguous
        rule_entry = e;
    }
    const found = rule_entry orelse return null;
    return .{ .key = found.key, .value = found.value, .message = message, .message_present_but_invalid = message_invalid };
}

/// Every operator name used anywhere in `rule` (built-in, or in
/// `custom_ops`) -- the first *unrecognized* name found, or `null` if
/// every name checks out. Catches a typo'd operator at schema-load time,
/// before any note exists to actually run the rule against and turn the
/// same mistake into a raw `UnknownOperator` error on someone's real write.
fn firstUnknownOperator(rule: std.json.Value) ?[]const u8 {
    switch (rule) {
        .object => |obj| {
            if (obj.count() == 1) {
                var it = obj.iterator();
                const entry = it.next().?;
                const name = entry.key_ptr.*;
                var known = false;
                for (jsonlogic.built_in_names) |b| {
                    if (std.mem.eql(u8, b, name)) {
                        known = true;
                        break;
                    }
                }
                if (!known) for (custom_ops) |c| {
                    if (std.mem.eql(u8, c.name, name)) {
                        known = true;
                        break;
                    }
                };
                if (!known) return name;
                return firstUnknownOperator(entry.value_ptr.*);
            }
            var it = obj.iterator();
            while (it.next()) |entry| if (firstUnknownOperator(entry.value_ptr.*)) |bad| return bad;
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| if (firstUnknownOperator(item)) |bad| return bad;
            return null;
        },
        else => return null,
    }
}

fn validateCheckRule(gpa: Allocator, check: *const Value, index: usize) !?[]u8 {
    const shape = checkShape(check) orelse
        return try diag(gpa, "schema.checks[{d}]: exactly one rule operator is required", .{index});
    if (shape.message_present_but_invalid)
        return try diag(gpa, "schema.checks[{d}].message: must be string", .{index});
    // The converted rule tree is throwaway -- read once by
    // firstUnknownOperator below and discarded, never returned -- so its
    // container allocations live in their own arena, not the caller's gpa.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
    const rule = schema_rules.toRule(arena_state.allocator(), &synthetic) catch |err| switch (err) {
        error.StrayTombstone => return try diag(gpa, "schema.checks[{d}].{s}: a bare null is not valid here", .{ index, shape.key }),
        else => return err,
    };
    if (firstUnknownOperator(rule)) |bad|
        return try diag(gpa, "schema.checks[{d}]: unknown operator '{s}'", .{ index, bad });
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

fn validateLintRule(gpa: Allocator, rule: *const Value, index: usize) !?[]u8 {
    const shape = checkShape(rule) orelse
        return try diag(gpa, "schema.lints[{d}]: exactly one rule operator is required", .{index});
    if (shape.message_present_but_invalid)
        return try diag(gpa, "schema.lints[{d}].message: must be string", .{index});
    const severity = stringAt(rule, "severity") orelse
        return try diag(gpa, "schema.lints[{d}].severity: required string is missing", .{index});
    if (Severity.parse(severity) == null)
        return try diag(gpa, "schema.lints[{d}].severity: unsupported value '{s}'", .{ index, severity });
    // Same throwaway-tree reasoning as validateCheckRule -- read once, then
    // discarded, so its own arena rather than the caller's gpa.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
    const converted = schema_rules.toRule(arena_state.allocator(), &synthetic) catch |err| switch (err) {
        error.StrayTombstone => return try diag(gpa, "schema.lints[{d}].{s}: a bare null is not valid here", .{ index, shape.key }),
        else => return err,
    };
    if (firstUnknownOperator(converted)) |bad|
        return try diag(gpa, "schema.lints[{d}]: unknown operator '{s}'", .{ index, bad });
    return null;
}

/// `schema` must already have passed `validateSchema` -- this reads
/// `schema.get("frontmatter"/"body"/"checks").?` unconditionally, so an
/// unvalidated document (one of those keys missing or malformed) panics
/// here instead of failing cleanly. Every real caller in this codebase
/// (`SchemaValidationStore.write`, `vault-check`) already validates first;
/// this is a caller contract, not a check this function makes itself.
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
                return try diag(gpa, "frontmatter.{s}: expected RFC3339, YYYY-MM-DDTHH:MM:SS then Z or a colon-separated numeric offset", .{field.key});
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

pub const Finding = struct {
    message: []u8,
    severity: Severity,
};

/// Never blocks a write itself -- every finding is collected, none stop the
/// pass early -- but it does tag each with the rule's own `severity:`, and
/// it is the caller's job to act on an `.error` one (`SchemaValidationStore
/// .write` refuses the write outright when any finding is `.error`; a
/// read-only sweep like `vault-check` can report every severity the same
/// way instead). An `.ignore`-severity rule never runs at all -- not "runs
/// and its finding is discarded", the rule itself is skipped. Called only
/// after `validateNote` has already passed (a rejected write never reaches
/// lint), and only for a schema that declares `lints:` at all -- a schema
/// with none returns an empty slice, the same "nothing to say" shape as a
/// clean note.
pub fn lintNote(gpa: Allocator, schema: *const Value, note: []const u8, path: []const u8) ![]const Finding {
    var findings: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer {
        for (findings.items) |f| gpa.free(f.message);
        findings.deinit(gpa);
    }

    const lints = schema.get("lints") orelse return findings.toOwnedSlice(gpa);
    // Lint is purely advisory and never itself distinguishes create from
    // update -- none of the five real operators need is_create/vocabularies
    // to run, so a neutral Context is the right input here, not a second
    // way for a caller to thread one through.
    //
    // The data tree and every converted rule are throwaway, same reasoning
    // as validateChecks -- one arena, with each finding's own message
    // duplicated into gpa before it's kept, so it outlives the arena.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try dataTree(arena, path, note, .{ .mode = .update });

    for (lints.list) |rule| {
        // Schema validation already confirmed `severity` is present and
        // one of the recognized values before any note is ever linted.
        const severity = Severity.parse(stringAt(rule, "severity").?).?;
        if (severity == .ignore) continue;
        const result = try evalEntry(arena, rule, tree) orelse continue;
        if (!jsonlogic.truthy(result)) {
            const msg = try ruleFailureMessage(arena, rule);
            const message = try gpa.dupe(u8, msg);
            try findings.append(gpa, .{ .message = message, .severity = severity });
        }
    }
    return findings.toOwnedSlice(gpa);
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

/// A `checks:`/`lints:` list entry with no recognizable rule-defining key
/// left after schema validation has already run should never reach here --
/// `validateCheckRule`/`validateLintRule` reject that at load time. Reached
/// only if a caller skipped schema validation first, which is already this
/// file's standing caller contract (see `validateNote`'s own doc comment).
fn evalEntry(gpa: Allocator, entry: *const Value, tree: std.json.Value) !?std.json.Value {
    const shape = checkShape(entry) orelse return null;
    var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
    const rule = try schema_rules.toRule(gpa, &synthetic);
    return try jsonlogic.evaluate(rule, tree, null, &custom_ops);
}

fn ruleFailureMessage(gpa: Allocator, entry: *const Value) ![]u8 {
    const shape = checkShape(entry).?; // evalEntry already confirmed this
    if (shape.message) |msg| return try gpa.dupe(u8, msg);
    var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
    const rule = try schema_rules.toRule(gpa, &synthetic);
    return try failureDiag(gpa, rule);
}

/// One `[]u8` fallback message for a failing rule with no `message:`
/// sibling of its own -- the rule's own JSON representation, truncated if
/// pathologically long. Worse than a hand-written sentence, but always
/// available without any operator having to produce text itself (every
/// operator, built-in or custom, returns only a bool).
fn failureDiag(gpa: Allocator, rule: std.json.Value) ![]u8 {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(rule, .{}, &writer) catch {}; // truncation is fine for a fallback
    return try std.fmt.allocPrint(gpa, "rule failed: {s}", .{writer.buffered()});
}

/// Every distinct `vocabularies.<stem>` a schema's `checks:` and `lints:`
/// together reference -- what a caller needs to know before it can build
/// `Context.vocabularies`, since the actual file *read* is the caller's
/// job, not this file's (no `std.fs` here, only `schema_yaml`/
/// `schema_rules`/`jsonlogic` trees). `<stem>.conf` is the file to load for
/// each name returned -- only the files a schema actually references, not
/// every conf file that happens to exist.
pub fn neededVocabularyStems(gpa: Allocator, schema: *const Value) ![]const []const u8 {
    // The stems themselves (strings) end up borrowed straight from
    // `schema`'s own tree either way -- `toRule` never copies a scalar's
    // bytes, only builds new container structures around it -- so only
    // those throwaway containers need their own arena; `out`'s own slice
    // of borrowed string headers is real, gpa-owned, and outlives this call.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ "checks", "lints" }) |key| {
        const list = schema.get(key) orelse continue;
        for (list.list) |entry| {
            const shape = checkShape(entry) orelse continue;
            var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
            const rule = try schema_rules.toRule(arena, &synthetic);
            try schema_rules.scanVocabularyStems(gpa, rule, &out);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// True iff `schema`'s own `checks:` actually consults `id_is_unique`
/// (via `on_create: {var: id_is_unique}` or any composition containing it)
/// -- lets the caller skip its vault-wide identity scan entirely for a
/// schema that never uses the field (`graph-node/v1` has no identity
/// check at all), the same "only scan when the concept is used" property
/// the old `unique:`/`when: create` check shape gave for free.
pub fn needsIdentityScan(gpa: Allocator, schema: *const Value) !bool {
    const checks = schema.get("checks") orelse return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (checks.list) |check| {
        const shape = checkShape(check) orelse continue;
        var synthetic = Value{ .map = &.{.{ .key = shape.key, .value = shape.value }} };
        const rule = try schema_rules.toRule(arena, &synthetic);
        if (schema_rules.referencesVar(rule, "id_is_unique")) return true;
    }
    return false;
}

fn validateChecks(gpa: Allocator, checks: *const Value, note: []const u8, path: []const u8, context: Context) !?[]u8 {
    if (checks.list.len == 0) return null;
    // The data tree and every converted rule are throwaway -- built once,
    // read a few times, discarded -- so they live in one arena rather than
    // the caller's own gpa; only the final diagnostic (if any) gets
    // duplicated into gpa right before returning, so it outlives the arena.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try dataTree(arena, path, note, context);
    for (checks.list) |check| {
        const result = try evalEntry(arena, check, tree) orelse continue;
        if (!jsonlogic.truthy(result)) {
            const msg = try ruleFailureMessage(arena, check);
            return try gpa.dupe(u8, msg);
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

/// The `std.json.Value` tree a `checks:`/`lints:` rule evaluates against --
/// reuses `vault_query.zig`'s own `frontmatterAsJson` for the frontmatter
/// half (the same conversion `vault-search` already trusts) and this
/// file's own `collectHeadings` for section presence, rather than pulling
/// fields one at a time through `lookupField`/`FieldValue` the way
/// `validateChecks`/`lintNote` do today.
///
/// `body.prose`/`body.section_names` are both scoped to the body only --
/// everything after the frontmatter's closing `---`, or the whole note
/// when there's no frontmatter block at all (a legacy note, the same
/// graceful fallback every other reader in this file already gives that
/// case).
///
/// `is_create`/`id_is_unique`/`created_epoch`/`updated_epoch` are derived
/// from `context` -- the same `Context` `validateChecks` already receives,
/// not a second source of truth about the write in progress.
/// `id_is_unique` stays `null` (not `false`) on an ordinary update: the
/// adapter's vault-wide scan only ever runs `when: create`
/// (`context.duplicate_identity` is simply never populated on an update),
/// so `null` here means "not computed," never "computed, and not unique."
/// `created_epoch`/`updated_epoch` are `null` when the field is missing or
/// fails `parseInstantSeconds` -- the same value `not_before` already
/// treats as "must not precede" failing outright, not silently passing.
///
/// `vocabularies` isn't built here yet -- a later addition to this same
/// tree, not this function's job on its own.
fn dataTree(gpa: Allocator, path: []const u8, note: []const u8, context: Context) !std.json.Value {
    const body = if (frontmatterBounds(note)) |b| note[b.after..] else note;

    const headings = try collectHeadings(gpa, body);
    defer gpa.free(headings);
    var section_names: std.json.Array = .init(gpa);
    for (headings) |h| try section_names.append(.{ .string = h.title });

    var body_obj: std.json.ObjectMap = .empty;
    try body_obj.put(gpa, "prose", .{ .string = body });
    try body_obj.put(gpa, "section_names", .{ .array = section_names });

    var filename_obj: std.json.ObjectMap = .empty;
    try filename_obj.put(gpa, "stem", .{ .string = filenameStem(path) });

    var root: std.json.ObjectMap = .empty;
    try root.put(gpa, "path", .{ .string = path });
    try root.put(gpa, "filename", .{ .object = filename_obj });
    try root.put(gpa, "frontmatter", try vault_query.frontmatterAsJson(gpa, note));
    try root.put(gpa, "body", .{ .object = body_obj });

    const is_create = context.mode == .create or context.mode == .migration;
    try root.put(gpa, "is_create", .{ .bool = is_create });
    try root.put(gpa, "id_is_unique", if (is_create) .{ .bool = context.duplicate_identity == null } else .null);
    try root.put(gpa, "created_epoch", try epochField(gpa, note, path, "frontmatter.created"));
    try root.put(gpa, "updated_epoch", try epochField(gpa, note, path, "frontmatter.updated"));

    var vocabularies: std.json.ObjectMap = .empty;
    for (context.vocabularies) |v| try vocabularies.put(gpa, v.stem, try vocabularyItems(gpa, v.content));
    try root.put(gpa, "vocabularies", .{ .object = vocabularies });

    return .{ .object = root };
}

fn epochField(gpa: Allocator, note: []const u8, path: []const u8, ref: []const u8) !std.json.Value {
    const resolved = try resolveRef(gpa, note, path, ref) orelse return .null;
    defer gpa.free(resolved);
    const secs = parseInstantSeconds(resolved) orelse return .null;
    return .{ .integer = secs };
}

/// One conf file's content, one line per entry, into a plain list of the
/// values a `var`/`in` rule can check membership against. A `key=value`
/// line (`synapse-projects.conf`'s own shape) contributes just the value;
/// a plain line (`synapse-tag-vocabulary.conf`'s shape) contributes
/// itself whole -- the same two shapes `vocabularyContains`'s `projection`
/// flag already distinguishes, unified here into one rule instead of a
/// per-rule flag, since a real vocabulary line never contains `=` unless
/// it's genuinely a `key=value` entry. This is what lets the old
/// `vocabulary: {..., projection: values}` config disappear entirely: the
/// distinction is now inherent to the file's own content, not something a
/// schema author has to declare per rule.
fn vocabularyItems(gpa: Allocator, content: []const u8) !std.json.Value {
    var items: std.json.Array = .init(gpa);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripTrailingComment(raw), " \t\r");
        if (line.len == 0) continue;
        const value = if (std.mem.indexOfScalar(u8, line, '=')) |eq|
            std.mem.trim(u8, line[eq + 1 ..], " \t")
        else
            line;
        try items.append(.{ .string = value });
    }
    return .{ .array = items };
}

/// `checks:`/`lints:`'s own custom-operator table -- covers the create-only
/// short-circuit and, as later checklist items land, the structural checks
/// no composition of `jsonlogic.zig`'s built-ins can express
/// (`no_hard_wrap`, `no_id_prefix_in_title`, `hard_wrap`,
/// `no_stray_frontmatter_block`). `unique`/`not_before`/`const`/`equals`
/// never get an entry here at all -- they already collapse into plain
/// built-in compositions once `dataTree`'s precomputed fields exist.
pub const custom_ops = [_]jsonlogic.CustomOp{
    .{ .name = "on_create", .func = evalOnCreate },
    .{ .name = "no_hard_wrap", .func = evalNoHardWrap },
    .{ .name = "no_id_prefix_in_title", .func = evalNoIdPrefixInTitle },
    .{ .name = "hard_wrap", .func = evalHardWrap },
    .{ .name = "no_stray_frontmatter", .func = evalNoStrayFrontmatter },
};

/// Short-circuits to truthy without evaluating its argument when
/// `data.is_create` is false or absent -- the create-only guard `unique`/
/// `equals {when: create}`/`const {when: create}` used to need a
/// special-cased `when:` sibling key for. Now it's just another operator
/// in the same table, composing like any other: `on_create` wraps one
/// whole sub-rule the same way `!` wraps one operand.
fn evalOnCreate(args: []const std.json.Value, data: std.json.Value, current_item: ?std.json.Value, ops: ?[]const jsonlogic.CustomOp) jsonlogic.Error!std.json.Value {
    if (args.len < 1) return jsonlogic.Error.InvalidArguments;
    const is_create = switch (data) {
        .object => |obj| if (obj.get("is_create")) |v| jsonlogic.truthy(v) else false,
        else => false,
    };
    if (!is_create) return .{ .bool = true };
    return jsonlogic.evaluate(args[0], data, current_item, ops);
}

/// `no_hard_wrap: {var: body.prose}` -- true (passes) unless some paragraph
/// in the resolved text is wrapped across 2+ consecutive lines. Fence
/// tracking plus `isExcludedProseLine`'s own exclusions (blank/heading/
/// blockquote/table/list/indented lines never count toward a run) decide
/// what counts as one paragraph run; this returns only a bool, the same as
/// every built-in -- the diagnostic text for a failing standalone lint
/// entry is `ruleFailureMessage`'s job, not this operator's.
fn evalNoHardWrap(args: []const std.json.Value, data: std.json.Value, current_item: ?std.json.Value, ops: ?[]const jsonlogic.CustomOp) jsonlogic.Error!std.json.Value {
    if (args.len < 1) return jsonlogic.Error.InvalidArguments;
    const prose_v = try jsonlogic.evaluate(args[0], data, current_item, ops);
    const prose = switch (prose_v) {
        .string => |s| s,
        else => return .{ .bool = true }, // nothing to scan: vacuously fine
    };

    var in_fence = false;
    var run_lines: usize = 0;
    var offset: usize = 0;
    while (offset <= prose.len) {
        const end = std.mem.indexOfScalarPos(u8, prose, offset, '\n') orelse prose.len;
        const line = prose[offset..end];
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
        const is_fence_delimiter = std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");

        if (is_fence_delimiter) {
            if (flushRun(&run_lines)) return .{ .bool = false };
            in_fence = !in_fence;
        } else if (in_fence or isExcludedProseLine(line)) {
            if (flushRun(&run_lines)) return .{ .bool = false };
        } else {
            run_lines += 1;
        }

        if (end == prose.len) break;
        offset = end + 1;
    }
    return .{ .bool = !flushRun(&run_lines) };
}

/// Closes the currently-open run, reporting whether it was a violation
/// (2+ lines).
fn flushRun(run_lines: *usize) bool {
    const violated = run_lines.* > 1;
    run_lines.* = 0;
    return violated;
}

/// `no_id_prefix_in_title: [{var: frontmatter.title}, {var: frontmatter.task_id}]`
/// -- true (passes) unless the title starts with its own id. A missing or
/// non-string title or id, or an empty id, passes vacuously -- nothing to
/// flag when either side of the comparison isn't really there.
fn evalNoIdPrefixInTitle(args: []const std.json.Value, data: std.json.Value, current_item: ?std.json.Value, ops: ?[]const jsonlogic.CustomOp) jsonlogic.Error!std.json.Value {
    if (args.len < 2) return jsonlogic.Error.InvalidArguments;
    const title_v = try jsonlogic.evaluate(args[0], data, current_item, ops);
    const id_v = try jsonlogic.evaluate(args[1], data, current_item, ops);
    const title = switch (title_v) {
        .string => |s| s,
        else => return .{ .bool = true },
    };
    const id = switch (id_v) {
        .string => |s| s,
        else => return .{ .bool = true },
    };
    if (id.len == 0) return .{ .bool = true };
    return .{ .bool = !std.mem.startsWith(u8, title, id) };
}

/// `hard_wrap: [{var: body.prose}, 100]` -- the opposite check from
/// `no_hard_wrap`: true (passes) only if every prose run in the resolved
/// text is *actually* filled toward `max_chars` the way a greedy
/// nearest-fit word-wrap would produce it, not merely "no line exceeds
/// it". Ported from sb-121's own proposed algorithm; its calling
/// convention changed from three sibling YAML keys (`hard_wrap: ...` /
/// `max_chars: ...` / `severity: ...`, meaningful under the old
/// one-operator-per-entry model) to two positional args, matching every
/// other multi-argument operator (`eq`, `in`, comparisons) now that a
/// `checks:`/`lints:` entry is a real expression, not a fixed slot for one
/// named check's own parameters.
fn evalHardWrap(args: []const std.json.Value, data: std.json.Value, current_item: ?std.json.Value, ops: ?[]const jsonlogic.CustomOp) jsonlogic.Error!std.json.Value {
    if (args.len < 2) return jsonlogic.Error.InvalidArguments;
    const text_v = try jsonlogic.evaluate(args[0], data, current_item, ops);
    const max_v = try jsonlogic.evaluate(args[1], data, current_item, ops);
    const text = switch (text_v) {
        .string => |s| s,
        else => return .{ .bool = true }, // nothing to scan: vacuously fine
    };
    const max_chars: usize = switch (max_v) {
        .integer => |i| if (i > 0) @intCast(i) else return jsonlogic.Error.InvalidArguments,
        else => return jsonlogic.Error.InvalidArguments,
    };

    var in_fence = false;
    var run_start: ?usize = null;
    var run_end: usize = 0;
    var offset: usize = 0;
    while (offset <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = text[offset..end];
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
        const is_fence_delimiter = std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");

        if (is_fence_delimiter) {
            if (run_start) |s| if (!matchesGreedyWrap(text[s..run_end], max_chars)) return .{ .bool = false };
            run_start = null;
            in_fence = !in_fence;
        } else if (in_fence or isExcludedProseLine(line)) {
            if (run_start) |s| if (!matchesGreedyWrap(text[s..run_end], max_chars)) return .{ .bool = false };
            run_start = null;
        } else {
            if (run_start == null) run_start = offset;
            run_end = end;
        }

        if (end == text.len) break;
        offset = end + 1;
    }
    if (run_start) |s| if (!matchesGreedyWrap(text[s..run_end], max_chars)) return .{ .bool = false };
    return .{ .bool = true };
}

/// True iff greedily reflowing `run_text`'s own word stream at target
/// width `max_chars` -- "whichever landing is closer to `max_chars`, over
/// or under; an exact tie starts the next line" -- reproduces exactly the
/// line breaks `run_text` already has. Allocation-free: `words`/`pending`
/// walk the run's flat word stream (newlines and spaces are equally word
/// separators, so which original line a word came from doesn't matter to
/// the simulation), and each actual line is compared word-by-word against
/// the words the simulation places on it, never materializing a
/// reconstructed line to compare as a string.
fn matchesGreedyWrap(run_text: []const u8, max_chars: usize) bool {
    var lines = std.mem.splitScalar(u8, run_text, '\n');
    var words = std.mem.tokenizeAny(u8, run_text, " \t\r\n");
    var pending: ?[]const u8 = words.next();

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw_line, "\r"), " \t");
        if (line.len == 0) continue;

        var line_words = std.mem.tokenizeAny(u8, line, " \t");

        const first = pending orelse return false;
        const actual_first = line_words.next() orelse return false;
        if (!std.mem.eql(u8, first, actual_first)) return false;
        var line_len: usize = first.len;
        pending = words.next();

        while (pending) |next_word| {
            const candidate_len = line_len + 1 + next_word.len;
            // The overshoot decision is final for this line: whichever way
            // it goes, no further word is considered after it -- spec is
            // "that word belongs on the line" (singular), not a license to
            // keep piling on past the target once one overshoot is allowed.
            var stop_after_this_word = false;
            if (candidate_len > max_chars) {
                const overshoot = candidate_len - max_chars;
                const undershoot = max_chars - line_len;
                if (overshoot >= undershoot) break; // strictly nearer only -- a tie excludes
                stop_after_this_word = true;
            }
            const actual_next = line_words.next() orelse return false;
            if (!std.mem.eql(u8, next_word, actual_next)) return false;
            line_len = candidate_len;
            pending = words.next();
            if (stop_after_this_word) break;
        }

        if (line_words.next() != null) return false; // actual line has extra words
    }
    return pending == null; // no leftover words after the last actual line
}

/// `no_stray_frontmatter: {var: body.prose}` -- true (passes) unless the
/// body contains a `---`...`---` pair, outside fenced code, whose lines in
/// between include at least one real `key: value` line (reusing
/// `core_query.topLevelKeyValue`, the same column-0 shape every other
/// frontmatter-line reader in this codebase already agrees on). That
/// combination -- not a lone `---` prose divider, not a fenced block
/// quoting YAML as an example -- is the corruption this rule exists to
/// catch: a bogus frontmatter-shaped fragment pasted into the body, past
/// the real one. `body.prose` is already everything *after* the real
/// frontmatter block by construction (`dataTree` strips it before this
/// operator ever sees the text), so nothing here has to re-exclude it.
fn evalNoStrayFrontmatter(args: []const std.json.Value, data: std.json.Value, current_item: ?std.json.Value, ops: ?[]const jsonlogic.CustomOp) jsonlogic.Error!std.json.Value {
    if (args.len < 1) return jsonlogic.Error.InvalidArguments;
    const text_v = try jsonlogic.evaluate(args[0], data, current_item, ops);
    const text = switch (text_v) {
        .string => |s| s,
        else => return .{ .bool = true },
    };

    var in_fence = false;
    var block_open = false;
    var saw_kv = false;
    var offset: usize = 0;
    while (offset <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..end], "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const is_fence_delimiter = std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");

        if (is_fence_delimiter) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            if (std.mem.eql(u8, line, "---")) {
                if (block_open and saw_kv) return .{ .bool = false };
                block_open = !block_open;
                saw_kv = false;
            } else if (block_open) {
                if (core_query.topLevelKeyValue(line)) |kv| {
                    if (kv.value.len > 0) saw_kv = true;
                }
            }
        }

        if (end == text.len) break;
        offset = end + 1;
    }
    return .{ .bool = true };
}

/// Null means unresolvable -- the field is absent, not a string, or `ref`
/// itself isn't a reference form this v1 language knows. Distinct from a
/// resolved-but-empty string on purpose: a check comparing two absent
/// fields must refuse, not silently treat "" as equal to itself.
fn resolveRef(gpa: Allocator, note: []const u8, path: []const u8, ref: []const u8) !?[]u8 {
    if (std.mem.eql(u8, ref, "filename.stem")) return try gpa.dupe(u8, filenameStem(path));
    if (!std.mem.startsWith(u8, ref, "frontmatter.")) return null;
    const field = ref["frontmatter.".len..];
    var lookup = try lookupField(gpa, note, field);
    defer lookup.deinit(gpa);
    return switch (lookup.value) {
        .string => |s| try gpa.dupe(u8, s),
        else => null,
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

/// RFC3339: `YYYY-MM-DDTHH:MM:SS` then either `Z` or a colon-separated
/// numeric offset (`+02:00`/`-05:00`) -- the exact shape `zeit`'s own
/// `"2006-01-02T15:04:05Z07:00"` gofmt writes. A bare numeric offset with no
/// colon (`+0200`, what `strftime`'s `%z` would write) is deliberately not
/// accepted: nothing in this codebase ever writes that shape, and accepting
/// it too would just be an unused second way to spell the same thing.
fn validTimestamp(value: []const u8) bool {
    if (value.len < 20) return false;
    const digits = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (digits) |i| if (!std.ascii.isDigit(value[i])) return false;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return false;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return false;

    const zone = value[19..];
    if (std.mem.eql(u8, zone, "Z")) return true;
    if (zone.len != 6 or (zone[0] != '+' and zone[0] != '-') or zone[3] != ':') return false;
    if (!std.ascii.isDigit(zone[1]) or !std.ascii.isDigit(zone[2])) return false;
    if (!std.ascii.isDigit(zone[4]) or !std.ascii.isDigit(zone[5])) return false;
    const off_hour = std.fmt.parseInt(u8, zone[1..3], 10) catch return false;
    const off_minute = std.fmt.parseInt(u8, zone[4..6], 10) catch return false;
    return off_hour <= 23 and off_minute <= 59;
}

/// Days since 1970-01-01 for a civil (year, month, day) date -- Howard
/// Hinnant's `days_from_civil`, pure integer arithmetic. Written out here
/// rather than reached through `std.time` or a date library: `core` may
/// only reach the system through an injected `Io` (`ci/check-layering.sh`
/// rejects a bare `std.time`, and `zeit` itself lives in `adapters`, which
/// `core` has no import edge to at all) -- and this needs no such reach in
/// the first place, since it is 100% closed-form arithmetic.
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(@as(i64, month) + 9, 12); // [0, 11], Mar=0 .. Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Seconds since an arbitrary but fixed reference point (not necessarily
/// the real Unix epoch -- self-consistent is all a comparison needs), from
/// an RFC3339 string already known to satisfy `validTimestamp`. Offset-aware,
/// so two values with different offsets compare correctly by real elapsed
/// time rather than by local wall-clock digits -- the DST "fall back" case
/// two RFC3339 strings can share the same local reading with different
/// offsets, sorting backwards if compared as raw text instead.
fn parseInstantSeconds(value: []const u8) ?i64 {
    if (!validTimestamp(value)) return null;
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, value[17..19], 10) catch return null;

    const zone = value[19..];
    const offset_seconds: i64 = if (std.mem.eql(u8, zone, "Z")) 0 else blk: {
        const sign: i64 = if (zone[0] == '+') 1 else -1;
        const off_hour = std.fmt.parseInt(i64, zone[1..3], 10) catch return null;
        const off_minute = std.fmt.parseInt(i64, zone[4..6], 10) catch return null;
        break :blk sign * (off_hour * 3600 + off_minute * 60);
    };

    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + minute * 60 + second - offset_seconds;
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
    "  - eq:\n" ++
    "      - var: filename.stem\n" ++
    "      - var: frontmatter.title\n" ++
    "  - on_create:\n" ++
    "      var: id_is_unique\n" ++
    "  - all:\n" ++
    "      - var: frontmatter.tags\n" ++
    "      - in:\n" ++
    "          - var: ''\n" ++
    "          - var: vocabularies.synapse-tag-vocabulary\n" ++
    "  - lte:\n" ++
    "      - var: created_epoch\n" ++
    "      - var: updated_epoch\n" ++
    "  - on_create:\n" ++
    "      eq:\n" ++
    "        - var: created_epoch\n" ++
    "        - var: updated_epoch\n";

test "validates a bare note with flow-style tags" {
    var doc = try schema_yaml.parse(testing.allocator, bare_schema);
    defer doc.deinit();
    try testing.expectEqual(@as(?[]u8, null), try validateSchema(testing.allocator, doc.root, "vault-note/v1"));
    const note =
        "---\n" ++
        "schema: vault-note/v1\n" ++
        "title: Example\n" ++
        "note_id: sb-081\n" ++
        "created: '2026-08-30T10:00:00+02:00'\n" ++
        "updated: '2026-08-30T10:00:00+02:00'\n" ++
        "tags: [synapse, architecture]\n" ++
        "extra: preserved\n" ++
        "---\n\n# Example\n\n## Summary\nUseful.\n";
    try testing.expectEqual(@as(?[]u8, null), try validateNote(testing.allocator, doc.root, note, "research/Example.md", .{
        .mode = .create,
        .vocabularies = &.{.{ .stem = "synapse-tag-vocabulary", .content = "synapse\narchitecture\n" }},
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
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\ncreated: '2026-08-30T10:00:00+02:00'\nupdated: '2026-08-30T10:00:00+02:00'\ntags: []\n---\n# Example\n## Summary\nOld\n";
    const changed =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-999\ncreated: '2026-08-30T10:00:00+02:00'\nupdated: '2026-08-30T11:00:00+02:00'\ntags: []\n---\n# Example\n## Summary\nNew\n";
    const message = (try validateNote(testing.allocator, doc.root, changed, "research/Example.md", .{
        .mode = .update,
        .existing = existing,
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

test "validTimestamp accepts RFC3339 with Z or a colon offset, rejects the old shape and a bare numeric offset" {
    try testing.expect(validTimestamp("2026-09-06T21:29:16Z"));
    try testing.expect(validTimestamp("2026-09-06T21:29:16+02:00"));
    try testing.expect(validTimestamp("2026-09-06T21:29:16-05:30"));
    try testing.expect(!validTimestamp("2026-09-06 21:29:16 CEST")); // the old shape
    try testing.expect(!validTimestamp("2026-09-06T21:29:16+0200")); // no colon (strftime %z's shape)
    try testing.expect(!validTimestamp("2026-09-06T25:00:00Z")); // hour out of range
    try testing.expect(!validTimestamp("2026-09-06T21:29:16+24:00")); // offset hour out of range
    try testing.expect(!validTimestamp("2026-09-06T21:29:16")); // no zone at all
}

test "parseInstantSeconds agrees across equivalent offsets and rejects a malformed value" {
    // Same real instant, two different offsets -- must parse to the same
    // total, the property `not_before`'s comparison actually depends on.
    try testing.expectEqual(
        parseInstantSeconds("2026-09-06T21:29:16Z").?,
        parseInstantSeconds("2026-09-06T23:29:16+02:00").?,
    );
    try testing.expectEqual(@as(?i64, null), parseInstantSeconds("not a timestamp"));
}

test "lte on created_epoch/updated_epoch fails when a timestamp field is missing, not silently passing" {
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
        "  - lte:\n" ++
        "      - var: created_epoch\n" ++
        "      - var: updated_epoch\n" ++
        "    message: 'frontmatter.updated: must not precede frontmatter.created'\n";
    try expectNoteMessage(source, "---\ntitle: Example\n---\n# Example\n", "x.md", .{ .mode = .create }, "frontmatter.updated: must not precede frontmatter.created");
}

test "eq on two missing fields returns true, matching JsonLogic null semantics -- presence must be composed explicitly" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: t/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "    a:\n" ++
        "      type: string\n" ++
        "      required: false\n" ++
        "    b:\n" ++
        "      type: string\n" ++
        "      required: false\n" ++
        "body:\n" ++
        "  h1:\n" ++
        "    required: true\n" ++
        "checks:\n" ++
        "  - eq:\n" ++
        "      - var: frontmatter.a\n" ++
        "      - var: frontmatter.b\n" ++
        "    message: 'frontmatter.a: must equal frontmatter.b'\n";
    // Both absent: null == null, so this passes -- a schema wanting to
    // require presence first composes that explicitly (e.g. `ne: [{var:
    // frontmatter.a}, null]`), it isn't implied by `eq` alone.
    try expectNoteOk(source, "---\ntitle: Example\n---\n# Example\n", "x.md", .{ .mode = .create });
    // Present and equal: passes.
    try expectNoteOk(source, "---\ntitle: Example\na: x\nb: x\n---\n# Example\n", "x.md", .{ .mode = .create });
    // One present, one missing: refused, null does not equal "x".
    try expectNoteMessage(source, "---\ntitle: Example\na: x\n---\n# Example\n", "x.md", .{ .mode = .create }, "frontmatter.a: must equal frontmatter.b");
}

test "lte on created_epoch/updated_epoch rejects an updated timestamp that precedes created, and accepts the reverse" {
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
        "  - lte:\n" ++
        "      - var: created_epoch\n" ++
        "      - var: updated_epoch\n" ++
        "    message: 'frontmatter.updated: must not precede frontmatter.created'\n";
    try expectNoteMessage(source,
        "---\ntitle: Example\nupdated: '2026-08-30T01:00:00+02:00'\ncreated: '2026-08-30T02:00:00+02:00'\n---\n# Example\n",
        "x.md", .{ .mode = .create }, "frontmatter.updated: must not precede frontmatter.created");
    try expectNoteOk(source,
        "---\ntitle: Example\nupdated: '2026-08-30T02:00:00+02:00'\ncreated: '2026-08-30T01:00:00+02:00'\n---\n# Example\n",
        "x.md", .{ .mode = .create });
}

test "lte on created_epoch/updated_epoch compares real instants across a DST fall-back, not raw text" {
    // 2026-10-25T02:30:00+02:00 and 2026-10-25T02:30:00+01:00 share the
    // same local wall-clock reading but are an hour apart in real terms
    // (the EU's fall-back transition) -- "+01:00" < "+02:00" lexically, so
    // a plain string compare would get this backwards.
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
        "  - lte:\n" ++
        "      - var: created_epoch\n" ++
        "      - var: updated_epoch\n" ++
        "    message: 'frontmatter.updated: must not precede frontmatter.created'\n";
    // created before the transition, updated an hour later (after it) --
    // genuinely later in real terms, so this must pass.
    try expectNoteOk(source,
        "---\ntitle: Example\nupdated: '2026-10-25T02:30:00+01:00'\ncreated: '2026-10-25T02:30:00+02:00'\n---\n# Example\n",
        "x.md", .{ .mode = .create });
    // Reversed: updated is genuinely earlier in real terms now, so this
    // must be rejected -- a byte-prefix compare would have accepted it.
    try expectNoteMessage(source,
        "---\ntitle: Example\nupdated: '2026-10-25T02:30:00+02:00'\ncreated: '2026-10-25T02:30:00+01:00'\n---\n# Example\n",
        "x.md", .{ .mode = .create }, "frontmatter.updated: must not precede frontmatter.created");
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
        "  - on_create:\n" ++
        "      eq:\n" ++
        "        - var: frontmatter.status\n" ++
        "        - TODO\n" ++
        "    message: \"frontmatter.status: must equal 'TODO' on creation\"\n";
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
        "  - all:\n" ++
        "      - var: frontmatter.tags\n" ++
        "      - in:\n" ++
        "          - var: ''\n" ++
        "          - var: vocabularies.synapse-tag-vocabulary\n" ++
        "    message: \"frontmatter.tags: not in synapse-tag-vocabulary.conf\"\n";
    try expectNoteMessage(source, "---\ntitle: Example\ntags: [synapse, nope]\n---\n# Example\n", "x.md", .{
        .mode = .create,
        .vocabularies = &.{.{ .stem = "synapse-tag-vocabulary", .content = "synapse\narchitecture\n" }},
    }, "frontmatter.tags: not in synapse-tag-vocabulary.conf");
    try expectNoteOk(source, "---\ntitle: Example\ntags: [synapse]\n---\n# Example\n", "x.md", .{
        .mode = .create,
        .vocabularies = &.{.{ .stem = "synapse-tag-vocabulary", .content = "synapse\narchitecture\n" }},
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
    const findings = try lintNote(gpa, doc.root, note, path);
    defer gpa.free(findings);
    const messages = try gpa.alloc([]u8, findings.len);
    for (findings, 0..) |f, i| messages[i] = f.message;
    return messages;
}

fn freeLintFindings(gpa: Allocator, findings: []const []const u8) void {
    for (findings) |f| gpa.free(f);
    gpa.free(findings);
}

const lint_test_frontmatter =
    "frontmatter:\n  fields:\n    title:\n      type: string\n    task_id:\n      type: string\n";

test "schema.lints rejects a second rule-shaped key as ambiguous" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: warn\n    extra: 1\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0]: exactly one rule operator is required", message);
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
    try testing.expectEqualStrings("schema.lints[0]: exactly one rule operator is required", message);
}

test "schema.lints rejects an unknown operator name at load time" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - not_a_real_operator:\n      var: body.prose\n    severity: warn\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0]: unknown operator 'not_a_real_operator'", message);
}

test "schema.lints.severity accepts ignore, warn, and error; rejects anything else" {
    for ([_][]const u8{ "ignore", "warn", "error" }) |severity| {
        const source = try std.fmt.allocPrint(testing.allocator, "schema: synapse-note-schema/v1\nid: t/v1\n" ++
            lint_test_frontmatter ++
            "body:\n  h1:\n    required: false\n" ++
            "checks: []\n" ++
            "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: {s}\n", .{severity});
        defer testing.allocator.free(source);
        var doc = try schema_yaml.parse(testing.allocator, source);
        defer doc.deinit();
        try testing.expectEqual(@as(?[]u8, null), try validateSchema(testing.allocator, doc.root, "t/v1"));
    }

    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: critical\n";
    var doc = try schema_yaml.parse(testing.allocator, source);
    defer doc.deinit();
    const message = (try validateSchema(testing.allocator, doc.root, "t/v1")).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("schema.lints[0].severity: unsupported value 'critical'", message);
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
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: warn\n";

    const wrapped = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a sentence that got\nhard-wrapped across two lines.\n";
    const findings = try lintFindings(testing.allocator, source, wrapped, "x.md");
    defer freeLintFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "no_hard_wrap") != null);

    const clean = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is one continuous line, exactly as the convention wants.\n";
    const clean_findings = try lintFindings(testing.allocator, source, clean, "x.md");
    defer testing.allocator.free(clean_findings);
    try testing.expectEqual(@as(usize, 0), clean_findings.len);
}

test "severity: ignore skips the rule entirely, not just discards its finding" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: ignore\n";
    const wrapped = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a sentence that got\nhard-wrapped across two lines.\n";
    const findings = try lintFindings(testing.allocator, source, wrapped, "x.md");
    defer freeLintFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "lintNote tags each finding with its own rule's severity" {
    var doc = try schema_yaml.parse(testing.allocator, "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: error\n");
    defer doc.deinit();
    const wrapped = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a sentence that got\nhard-wrapped across two lines.\n";
    const findings = try lintNote(testing.allocator, doc.root, wrapped, "x.md");
    defer {
        for (findings) |f| testing.allocator.free(f.message);
        testing.allocator.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Severity.@"error", findings[0].severity);
}

test "no_hard_wrap excludes table rows, list continuations, and fenced code" {
    const source = "schema: synapse-note-schema/v1\nid: t/v1\n" ++
        lint_test_frontmatter ++
        "body:\n  h1:\n    required: false\n" ++
        "checks: []\n" ++
        "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: warn\n";

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
        "lints:\n  - no_id_prefix_in_title:\n      - var: frontmatter.title\n      - var: frontmatter.task_id\n    severity: warn\n";

    const prefixed = "---\ntitle: \"sb-102 — Something\"\ntask_id: sb-102\n---\n# X\n";
    const findings = try lintFindings(testing.allocator, source, prefixed, "x.md");
    defer freeLintFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "no_id_prefix_in_title") != null);

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
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\ncreated: '2026-08-30T10:00:00+02:00'\nupdated: '2026-08-30T10:00:00+02:00'\ntags: []\n---\n# Example\n## Summary\nNew\n";
    const message = (try validateNote(testing.allocator, doc.root, candidate, "research/Example.md", .{
        .mode = .migration,
        .existing = existing,
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

test "dataTree: path, frontmatter, body.prose, and body.section_names all come through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\nstatus: REVIEW\n---\n# X\n\n## Summary\nSome prose.\n\n## Notes\nMore prose.\n";
    const tree = try dataTree(gpa, "tasks/synapse/X.md", note, .{ .mode = .update });

    try testing.expectEqualStrings("tasks/synapse/X.md", tree.object.get("path").?.string);
    try testing.expectEqualStrings("REVIEW", tree.object.get("frontmatter").?.object.get("status").?.string);

    const body = tree.object.get("body").?.object;
    try testing.expect(std.mem.startsWith(u8, body.get("prose").?.string, "# X\n"));
    try testing.expect(std.mem.indexOf(u8, body.get("prose").?.string, "title: X") == null);

    const sections = body.get("section_names").?.array.items;
    try testing.expectEqual(@as(usize, 3), sections.len);
    try testing.expectEqualStrings("X", sections[0].string);
    try testing.expectEqualStrings("Summary", sections[1].string);
    try testing.expectEqualStrings("Notes", sections[2].string);
}

test "dataTree: a legacy note with no frontmatter block treats the whole note as body.prose" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "# Just a heading\n\nNo frontmatter here at all.\n";
    const tree = try dataTree(gpa, "notes/legacy.md", note, .{ .mode = .update });

    try testing.expectEqualStrings(note, tree.object.get("body").?.object.get("prose").?.string);
    const sections = tree.object.get("body").?.object.get("section_names").?.array.items;
    try testing.expectEqual(@as(usize, 1), sections.len);
    try testing.expectEqualStrings("Just a heading", sections[0].string);
}

test "dataTree: output evaluates directly through jsonlogic, the whole point of building it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\nstatus: REVIEW\n---\n# X\n\n## Notes\nDone.\n";
    const tree = try dataTree(gpa, "tasks/synapse/X.md", note, .{ .mode = .update });

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"or": [{"!=": [{"var": "frontmatter.status"}, "REVIEW"]}, {"in": ["Notes", {"var": "body.section_names"}]}]}
    , .{});
    defer rule.deinit();

    const result = try jsonlogic.evaluate(rule.value, tree, null, null);
    try testing.expect(result.bool);
}

test "dataTree: is_create is true for create and migration, false for update" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const note = "---\ntitle: X\n---\n# X\n";

    const created = try dataTree(gpa, "x.md", note, .{ .mode = .create });
    try testing.expect(created.object.get("is_create").?.bool);

    const migrated = try dataTree(gpa, "x.md", note, .{ .mode = .migration });
    try testing.expect(migrated.object.get("is_create").?.bool);

    const updated = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    try testing.expect(!updated.object.get("is_create").?.bool);
}

test "dataTree: id_is_unique is a real bool on create, and null (not false) on an ordinary update" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const note = "---\ntitle: X\n---\n# X\n";

    const unique = try dataTree(gpa, "x.md", note, .{ .mode = .create, .duplicate_identity = null });
    try testing.expect(unique.object.get("id_is_unique").?.bool);

    const dup = try dataTree(gpa, "x.md", note, .{ .mode = .create, .duplicate_identity = "sb-001" });
    try testing.expect(!dup.object.get("id_is_unique").?.bool);

    // Not computed on a plain update -- null, never a stale/reused false.
    const not_computed = try dataTree(gpa, "x.md", note, .{ .mode = .update, .duplicate_identity = null });
    try testing.expectEqual(std.json.Value.null, not_computed.object.get("id_is_unique").?);
}

test "dataTree: created_epoch/updated_epoch parse real timestamps, and stay null when missing or malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const good = "---\ntitle: X\ncreated: \"2026-09-07T15:00:00Z\"\nupdated: \"2026-09-07T15:05:00Z\"\n---\n# X\n";
    const tree = try dataTree(gpa, "x.md", good, .{ .mode = .update });
    const created_epoch = tree.object.get("created_epoch").?.integer;
    const updated_epoch = tree.object.get("updated_epoch").?.integer;
    try testing.expect(updated_epoch > created_epoch);

    const missing = "---\ntitle: X\n---\n# X\n";
    const missing_tree = try dataTree(gpa, "x.md", missing, .{ .mode = .update });
    try testing.expectEqual(std.json.Value.null, missing_tree.object.get("created_epoch").?);

    const malformed = "---\ntitle: X\ncreated: not-a-timestamp\n---\n# X\n";
    const malformed_tree = try dataTree(gpa, "x.md", malformed, .{ .mode = .update });
    try testing.expectEqual(std.json.Value.null, malformed_tree.object.get("created_epoch").?);
}

test "dataTree: not_before composes directly from created_epoch/updated_epoch with lte, no operator needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\ncreated: \"2026-09-07T15:00:00Z\"\nupdated: \"2026-09-07T15:05:00Z\"\n---\n# X\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"<=": [{"var": "created_epoch"}, {"var": "updated_epoch"}]}
    , .{});
    defer rule.deinit();

    const result = try jsonlogic.evaluate(rule.value, tree, null, null);
    try testing.expect(result.bool);
}

test "dataTree: vocabularies is keyed by stem, one plain-line file and one key=value file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\n---\n# X\n";
    const context = Context{
        .mode = .update,
        .vocabularies = &.{
            .{ .stem = "synapse-tag-vocabulary", .content = "synapse\nvault-infra\n# a comment\n\narchitecture\n" },
            .{ .stem = "synapse-projects", .content = "synapse=sb\neon=eon\n" },
        },
    };
    const tree = try dataTree(gpa, "x.md", note, context);

    const vocabs = tree.object.get("vocabularies").?.object;
    const tags = vocabs.get("synapse-tag-vocabulary").?.array.items;
    try testing.expectEqual(@as(usize, 3), tags.len);
    try testing.expectEqualStrings("synapse", tags[0].string);
    try testing.expectEqualStrings("vault-infra", tags[1].string);
    try testing.expectEqualStrings("architecture", tags[2].string);

    // key=value lines contribute only the value, the same distinction
    // vocabularyContains's own `projection: values` flag used to need a
    // schema author to declare per rule.
    const projects = vocabs.get("synapse-projects").?.array.items;
    try testing.expectEqual(@as(usize, 2), projects.len);
    try testing.expectEqualStrings("sb", projects[0].string);
    try testing.expectEqualStrings("eon", projects[1].string);
}

test "dataTree: vocabularies is an empty object when the context supplies none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\n---\n# X\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    try testing.expectEqual(@as(usize, 0), tree.object.get("vocabularies").?.object.count());
}

test "dataTree: vocabularies composes directly through all/in, the real end-to-end shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\ntags: [synapse, vault-infra]\n---\n# X\n";
    const context = Context{
        .mode = .update,
        .vocabularies = &.{
            .{ .stem = "synapse-tag-vocabulary", .content = "synapse\nvault-infra\narchitecture\n" },
        },
    };
    const tree = try dataTree(gpa, "x.md", note, context);

    var rule2 = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"all": [{"var": "frontmatter.tags"}, {"in": [{"var": ""}, {"var": "vocabularies.synapse-tag-vocabulary"}]}]}
    , .{});
    defer rule2.deinit();

    const result = try jsonlogic.evaluate(rule2.value, tree, null, null);
    try testing.expect(result.bool);
}

test "on_create delegates to its argument when is_create is true" {
    var pass = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"on_create": {"var": "n"}}
    , .{});
    defer pass.deinit();
    var data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"is_create": true, "n": true}
    , .{});
    defer data.deinit();
    const got = try jsonlogic.evaluate(pass.value, data.value, null, &custom_ops);
    try testing.expect(got.bool);

    var fail = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"on_create": {"var": "n"}}
    , .{});
    defer fail.deinit();
    var fail_data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"is_create": true, "n": false}
    , .{});
    defer fail_data.deinit();
    const got_fail = try jsonlogic.evaluate(fail.value, fail_data.value, null, &custom_ops);
    try testing.expect(!got_fail.bool);
}

test "on_create short-circuits to truthy without evaluating its argument when is_create is false" {
    // The wrapped rule names an unknown operator -- if on_create ever
    // evaluated it, this would error instead of passing.
    var rule = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"on_create": {"this_operator_does_not_exist": 1}}
    , .{});
    defer rule.deinit();
    var data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"is_create": false}
    , .{});
    defer data.deinit();
    const got = try jsonlogic.evaluate(rule.value, data.value, null, &custom_ops);
    try testing.expect(got.bool);
}

test "on_create short-circuits the same way when is_create is absent from data entirely" {
    var rule = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"on_create": {"this_operator_does_not_exist": 1}}
    , .{});
    defer rule.deinit();
    const got = try jsonlogic.evaluate(rule.value, .{ .object = .empty }, null, &custom_ops);
    try testing.expect(got.bool);
}

test "on_create composes through the real data tree: unique-note-id and created==updated shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\ncreated: \"2026-09-07T15:00:00Z\"\nupdated: \"2026-09-07T15:00:00Z\"\n---\n# X\n";

    // A duplicate id on create: on_create: {var: id_is_unique} must fail.
    const dup_tree = try dataTree(gpa, "x.md", note, .{ .mode = .create, .duplicate_identity = "sb-001" });
    var unique_rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"on_create": {"var": "id_is_unique"}}
    , .{});
    defer unique_rule.deinit();
    const dup_result = try jsonlogic.evaluate(unique_rule.value, dup_tree, null, &custom_ops);
    try testing.expect(!dup_result.bool);

    // Unique on create: same rule must pass.
    const ok_tree = try dataTree(gpa, "x.md", note, .{ .mode = .create, .duplicate_identity = null });
    const ok_result = try jsonlogic.evaluate(unique_rule.value, ok_tree, null, &custom_ops);
    try testing.expect(ok_result.bool);

    // created == updated on create: on_create: {eq: [created_epoch, updated_epoch]}.
    var eq_rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"on_create": {"==": [{"var": "created_epoch"}, {"var": "updated_epoch"}]}}
    , .{});
    defer eq_rule.deinit();
    const eq_result = try jsonlogic.evaluate(eq_rule.value, ok_tree, null, &custom_ops);
    try testing.expect(eq_result.bool);

    // Same rule on an ordinary update: created != updated is fine now,
    // since on_create never evaluates it at all.
    const updated_note = "---\ntitle: X\ncreated: \"2026-09-07T15:00:00Z\"\nupdated: \"2026-09-07T16:00:00Z\"\n---\n# X\n";
    const update_tree = try dataTree(gpa, "x.md", updated_note, .{ .mode = .update });
    const update_result = try jsonlogic.evaluate(eq_rule.value, update_tree, null, &custom_ops);
    try testing.expect(update_result.bool);
}

test "no_hard_wrap custom operator: fires on a wrapped paragraph, stays silent on a clean one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_hard_wrap": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const wrapped = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a sentence that got\nhard-wrapped across two lines.\n";
    const wrapped_tree = try dataTree(gpa, "x.md", wrapped, .{ .mode = .update });
    const wrapped_result = try jsonlogic.evaluate(rule.value, wrapped_tree, null, &custom_ops);
    try testing.expect(!wrapped_result.bool);

    const clean = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is one continuous line, exactly as the convention wants.\n";
    const clean_tree = try dataTree(gpa, "x.md", clean, .{ .mode = .update });
    const clean_result = try jsonlogic.evaluate(rule.value, clean_tree, null, &custom_ops);
    try testing.expect(clean_result.bool);
}

test "no_hard_wrap custom operator: excludes fenced code, matching the old function exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_hard_wrap": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const fenced = "---\ntitle: X\n---\n# X\n\n## Summary\n```\ntwo\nlines\n```\n";
    const tree = try dataTree(gpa, "x.md", fenced, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "no_hard_wrap custom operator composes with and/or, unlike the old standalone-only lint entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"and": [{"no_hard_wrap": {"var": "body.prose"}}, {"==": [{"var": "frontmatter.status"}, "Ready"]}]}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\nstatus: Ready\n---\n# X\n\n## Summary\nOne continuous line.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "no_id_prefix_in_title custom operator: fires when the title starts with its own id, silent otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_id_prefix_in_title": [{"var": "frontmatter.title"}, {"var": "frontmatter.task_id"}]}
    , .{});
    defer rule.deinit();

    const prefixed = "---\ntitle: \"sb-102 — Something\"\ntask_id: sb-102\n---\n# X\n";
    const prefixed_tree = try dataTree(gpa, "x.md", prefixed, .{ .mode = .update });
    const prefixed_result = try jsonlogic.evaluate(rule.value, prefixed_tree, null, &custom_ops);
    try testing.expect(!prefixed_result.bool);

    const clean = "---\ntitle: Something\ntask_id: sb-102\n---\n# X\n";
    const clean_tree = try dataTree(gpa, "x.md", clean, .{ .mode = .update });
    const clean_result = try jsonlogic.evaluate(rule.value, clean_tree, null, &custom_ops);
    try testing.expect(clean_result.bool);
}

test "no_id_prefix_in_title custom operator passes vacuously when the id field is empty or missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_id_prefix_in_title": [{"var": "frontmatter.title"}, {"var": "frontmatter.task_id"}]}
    , .{});
    defer rule.deinit();

    const no_id = "---\ntitle: Something\n---\n# X\n";
    const tree = try dataTree(gpa, "x.md", no_id, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "hard_wrap custom operator: passes a correctly greedy-wrapped paragraph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}, 20]}
    , .{});
    defer rule.deinit();

    // Greedy-nearest-fit at width 20: "This is a test of hard" (22, the
    // boundary word "hard" overshoots by 2 but landed nearer than the 3
    // it would have undershot by stopping at "of") / "wrap logic here."
    const note = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a test of hard\nwrap logic here.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "hard_wrap custom operator: fails a paragraph reflowed too early (stopped before the nearer boundary word)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}, 20]}
    , .{});
    defer rule.deinit();

    // "hard" belongs on line 1 (nearer at 22 than stopping at 17) but was
    // pushed to line 2 instead.
    const note = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a test of\nhard wrap logic here.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(!result.bool);
}

test "hard_wrap custom operator: fails a paragraph padded past the boundary word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}, 20]}
    , .{});
    defer rule.deinit();

    // "wrap" was also packed onto line 1, past where the boundary-word
    // decision should have stopped it.
    const note = "---\ntitle: X\n---\n# X\n\n## Summary\nThis is a test of hard wrap\nlogic here.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(!result.bool);
}

test "hard_wrap custom operator: excludes fenced code, matching no_hard_wrap's own exclusions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}, 20]}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\n---\n# X\n\n## Summary\n```\nnot wrapped\nat all\n```\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "hard_wrap custom operator: max_chars must be a positive integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const note = "---\ntitle: X\n---\n# X\n\n## Summary\nShort.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });

    var missing = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}]}
    , .{});
    defer missing.deinit();
    try testing.expectError(jsonlogic.Error.InvalidArguments, jsonlogic.evaluate(missing.value, tree, null, &custom_ops));

    var zero = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"hard_wrap": [{"var": "body.prose"}, 0]}
    , .{});
    defer zero.deinit();
    try testing.expectError(jsonlogic.Error.InvalidArguments, jsonlogic.evaluate(zero.value, tree, null, &custom_ops));
}

test "no_stray_frontmatter custom operator: fails on a bogus frontmatter-shaped block pasted into the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_stray_frontmatter": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\n---\n# X\n\nSome prose.\n\n---\nleftover: fragment\n---\n\nMore prose.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(!result.bool);
}

test "no_stray_frontmatter custom operator: a lone --- prose divider never triggers it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_stray_frontmatter": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\n---\n# X\n\nAbove the divider.\n\n---\n\nBelow the divider.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "no_stray_frontmatter custom operator: a fenced block quoting frontmatter as an example is excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_stray_frontmatter": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\n---\n# X\n\nExample:\n\n```\n---\nkey: value\n---\n```\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}

test "no_stray_frontmatter custom operator: a clean note with no stray block at all passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var rule = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"no_stray_frontmatter": {"var": "body.prose"}}
    , .{});
    defer rule.deinit();

    const note = "---\ntitle: X\n---\n# X\n\nJust ordinary prose, nothing stray.\n";
    const tree = try dataTree(gpa, "x.md", note, .{ .mode = .update });
    const result = try jsonlogic.evaluate(rule.value, tree, null, &custom_ops);
    try testing.expect(result.bool);
}
