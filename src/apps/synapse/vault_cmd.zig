//! `synapse vault-read`/`vault-write`/`vault-list`/`vault-search`/
//! `vault-search-text`/`vault-doc-map`/`vault-patch` -- the CLI door skills
//! use to reach `ports.Store` instead of calling any tool by name directly.
//! A skill's prose stays put across a backend swap, which then touches only
//! `resolveStore()` and the `Store` implementation, never skill text.
//!
//! Every subcommand addresses a note by its full vault-relative path (an
//! empty-namespace `Store`, the same convention `frontmatter get/set`
//! already uses) -- these are whole-vault tools, not scoped to one repo's
//! code-graph namespace.
//!
//!   vault-read <path>
//!   vault-write <path>                     body on stdin
//!   vault-list
//!   vault-search [--fields <f1,f2,...>]    JsonLogic rule on stdin
//!   vault-search-text <query> [--path-filter]
//!                                           full-text relevance search, optionally scoped by
//!                                           a JsonLogic path filter (`{"var": "path"}` only) on stdin
//!   vault-doc-map <path>                   headings/block ids/frontmatter keys
//!   vault-patch <path> --heading <h>|--block <id>|--frontmatter <key>
//!               [--append|--prepend|--replace] [--create]
//!                                           content on stdin
//!
//! `--heading`'s `<h>` is a `::`-joined path (`"Notes::Sub"`), disambiguating
//! a heading nested under a same-named parent from any other heading with
//! that name. `--replace` is the default operation when none is given.
//! `--create` only applies to
//! `--heading` (a missing frontmatter key is always inserted, by
//! `core.frontmatter.set`'s own existing behavior; a missing block cannot
//! be created -- there is no content to anchor an id to).
//!
//! `vault-search`'s rows print as `path<TAB>field1<TAB>field2...`, one row
//! per line -- a non-string field value is JSON-encoded so it stays one TSV
//! field. With no `--fields`, each row is just the path. It's a structured
//! JsonLogic filter over frontmatter/content/tags; for plain full-text
//! relevance search instead, `vault-search-text` wraps `Store`'s own
//! `search` method directly, one `node<TAB>score<TAB>context` row per hit.
//! `--path-filter` scopes that search to a subset of paths first -- the
//! stdin rule is expected to reference nothing but `path` (see
//! `ResolvedStore.searchFiltered`'s own doc comment for exactly what that
//! means per backend), and disqualified paths are never read at all.
//! `vault-doc-map` lists every heading path/block id/frontmatter key a
//! `vault-patch` target could name, one `kind<TAB>value` row per entry,
//! `kind` one of `heading`/`block`/`frontmatter`.
//!
//! Exit 1 for anything that made the operation impossible, 2 for a usage
//! error.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-vault";

const usage_text =
    \\usage: synapse vault-read <path>
    \\       synapse vault-write <path>                     body on stdin
    \\       synapse vault-list
    \\       synapse vault-check                        read-only conformance audit over schema-declaring notes
    \\       synapse vault-search [--fields <f1,f2,...>]     JsonLogic rule on stdin
    \\       synapse vault-search-text <query> [--path-filter]
    \\                                                       full-text relevance search, optionally
    \\                                                       scoped by a JsonLogic path filter on stdin
    \\       synapse vault-doc-map <path>                    headings/block ids/frontmatter keys
    \\       synapse vault-patch <path> --heading <h>|--block <id>|--frontmatter <key>
    \\                   [--append|--prepend|--replace] [--create]
    \\                                                       content on stdin
    \\       synapse vault-backlinks <path>                  node<TAB>count, per file linking to <path>
    \\       synapse vault-links <path>                      outgoing link targets from <path>
    \\       synapse vault-unresolved                        source<TAB>target<TAB>count, one row per broken link
    \\       synapse vault-orphans                           notes with no backlinks
    \\       synapse vault-deadends                          notes with no outgoing links
    \\       synapse vault-ambiguous                         source<TAB>target<TAB>candidate<TAB>count, one row per (source, target, candidate)
    \\       synapse vault-rename <old-path> <new-path>      moves a note and rewrites every referring wikilink,
    \\                                                       syncing its title:/H1 to the new filename
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

fn help() u8 {
    std.debug.print("{s}", .{usage_text});
    return 0;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn readStdin(gpa: Allocator, io: Io) ![]u8 {
    var in_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().reader(io, &in_buf);
    return in.interface.allocRemaining(gpa, .limited(64 << 20)) catch |e| switch (e) {
        error.ReadFailed => return error.StdinReadFailed,
        else => |other| return other,
    };
}

fn openWholeVaultStore(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, self_path: []const u8) !?adapters.store_resolve.ResolvedStore {
    return try adapters.store_resolve.resolveStore(gpa, io, env, vault, "", prog, self_path);
}

// --- Testable core, one function per subcommand -----------------------

pub fn read(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, path: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    const body = (store.read(gpa, io, path) catch {
        std.debug.print("{s}: read failed\n", .{prog});
        return 1;
    }) orelse {
        std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        return 1;
    };
    defer gpa.free(body);
    try result.writeAll(body);
    return 0;
}

pub fn write(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    body: []const u8,
    self_path: []const u8,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, self_path)) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    // Creation carries the one timestamp sampled by the authoring command. An
    // update's `updated` refresh happens inside the validation decorator, the
    // persistence boundary that already reads the existing note -- so this
    // command never pre-reads: no second read on an update.
    const wr = store.write(io, path, body) catch {
        std.debug.print("{s}: write failed\n", .{prog});
        return 1;
    };
    defer gpa.free(wr.body);
    if (!wr.accepted) {
        std.debug.print("{s}: write rejected ({d}): {s}\n", .{ prog, wr.status, wr.body });
        return 1;
    }
    try result.print("{s}\n", .{path});
    return 0;
}

pub fn list(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    const names = store.list(gpa, io) catch {
        std.debug.print("{s}: list failed\n", .{prog});
        return 1;
    };
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |n| try result.print("{s}\n", .{n});
    return 0;
}

/// Read-only conformance audit of the whole vault. One note at a time:
/// a note with no `schema` declaration is legacy and simply counted; a
/// note that declares one is resolved, loaded, and validated exactly as
/// `vault-write`'s persistence boundary would (`mode = .update` against its
/// own content, so mutable/unique/creation-only rules cannot fire against
/// a note that already exists). One `path\tmessage` row per violating
/// schema-declaring note, then a summary line. Exit 0 when every
/// schema-declaring note conforms, 1 when any does not -- legacy notes are
/// never a violation, only a count.
pub fn check(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();
    const vars = adapters.env.vars(env);

    const names = store.list(gpa, io) catch {
        std.debug.print("{s}: list failed\n", .{prog});
        return 1;
    };
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    // Loaded once for the whole run, not per note: on a real vault (20
    // schema-declaring notes) that was 20 redundant reads of the same 2
    // files instead of 2 total.
    const projects = try adapters.schema_validation_store.loadVocabularyText(gpa, io, vars, "synapse-projects.conf");
    defer if (projects) |text| gpa.free(text);
    const tags = try adapters.schema_validation_store.loadVocabularyText(gpa, io, vars, "synapse-tag-vocabulary.conf");
    defer if (tags) |text| gpa.free(text);

    var declared: usize = 0;
    var conformant: usize = 0;
    var legacy: usize = 0;
    var violations: usize = 0;
    var lint_notes: usize = 0;
    var lint_findings_total: usize = 0;
    var lint_buf: Io.Writer.Allocating = .init(gpa);
    defer lint_buf.deinit();
    for (names) |name| {
        const body = (store.read(gpa, io, name) catch continue) orelse continue;
        defer gpa.free(body);
        const schema_id = core.note_schema.schemaId(body) orelse {
            legacy += 1;
            continue;
        };
        declared += 1;

        var doc = adapters.schema_validation_store.loadSchemaDocument(gpa, io, vars, schema_id) catch |err| {
            try result.print("{s}\t{any}\n", .{ name, @errorName(err) });
            violations += 1;
            continue;
        };
        defer doc.deinit();
        if (try core.note_schema.validateSchema(gpa, doc.root, schema_id)) |message| {
            defer gpa.free(message);
            try result.print("{s}\t{s}\n", .{ name, message });
            violations += 1;
            continue;
        }
        if (try core.note_schema.validateNote(gpa, doc.root, body, name, .{
            .mode = .update,
            .existing = body,
            .projects_vocabulary = projects,
            .tags_vocabulary = tags,
        })) |message| {
            defer gpa.free(message);
            try result.print("{s}\t{s}\n", .{ name, message });
            violations += 1;
            continue;
        }
        conformant += 1;

        // Advisory only, and swept read-only exactly like the validation
        // pass above -- never folded into or confused with the
        // conformant/violation counts, and never affects this command's
        // exit code either.
        const findings = try core.note_schema.lintNote(gpa, doc.root, body, name);
        defer {
            for (findings) |f| gpa.free(f);
            gpa.free(findings);
        }
        if (findings.len > 0) {
            lint_notes += 1;
            for (findings) |finding| {
                try lint_buf.writer.print("{s}\t{s}\n", .{ name, finding });
                lint_findings_total += 1;
            }
        }
    }
    try result.print("{d} notes: {d} schema-declaring ({d} conformant, {d} violations), {d} legacy\n", .{ names.len, declared, conformant, violations, legacy });
    if (lint_findings_total > 0) {
        try result.print("\nLint (advisory, {d} finding(s) across {d} note(s)):\n", .{ lint_findings_total, lint_notes });
        try result.writeAll(lint_buf.written());
    }
    return if (violations == 0) 0 else 1;
}

/// Plain full-text relevance search, straight over `Store.search` (or, with
/// `path_filter`, `ResolvedStore.searchFiltered` -- see its own doc comment
/// for exactly what backends that scopes and how) -- distinct from `search`
/// below (which answers a structured JsonLogic filter instead). `null`
/// behaves exactly as before this parameter existed.
pub fn searchText(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    query: []const u8,
    path_filter: ?std.json.Value,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();

    const hits = resolved.searchFiltered(gpa, io, query, path_filter) catch {
        std.debug.print("{s}: search failed\n", .{prog});
        return 1;
    };
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }

    for (hits) |h| try result.print("{s}\t{d}\t{s}\n", .{ h.node, h.score, h.context });
    return 0;
}

/// Every heading path/block id/frontmatter key `note`'s body has, so a
/// caller can pick a real `vault-patch` target instead of guessing one.
pub fn docMap(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    const body = (store.read(gpa, io, path) catch {
        std.debug.print("{s}: read failed\n", .{prog});
        return 1;
    }) orelse {
        std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        return 1;
    };
    defer gpa.free(body);

    var map = try core.patch.documentMap(gpa, body);
    defer map.deinit(gpa);

    for (map.headings) |h| try result.print("heading\t{s}\n", .{h});
    for (map.blocks) |b| try result.print("block\t{s}\n", .{b});
    for (map.frontmatter_keys) |k| try result.print("frontmatter\t{s}\n", .{k});
    return 0;
}

/// `null` from `resolved.linkGraph()` means the resolved backend has no
/// `LinkGraph` of its own -- not a usage error: the caller asked a
/// well-formed question, this backend just can't answer it (true of Bard's
/// stores, not either real coding-vault backend).
/// The one safe way to reach a resolved store's `LinkGraph`: call
/// `.linkGraph()` on a `ResolvedStore` that is already sitting in its final,
/// stable location -- never on one still about to be moved. `LinkGraph.ptr`
/// is `&resolved.<backend>.link_graph`, a pointer *into* whatever `resolved`
/// this call receives; if that `resolved` is a local inside a helper that
/// then returns it by value (the shape this used to be), the returned copy
/// lives at a new address and the pointer captured before the move is left
/// dangling -- reads whatever the old stack slot gets reused for next,
/// which is silent right up until it isn't. Every call site below opens its
/// own `resolved` and asks it for a `LinkGraph` in the same breath, so the
/// address `.ptr` captures is the address `resolved` keeps for the rest of
/// the function.
fn openLinkGraph(resolved: *adapters.store_resolve.ResolvedStore) ports.LinkGraph {
    return resolved.linkGraph();
}

/// Same reasoning as `openLinkGraph`, for `Renamer`.
fn openRenamer(resolved: *adapters.store_resolve.ResolvedStore) ports.Renamer {
    return resolved.renamer();
}

pub fn backlinks(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, path: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const hits = link_graph.backlinks(gpa, io, path) catch {
        std.debug.print("{s}: backlinks failed\n", .{prog});
        return 1;
    };
    defer {
        for (hits) |h| gpa.free(h.node);
        gpa.free(hits);
    }
    for (hits) |h| try result.print("{s}\t{d}\n", .{ h.node, h.count });
    return 0;
}

pub fn links(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, path: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const names = link_graph.links(gpa, io, path) catch {
        std.debug.print("{s}: links failed\n", .{prog});
        return 1;
    };
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |n| try result.print("{s}\n", .{n});
    return 0;
}

/// One row per `(source, target)` pair -- the exact shape
/// `/synapse-vault-tidy`'s own "Broken link in `{note}`: → `{target}`"
/// finding needs, `sources` iterated rather than joined onto one row.
pub fn unresolved(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const rows = link_graph.unresolved(gpa, io) catch {
        std.debug.print("{s}: unresolved failed\n", .{prog});
        return 1;
    };
    defer {
        for (rows) |r| {
            gpa.free(r.target);
            for (r.sources) |s| gpa.free(s);
            gpa.free(r.sources);
        }
        gpa.free(rows);
    }
    for (rows) |r| {
        for (r.sources) |source| try result.print("{s}\t{s}\t{d}\n", .{ source, r.target, r.count });
    }
    return 0;
}

pub fn orphans(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const names = link_graph.orphans(gpa, io) catch {
        std.debug.print("{s}: orphans failed\n", .{prog});
        return 1;
    };
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |n| try result.print("{s}\n", .{n});
    return 0;
}

pub fn deadends(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const names = link_graph.deadends(gpa, io) catch {
        std.debug.print("{s}: deadends failed\n", .{prog});
        return 1;
    };
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |n| try result.print("{s}\n", .{n});
    return 0;
}

/// One row per `(source, target, candidate)` triple -- `count` (the total
/// occurrences of `target` across the vault) repeats per source, same
/// convention `unresolved`'s own rows already use.
pub fn ambiguous(gpa: Allocator, io: Io, env: *std.process.Environ.Map, vault: []const u8, result: *Io.Writer) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const link_graph = openLinkGraph(&resolved);

    const rows = link_graph.ambiguous(gpa, io) catch {
        std.debug.print("{s}: ambiguous failed\n", .{prog});
        return 1;
    };
    defer {
        for (rows) |r| {
            gpa.free(r.target);
            for (r.candidates) |c| gpa.free(c);
            gpa.free(r.candidates);
            for (r.sources) |s| gpa.free(s);
            gpa.free(r.sources);
        }
        gpa.free(rows);
    }
    for (rows) |r| {
        for (r.sources) |source| {
            for (r.candidates) |candidate| {
                try result.print("{s}\t{s}\t{s}\t{d}\n", .{ source, r.target, candidate, r.count });
            }
        }
    }
    return 0;
}

pub fn rename(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    old_path: []const u8,
    new_path: []const u8,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const renamer = openRenamer(&resolved);

    renamer.rename(gpa, io, old_path, new_path) catch |err| {
        if (err == error.NodeNotFound) {
            std.debug.print("{s}: no such note: {s}\n", .{ prog, old_path });
        } else {
            std.debug.print("{s}: rename failed\n", .{prog});
        }
        return 1;
    };
    try result.print("{s}\n", .{new_path});
    return 0;
}

pub fn search(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    query: std.json.Value,
    fields: []const []const u8,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, "")) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    const rows = core.vault_query.query(gpa, io, store, query, fields) catch {
        std.debug.print("{s}: query failed\n", .{prog});
        return 1;
    };
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }

    for (rows) |row| {
        try result.print("{s}", .{row.path});
        for (row.values) |v| {
            try result.writeByte('\t');
            try writeFieldValue(result, v);
        }
        try result.writeByte('\n');
    }
    return 0;
}

/// A string prints bare (no quotes, no TSV escaping -- a note path or
/// frontmatter scalar realistically never contains a tab or newline);
/// anything else prints as compact JSON, so a `tags` array or a missing
/// field (`null`) still lands in exactly one TSV column.
fn writeFieldValue(w: *Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

pub fn patch(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    path: []const u8,
    target: core.patch.Target,
    op: core.patch.Operation,
    create_if_missing: bool,
    content: []const u8,
    self_path: []const u8,
    result: *Io.Writer,
) !u8 {
    var resolved = (try openWholeVaultStore(gpa, io, env, vault, self_path)) orelse return 1;
    defer resolved.deinit();
    const store = resolved.store();

    const current = (store.read(gpa, io, path) catch {
        std.debug.print("{s}: read failed\n", .{prog});
        return 1;
    }) orelse {
        std.debug.print("{s}: no such note: {s}\n", .{ prog, path });
        return 1;
    };
    defer gpa.free(current);

    const patched = core.patch.apply(gpa, current, target, op, content, create_if_missing) catch |e| {
        switch (e) {
            error.TargetNotFound => std.debug.print("{s}: target not found in {s}\n", .{ prog, path }),
            error.NoFrontmatter => std.debug.print("{s}: no frontmatter in {s}\n", .{ prog, path }),
            else => std.debug.print("{s}: patch failed\n", .{prog}),
        }
        return 1;
    };
    defer gpa.free(patched);

    const wr = store.write(io, path, patched) catch {
        std.debug.print("{s}: write failed\n", .{prog});
        return 1;
    };
    defer gpa.free(wr.body);
    if (!wr.accepted) {
        std.debug.print("{s}: write rejected ({d}): {s}\n", .{ prog, wr.status, wr.body });
        return 1;
    }
    try result.print("{s}\n", .{path});
    return 0;
}

// --- argv/stdin plumbing, called from main.zig -------------------------

fn resolveVault(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !?[]u8 {
    return (try core.conf.vaultDir(gpa, io, adapters.env.vars(env))) orelse {
        std.debug.print("{s}: no vault\n", .{prog});
        return null;
    };
}

pub fn runRead(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try read(gpa, io, env, vault, path, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runWrite(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator, self_path: []const u8) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    const body = readStdin(gpa, io) catch {
        std.debug.print("{s}: could not read stdin\n", .{prog});
        return 1;
    };
    defer gpa.free(body);

    var out_buf: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try write(gpa, io, env, vault, path, body, self_path, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runList(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |a| {
        if (isHelp(a)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try list(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runCheck(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |arg| {
        if (isHelp(arg)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try check(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runSearchText(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const query = args.next() orelse return usage();
    if (isHelp(query)) return help();

    var want_path_filter = false;
    if (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--path-filter")) return usage();
        want_path_filter = true;
        if (args.next() != null) return usage();
    }

    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (want_path_filter) {
        const filter_text = readStdin(gpa, io) catch {
            std.debug.print("{s}: could not read stdin\n", .{prog});
            return 1;
        };
        defer gpa.free(filter_text);
        parsed = std.json.parseFromSlice(std.json.Value, gpa, filter_text, .{}) catch {
            std.debug.print("{s}: stdin is not valid JSON\n", .{prog});
            return 1;
        };
    }

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try searchText(gpa, io, env, vault, query, if (parsed) |p| p.value else null, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runDocMap(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try docMap(gpa, io, env, vault, path, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runBacklinks(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try backlinks(gpa, io, env, vault, path, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runLinks(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try links(gpa, io, env, vault, path, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runUnresolved(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |a| {
        if (isHelp(a)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try unresolved(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runOrphans(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |a| {
        if (isHelp(a)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try orphans(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runDeadends(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |a| {
        if (isHelp(a)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try deadends(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runAmbiguous(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |a| {
        if (isHelp(a)) return help();
        return usage();
    }
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try ambiguous(gpa, io, env, vault, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runRename(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    const old_path = args.next() orelse return usage();
    if (isHelp(old_path)) return help();
    const new_path = args.next() orelse return usage();
    if (args.next() != null) return usage();
    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    var out_buf: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try rename(gpa, io, env, vault, old_path, new_path, &out.interface);
    try out.interface.flush();
    return code;
}

/// `synapse vault-git-pusher <vault>` -- not registered as a hook or
/// documented in usage text, the same "not registered" shape
/// `synapse-hook vault-sync`/`vault-pull` already have. `GitStore.write()`
/// spawns this detached, passing the vault path it already resolved rather
/// than having this re-resolve one from the environment -- the caller
/// already knows exactly which vault it's working against.
pub fn runVaultGitPusher(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const vault = args.next() orelse return 2;
    adapters.git_store.runPusher(gpa, io, vault);
    return 0;
}

pub fn runSearch(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator) !u8 {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fields.deinit(gpa);

    while (args.next()) |arg| {
        if (isHelp(arg)) return help();
        if (std.mem.eql(u8, arg, "--fields")) {
            const raw = args.next() orelse return usage();
            var it = std.mem.splitScalar(u8, raw, ',');
            while (it.next()) |f| {
                const trimmed = std.mem.trim(u8, f, " \t");
                if (trimmed.len != 0) try fields.append(gpa, trimmed);
            }
            continue;
        }
        return usage();
    }

    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    const query_text = readStdin(gpa, io) catch {
        std.debug.print("{s}: could not read stdin\n", .{prog});
        return 1;
    };
    defer gpa.free(query_text);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, query_text, .{}) catch {
        std.debug.print("{s}: stdin is not valid JSON\n", .{prog});
        return 1;
    };
    defer parsed.deinit();

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try search(gpa, io, env, vault, parsed.value, fields.items, &out.interface);
    try out.interface.flush();
    return code;
}

pub fn runPatch(gpa: Allocator, io: Io, env: *std.process.Environ.Map, args: *std.process.Args.Iterator, self_path: []const u8) !u8 {
    const path = args.next() orelse return usage();
    if (isHelp(path)) return help();

    var target: ?core.patch.Target = null;
    var op: core.patch.Operation = .replace;
    var create_if_missing = false;
    var owned_segs: ?[]const []const u8 = null;
    defer if (owned_segs) |s| gpa.free(s);

    while (args.next()) |arg| {
        if (isHelp(arg)) return help();
        if (std.mem.eql(u8, arg, "--heading")) {
            if (target != null) return usage();
            const raw = args.next() orelse return usage();
            var segs: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = std.mem.splitSequence(u8, raw, "::");
            while (it.next()) |s| try segs.append(gpa, s);
            owned_segs = try segs.toOwnedSlice(gpa);
            target = .{ .heading = owned_segs.? };
        } else if (std.mem.eql(u8, arg, "--block")) {
            if (target != null) return usage();
            target = .{ .block = args.next() orelse return usage() };
        } else if (std.mem.eql(u8, arg, "--frontmatter")) {
            if (target != null) return usage();
            target = .{ .frontmatter = args.next() orelse return usage() };
        } else if (std.mem.eql(u8, arg, "--append")) {
            op = .append;
        } else if (std.mem.eql(u8, arg, "--prepend")) {
            op = .prepend;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            op = .replace;
        } else if (std.mem.eql(u8, arg, "--create")) {
            create_if_missing = true;
        } else {
            return usage();
        }
    }
    const real_target = target orelse return usage();

    const vault = (try resolveVault(gpa, io, env)) orelse return 1;
    defer gpa.free(vault);

    const content = readStdin(gpa, io) catch {
        std.debug.print("{s}: could not read stdin\n", .{prog});
        return 1;
    };
    defer gpa.free(content);

    var out_buf: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try patch(gpa, io, env, vault, path, real_target, op, create_if_missing, content, self_path, &out.interface);
    try out.interface.flush();
    return code;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const frontmatter_cmd = @import("frontmatter_cmd.zig");

test "read prints a note's full body" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: X\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try read(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("---\ntitle: X\n---\nbody\n", out.written());
}

test "read on a missing note fails clearly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try read(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/nope.md", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "write then read round-trips a note's full body" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var write_out: Io.Writer.Allocating = .init(gpa);
    defer write_out.deinit();
    const wcode = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/new.md", "---\ntitle: New\n---\nbody\n", "", &write_out.writer);
    try testing.expectEqual(@as(u8, 0), wcode);
    try testing.expectEqualStrings("tasks/synapse/new.md\n", write_out.written());

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/new.md")).?;
    defer gpa.free(written);
    try testing.expectEqualStrings("---\ntitle: New\n---\nbody\n", written);
}

test "write against SYNAPSE_VAULT_INTEGRATIONS=git initializes a repo and commits, end to end through the CLI function" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/new.md", "---\ntitle: New\n---\nbody\n", "", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{fx.vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(fx.io(), dot_git, .{});
}

test "list returns every note under the vault, recursively" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("designs/synapse/sb-001.md", "a\n");
    try fx.writeVaultFile("tasks/eon/ecs-001.md", "b\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try list(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "designs/synapse/sb-001.md\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "tasks/eon/ecs-001.md\n") != null);
}

test "searchText finds a note by plain full-text substring, TSV row per hit" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("designs/synapse/sb-001.md", "---\ntitle: X\n---\nsomething about widgets\n");
    try fx.writeVaultFile("designs/synapse/sb-002.md", "---\ntitle: Y\n---\nunrelated\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try searchText(gpa, fx.io(), &fx.env, fx.vault, "widgets", null, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "designs/synapse/sb-001.md\t") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sb-002") == null);
}

test "searchText with a path filter excludes a matching note outside the filtered paths" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("designs/synapse/sb-001.md", "---\ntitle: X\n---\nsomething about widgets\n");
    try fx.writeVaultFile("tasks/synapse/wg-001.md", "---\ntitle: Y\n---\nalso about widgets\n");

    var filter = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"glob": ["designs/*", {"var": "path"}]}
    , .{});
    defer filter.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try searchText(gpa, fx.io(), &fx.env, fx.vault, "widgets", filter.value, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "designs/synapse/sb-001.md\t") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "wg-001") == null);
}

test "docMap reports a note's heading paths, block ids, and frontmatter keys" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile(
        "tasks/synapse/x.md",
        "---\ntitle: X\nstatus: TODO\n---\n\n# X\n\n## Notes\nsee ^ref\n",
    );

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try docMap(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "heading\tX\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "heading\tX::Notes\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "block\tref\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "frontmatter\ttitle\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "frontmatter\tstatus\n") != null);
}

test "docMap on a missing note fails clearly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try docMap(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/nope.md", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "ambiguous reports a wikilink matching two real files, one row per (source, target, candidate)" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    try fx.writeVaultFile("source.md", "[[Duplicate]]\n");
    try fx.writeVaultFile("designs/Duplicate.md", "one\n");
    try fx.writeVaultFile("research/Duplicate.md", "two\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try ambiguous(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "source.md\tDuplicate\tdesigns/Duplicate.md\t1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "source.md\tDuplicate\tresearch/Duplicate.md\t1\n") != null);
}

test "ambiguous is empty when every wikilink resolves cleanly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    try fx.writeVaultFile("source.md", "[[Target]]\n");
    try fx.writeVaultFile("Target.md", "body\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try ambiguous(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("", out.written());
}

test "rename moves a note and rewrites its referrers" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    try fx.writeVaultFile("Old.md", "body\n");
    try fx.writeVaultFile("A.md", "see [[Old]]\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try rename(gpa, fx.io(), &fx.env, fx.vault, "Old.md", "New.md", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("New.md\n", out.written());

    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "Old.md"));
    const new_body = (try fx.readVaultFile(gpa, "New.md")).?;
    defer gpa.free(new_body);
    try testing.expectEqualStrings("body\n", new_body);
    const a = (try fx.readVaultFile(gpa, "A.md")).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("see [[New]]\n", a);
}

test "rename on a missing note fails clearly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try rename(gpa, fx.io(), &fx.env, fx.vault, "Nope.md", "New.md", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "search filters and projects requested fields as TSV" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/a.md", "---\nstatus: TODO\n---\nbody a\n");
    try fx.writeVaultFile("tasks/synapse/b.md", "---\nstatus: DONE\n---\nbody b\n");

    var q = try std.json.parseFromSlice(std.json.Value, gpa, "{\"==\": [{\"var\": \"frontmatter.status\"}, \"TODO\"]}", .{});
    defer q.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try search(gpa, fx.io(), &fx.env, fx.vault, q.value, &.{"frontmatter.status"}, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("tasks/synapse/a.md\tTODO\n", out.written());
}

test "search with no --fields prints just the matching path" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/a.md", "body\n");

    var q = try std.json.parseFromSlice(std.json.Value, gpa, "true", .{});
    defer q.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try search(gpa, fx.io(), &fx.env, fx.vault, q.value, &.{}, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("tasks/synapse/a.md\n", out.written());
}

const test_check_schema =
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
    "    count: 1\n" ++
    "checks: []\n";

fn writeCheckSchema(fx: *fixture.Fixture) !void {
    try fx.tmp.dir.createDirPath(testing.io, "schema/t");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "schema/t/v1.yaml", .data = test_check_schema });
    try fx.env.put("SYNAPSE_CONTENT_ROOT", fx.root);
}

const test_check_schema_with_lint =
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
    "    count: 1\n" ++
    "checks: []\n" ++
    "lints:\n" ++
    "  - no_hard_wrap: body.prose\n" ++
    "    severity: warn\n";

fn writeCheckSchemaWithLint(fx: *fixture.Fixture) !void {
    try fx.tmp.dir.createDirPath(testing.io, "schema/t");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "schema/t/v1.yaml", .data = test_check_schema_with_lint });
    try fx.env.put("SYNAPSE_CONTENT_ROOT", fx.root);
}

test "check reports a conformant schema note clean and counts legacy notes" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    _ = fx.env.swapRemove("SYNAPSE_CONTENT_ROOT");
    try writeCheckSchema(&fx);
    try fx.writeVaultFile("research/Good.md", "---\nschema: t/v1\ntitle: Good\n---\n# Good\n\nbody\n");
    try fx.writeVaultFile("research/Legacy.md", "---\ntitle: Legacy\n---\n# Legacy\n\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try check(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("2 notes: 1 schema-declaring (1 conformant, 0 violations), 1 legacy\n", out.written());
}

test "check reports a violating schema note and exits 1" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    _ = fx.env.swapRemove("SYNAPSE_CONTENT_ROOT");
    try writeCheckSchema(&fx);
    try fx.writeVaultFile("research/Bad.md", "---\nschema: t/v1\n---\n# Bad\n\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try check(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research/Bad.md\tfrontmatter.title: required field is missing\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "1 schema-declaring (0 conformant, 1 violations)") != null);
}

test "check reports lint findings as a distinct advisory section, not counted as a violation" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS");
    _ = fx.env.swapRemove("SYNAPSE_CONTENT_ROOT");
    try writeCheckSchemaWithLint(&fx);
    try fx.writeVaultFile("research/Wrapped.md",
        "---\nschema: t/v1\ntitle: Wrapped\n---\n# Wrapped\n\nThis sentence got\nhard-wrapped across two lines.\n");
    try fx.writeVaultFile("research/Clean.md", "---\nschema: t/v1\ntitle: Clean\n---\n# Clean\n\nOne line, as it should be.\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try check(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "2 schema-declaring (2 conformant, 0 violations)") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Lint (advisory, 1 finding(s) across 1 note(s)):\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research/Wrapped.md\tno_hard_wrap:") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Clean.md\tno_hard_wrap") == null);
}

test "check reports an unresolvable schema id per note" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    _ = fx.env.swapRemove("SYNAPSE_CONTENT_ROOT");
    try writeCheckSchema(&fx);
    try fx.writeVaultFile("research/Unknown.md", "---\nschema: missing/v1\n---\n# Unknown\n\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try check(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research/Unknown.md\t") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "1 legacy") == null);
}

const test_check_schema_stem_equals_title =
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
    "    count: 1\n" ++
    "checks:\n" ++
    "  - equals: [filename.stem, frontmatter.title]\n";

fn writeCheckSchemaStemEqualsTitle(fx: *fixture.Fixture) !void {
    try fx.tmp.dir.createDirPath(testing.io, "schema/t");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "schema/t/v1.yaml", .data = test_check_schema_stem_equals_title });
    try fx.env.put("SYNAPSE_CONTENT_ROOT", fx.root);
}

test "rename keeps a schema-declaring note's stem==title check conformant" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS"); // disk is implicit, never named
    _ = fx.env.swapRemove("SYNAPSE_CONTENT_ROOT");
    try writeCheckSchemaStemEqualsTitle(&fx);
    try fx.writeVaultFile("research/Old.md", "---\nschema: t/v1\ntitle: Old\n---\n# Old\n\nbody\n");

    var rename_out: Io.Writer.Allocating = .init(gpa);
    defer rename_out.deinit();
    const rename_code = try rename(gpa, fx.io(), &fx.env, fx.vault, "research/Old.md", "research/New.md", &rename_out.writer);
    try testing.expectEqual(@as(u8, 0), rename_code);

    var check_out: Io.Writer.Allocating = .init(gpa);
    defer check_out.deinit();
    const check_code = try check(gpa, fx.io(), &fx.env, fx.vault, &check_out.writer);
    try testing.expectEqual(@as(u8, 0), check_code);
    try testing.expectEqualStrings("1 notes: 1 schema-declaring (1 conformant, 0 violations), 0 legacy\n", check_out.written());
}

test "patch replaces a heading's content" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("designs/synapse/x.md", "# Title\n\n## Status\nDiscussing\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try patch(gpa, fx.io(), &fx.env, fx.vault, "designs/synapse/x.md", .{ .heading = &.{"Status"} }, .replace, false, "Ready\n", "", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "designs/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expectEqualStrings("# Title\n\n## Status\nReady\n", written);
}

test "patch on a frontmatter target delegates to the byte-preserving path" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("tasks/synapse/x.md", "---\ntitle: \"X\"\nstatus: TODO\n---\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try patch(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/x.md", .{ .frontmatter = "status" }, .replace, false, "DONE", "", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/x.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "status: DONE\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "title: \"X\"\n") != null);
}

test "patch on a missing target fails clearly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeVaultFile("designs/synapse/x.md", "# Title\n\nbody\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try patch(gpa, fx.io(), &fx.env, fx.vault, "designs/synapse/x.md", .{ .heading = &.{"Nope"} }, .replace, false, "x", "", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

// --- Real shipped v1 schema coverage -----------------------------------
//
// Migrated from tests/synapse-schema-validation.bats (kept only "the npm
// package includes all shipped schema documents" there, since that one has
// no Zig code behind it at all). Points SYNAPSE_CONTENT_ROOT at the real
// packages/synapse/schema/ directory rather than a synthetic one, the same
// way the bats suite pointed SYNAPSE_CONTENT_ROOT at $REPO_ROOT/packages/
// synapse -- these tests are about the real shipped schema documents
// actually validating through this CLI door, not about the DSL engine
// (already covered with synthetic schemas by note_schema.zig's own tests
// and this file's writeCheckSchema()-based ones above).

fn withRealSchemas(fx: *fixture.Fixture) !void {
    try fx.env.put("SYNAPSE_CONTENT_ROOT", "packages/synapse");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/synapse-projects.conf", .data = "synapse=sb\n" });
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/synapse-tag-vocabulary.conf",
        .data = "synapse\narchitecture\nvault-infra\n",
    });
}

const schema_fixed_timestamp = "2026-08-30 01:00:00 CEST";

fn bareNoteBody(gpa: Allocator, title: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "---\n" ++
        "schema: vault-note/v1\n" ++
        "title: \"{s}\"\n" ++
        "note_id: {s}\n" ++
        "created: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "updated: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "tags: [synapse, architecture]\n" ++
        "---\n\n" ++
        "# {s}\n\n" ++
        "## Summary\n\n" ++
        "A useful summary.\n", .{ title, id, title });
}

fn taskNoteBody(gpa: Allocator, title: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "---\n" ++
        "schema: vault-task-note/v1\n" ++
        "title: \"{s}\"\n" ++
        "project: sb\n" ++
        "task_id: {s}\n" ++
        "created: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "updated: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "tags:\n  - synapse\n  - architecture\n" ++
        "status: TODO\n" ++
        "---\n\n" ++
        "# {s}\n\n" ++
        "Implement the requested change.\n\n" ++
        "## Checklist\n\n" ++
        "- [ ] First implementation step\n\n" ++
        "## Notes\n\n" ++
        "Design context.\n", .{ title, id, title });
}

test "no_hard_wrap fires against the real shipped vault-note/v1 schema, on a hard-wrapped Summary" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const note = try std.fmt.allocPrint(gpa, "---\n" ++
        "schema: vault-note/v1\n" ++
        "title: \"Wrapped example\"\n" ++
        "note_id: sb-907\n" ++
        "created: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "updated: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "tags: [synapse]\n" ++
        "---\n\n" ++
        "# Wrapped example\n\n" ++
        "## Summary\n" ++
        "This sentence got manually\n" ++
        "wrapped at roughly seventy columns.\n", .{});
    defer gpa.free(note);

    const vars = adapters.env.vars(&fx.env);
    var doc = try adapters.schema_validation_store.loadSchemaDocument(gpa, fx.io(), vars, "vault-note/v1");
    defer doc.deinit();
    const findings = try core.note_schema.lintNote(gpa, doc.root, note, "research/Wrapped example.md");
    defer {
        for (findings) |f| gpa.free(f);
        gpa.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "no_hard_wrap") != null);
}

test "no_id_prefix_in_title fires against the real shipped vault-task-note/v1 schema, on the exact motivating shape" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    // The real originating incident: a title carrying its own task_id
    // prefix, the form every actual task note omits.
    const note = try taskNoteBody(gpa, "sb-908 — Prefixed example", "sb-908");
    defer gpa.free(note);

    const vars = adapters.env.vars(&fx.env);
    var doc = try adapters.schema_validation_store.loadSchemaDocument(gpa, fx.io(), vars, "vault-task-note/v1");
    defer doc.deinit();
    const findings = try core.note_schema.lintNote(gpa, doc.root, note, "tasks/synapse/sb-908 — Prefixed example.md");
    defer {
        for (findings) |f| gpa.free(f);
        gpa.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "sb-908") != null);
}

test "no_hard_wrap fires against the real shipped vault-task-note/v1 schema, on the exact motivating shape" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    // The other half of the real originating incident: a task note's own
    // lead description, hard-wrapped at roughly seventy columns.
    const note = try std.fmt.allocPrint(gpa, "---\n" ++
        "schema: vault-task-note/v1\n" ++
        "title: \"Wrapped task example\"\n" ++
        "project: sb\n" ++
        "task_id: sb-909\n" ++
        "created: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "updated: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "tags: [synapse]\n" ++
        "status: TODO\n" ++
        "---\n\n" ++
        "# Wrapped task example\n\n" ++
        "This description got manually\n" ++
        "wrapped across two lines.\n\n" ++
        "## Checklist\n\n" ++
        "- [ ] First implementation step\n", .{});
    defer gpa.free(note);

    const vars = adapters.env.vars(&fx.env);
    var doc = try adapters.schema_validation_store.loadSchemaDocument(gpa, fx.io(), vars, "vault-task-note/v1");
    defer doc.deinit();
    const findings = try core.note_schema.lintNote(gpa, doc.root, note, "tasks/synapse/Wrapped task example.md");
    defer {
        for (findings) |f| gpa.free(f);
        gpa.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expect(std.mem.indexOf(u8, findings[0], "no_hard_wrap") != null);
}

test "all three shipped v1 note schemas validate through vault-write" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const bare = try bareNoteBody(gpa, "Bare example", "sb-901");
    defer gpa.free(bare);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Bare example.md", bare, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    const task = try taskNoteBody(gpa, "Task example", "sb-902");
    defer gpa.free(task);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/Task example.md", task, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    const design = try std.fmt.allocPrint(gpa, "---\n" ++
        "schema: vault-design-note/v1\n" ++
        "title: \"sb — Design example\"\n" ++
        "project: sb\n" ++
        "note_id: sb-903\n" ++
        "created: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "updated: \"" ++ schema_fixed_timestamp ++ "\"\n" ++
        "tags: [synapse, architecture]\n" ++
        "---\n\n" ++
        "# sb — Design example\n\n" ++
        "## Status\nDiscussing\n\n" ++
        "## Problem\nA concrete problem.\n\n" ++
        "## Approach\nA concrete approach.\n\n" ++
        "## Constraints\nA concrete constraint.\n", .{});
    defer gpa.free(design);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "designs/synapse/sb — Design example.md", design, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }
}

fn graphNodeBody(gpa: Allocator, title: []const u8, sources_tail: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "---\n" ++
        "schema: graph-node/v1\n" ++
        "title: \"{s}\"\n" ++
        "summary: \"One line differentiating this node from its siblings.\"\n" ++
        "node_type: synapse-node\n" ++
        "project: acme\n" ++
        "branch: main\n" ++
        "sources_digest: " ++ ("df91a067" ** 8) ++ "\n" ++
        "stale: false\n" ++
        "built_at: \"" ++ schema_fixed_timestamp[0..16] ++ "\"\n" ++
        "{s}" ++
        "---\n\n" ++
        "# {s}\n\n" ++
        "## Summary\n\nPlain-English explanation.\n\n" ++
        "## Crux\n<!-- crux: none -->\n\n" ++
        "## Links\n\n" ++
        "## Sources\n- `acme_ecs` (1)\n\n" ++
        "## Notes\n", .{ title, sources_tail, title });
}

test "the shipped graph-node/v1 schema validates a realistic node through vault-write" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const node = try graphNodeBody(gpa, "Widget core",
        "sources:\n  - path: acme_ecs/world.ml\n    hash: aa\n");
    defer gpa.free(node);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, fx.vault, "synapse/acme@main/Widget core.md", node, "", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
}

test "the shipped graph-node/v1 schema refuses sources ahead of another declared field" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    // `sources:` moved ahead of `built_at:` -- the whole point of `field_order: relative`.
    const node = try std.fmt.allocPrint(gpa, "---\n" ++
        "schema: graph-node/v1\n" ++
        "title: \"Widget core\"\n" ++
        "summary: \"One line differentiating this node from its siblings.\"\n" ++
        "node_type: synapse-node\n" ++
        "project: acme\n" ++
        "branch: main\n" ++
        "sources:\n  - path: acme_ecs/world.ml\n    hash: aa\n" ++
        "sources_digest: " ++ ("df91a067" ** 8) ++ "\n" ++
        "stale: false\n" ++
        "built_at: \"" ++ schema_fixed_timestamp[0..16] ++ "\"\n" ++
        "---\n\n" ++
        "# Widget core\n\n" ++
        "## Summary\n\nPlain-English explanation.\n\n" ++
        "## Crux\n<!-- crux: none -->\n\n" ++
        "## Links\n\n" ++
        "## Sources\n- `acme_ecs` (1)\n\n" ++
        "## Notes\n", .{});
    defer gpa.free(node);

    var resolved = (try openWholeVaultStore(gpa, fx.io(), &fx.env, fx.vault, "")).?;
    defer resolved.deinit();
    var store = resolved.store();
    const wr = try store.write(fx.io(), "synapse/acme@main/Widget core.md", node);
    defer gpa.free(wr.body);
    try testing.expect(!wr.accepted);
    try testing.expect(std.mem.indexOf(u8, wr.body, "out of relative order") != null);
    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "synapse/acme@main/Widget core.md"));
}

test "invalid schema-declaring notes fail with a field diagnostic and no partial file" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const body = try bareNoteBody(gpa, "Wrong title", "sb-904");
    defer gpa.free(body);

    var resolved = (try openWholeVaultStore(gpa, fx.io(), &fx.env, fx.vault, "")).?;
    defer resolved.deinit();
    var store = resolved.store();
    const wr = try store.write(fx.io(), "research/Right title.md", body);
    defer gpa.free(wr.body);
    try testing.expect(!wr.accepted);
    try testing.expect(std.mem.indexOf(u8, wr.body, "filename.stem") != null);
    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "research/Right title.md"));
}

test "unknown and unsafe schema identifiers fail closed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    var resolved = (try openWholeVaultStore(gpa, fx.io(), &fx.env, fx.vault, "")).?;
    defer resolved.deinit();
    var store = resolved.store();

    {
        const wr = try store.write(fx.io(), "missing.md", "---\nschema: vault-missing/v1\n---\n");
        defer gpa.free(wr.body);
        try testing.expect(!wr.accepted);
        try testing.expect(std.mem.indexOf(u8, wr.body, "schema:") != null);
        try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "missing.md"));
    }
    {
        const wr = try store.write(fx.io(), "unsafe.md", "---\nschema: ../secret\n---\n");
        defer gpa.free(wr.body);
        try testing.expect(!wr.accepted);
        try testing.expect(std.mem.indexOf(u8, wr.body, "unsafe identifier") != null);
        try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "unsafe.md"));
    }
}

test "note_id and task_id share one creation-time uniqueness namespace" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const owner = try taskNoteBody(gpa, "Identity owner", "sb-905");
    defer gpa.free(owner);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/Identity owner.md", owner, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    const dup = try bareNoteBody(gpa, "Duplicate identity", "sb-905");
    defer gpa.free(dup);

    var resolved = (try openWholeVaultStore(gpa, fx.io(), &fx.env, fx.vault, "")).?;
    defer resolved.deinit();
    var store = resolved.store();
    const wr = try store.write(fx.io(), "research/Duplicate identity.md", dup);
    defer gpa.free(wr.body);
    try testing.expect(!wr.accepted);
    try testing.expect(std.mem.indexOf(u8, wr.body, "already exists") != null);
    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "research/Duplicate identity.md"));
}

test "vault-patch refreshes updated before validation and preserves all other frontmatter" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const body = try bareNoteBody(gpa, "Timestamp example", "sb-906");
    defer gpa.free(body);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Timestamp example.md", body, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try patch(
            gpa,
            fx.io(),
            &fx.env,
            fx.vault,
            "research/Timestamp example.md",
            .{ .heading = &.{ "Timestamp example", "Summary" } },
            .append,
            false,
            "More detail.\n",
            "",
            &out.writer,
        );
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try frontmatter_cmd.get(gpa, fx.io(), &fx.env, fx.vault, "research/Timestamp example.md", "updated", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
        const updated = std.mem.trim(u8, out.written(), "\n");
        try testing.expect(!std.mem.eql(u8, updated, schema_fixed_timestamp));
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try frontmatter_cmd.get(gpa, fx.io(), &fx.env, fx.vault, "research/Timestamp example.md", "note_id", &out.writer);
        try testing.expectEqualStrings("sb-906\n", out.written());
    }
}

test "vault-write refreshes updated on an existing schema note" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const body = try bareNoteBody(gpa, "Write timestamp", "sb-908");
    defer gpa.free(body);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Write timestamp.md", body, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    const replaced = try std.mem.replaceOwned(u8, gpa, body, "A useful summary.", "A replacement summary.");
    defer gpa.free(replaced);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Write timestamp.md", replaced, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try frontmatter_cmd.get(gpa, fx.io(), &fx.env, fx.vault, "research/Write timestamp.md", "updated", &out.writer);
        try testing.expect(!std.mem.eql(u8, std.mem.trim(u8, out.written(), "\n"), schema_fixed_timestamp));
    }

    const written = (try fx.readVaultFile(gpa, "research/Write timestamp.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "A replacement summary.") != null);
}

test "a rejected write under SYNAPSE_VAULT_INTEGRATIONS=git has no Git integration side effect" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);
    try fx.env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    const body = try bareNoteBody(gpa, "Wrong title", "sb-907");
    defer gpa.free(body);

    var resolved = (try openWholeVaultStore(gpa, fx.io(), &fx.env, fx.vault, "")).?;
    defer resolved.deinit();
    var store = resolved.store();
    const wr = try store.write(fx.io(), "research/Right title.md", body);
    defer gpa.free(wr.body);
    try testing.expect(!wr.accepted);

    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{fx.vault});
    defer gpa.free(dot_git);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(fx.io(), dot_git, .{}));
}

test "vault-patch on H1::Checklist replaces the checklist without touching Notes" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const body = try taskNoteBody(gpa, "Checklist scoping", "sb-910");
    defer gpa.free(body);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "tasks/synapse/Checklist scoping.md", body, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try patch(
            gpa,
            fx.io(),
            &fx.env,
            fx.vault,
            "tasks/synapse/Checklist scoping.md",
            .{ .heading = &.{ "Checklist scoping", "Checklist" } },
            .replace,
            false,
            "- [x] Done first\n- [ ] Next step\n",
            "",
            &out.writer,
        );
        try testing.expectEqual(@as(u8, 0), code);
    }

    const written = (try fx.readVaultFile(gpa, "tasks/synapse/Checklist scoping.md")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "## Checklist") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- [x] Done first") != null);
    try testing.expect(std.mem.indexOf(u8, written, "## Notes") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Design context.") != null);
}

test "vault-rename syncs title/H1 to the new filename, rewrites referrers, and stays vault-check clean" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try withRealSchemas(&fx);

    const old = try bareNoteBody(gpa, "Old title", "sb-909");
    defer gpa.free(old);
    const referrer = try bareNoteBody(gpa, "Referrer", "sb-911");
    defer gpa.free(referrer);
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Old title.md", old, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try write(gpa, fx.io(), &fx.env, fx.vault, "research/Referrer.md", referrer, "", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try patch(
            gpa,
            fx.io(),
            &fx.env,
            fx.vault,
            "research/Referrer.md",
            .{ .heading = &.{ "Referrer", "Summary" } },
            .append,
            false,
            "See [[Old title]] for background.\n",
            "",
            &out.writer,
        );
        try testing.expectEqual(@as(u8, 0), code);
    }

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try rename(gpa, fx.io(), &fx.env, fx.vault, "research/Old title.md", "research/New title.md", &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }
    try testing.expectEqual(@as(?[]u8, null), try fx.readVaultFile(gpa, "research/Old title.md"));

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try frontmatter_cmd.get(gpa, fx.io(), &fx.env, fx.vault, "research/New title.md", "title", &out.writer);
        try testing.expectEqualStrings("New title\n", out.written());
    }

    const new_body = (try fx.readVaultFile(gpa, "research/New title.md")).?;
    defer gpa.free(new_body);
    try testing.expect(std.mem.indexOf(u8, new_body, "# New title") != null);

    const referrer_body = (try fx.readVaultFile(gpa, "research/Referrer.md")).?;
    defer gpa.free(referrer_body);
    try testing.expect(std.mem.indexOf(u8, referrer_body, "[[New title]]") != null);

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try check(gpa, fx.io(), &fx.env, fx.vault, &out.writer);
        try testing.expectEqual(@as(u8, 0), code);
    }
}
