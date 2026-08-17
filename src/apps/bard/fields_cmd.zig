//! `synapse-bard fields <node>` / `synapse-bard fields --template <name>` --
//! every root-level frontmatter field name a template defines, so an agent
//! knows which `field <node> <key>` calls are worth making instead of
//! guessing one at a time.
//!
//! `synapse-bard-006`, surfaced live during a real writing-assistant
//! simulation: `query`'s own output already names an entity's template
//! (`Gael Varis (character_pov)`), but nothing said what fields that
//! template actually has -- probing `goals`/`arc`/`secrets`/`internal_
//! conflict` cost four clean misses before `personality` hit. The missing
//! step was reading the template file's own field list, the same way a
//! human familiar with the schema already would.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard fields <node>
    \\       synapse-bard fields --template <name>
    \\
    \\  <node>              the wikilink slug -- resolved the same way query/
    \\                      field do, then its own template is looked up
    \\  --template <name>   a template name directly (e.g. character_pov),
    \\                      matching a root-level template: value verbatim --
    \\                      for exploring a schema with no example entity
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    const first = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Help must not need an environment -- checked before Roots.resolve
    // below, which requires being inside a git repo.
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var template_name: []const u8 = undefined;
    var owned: ?[]u8 = null;
    defer if (owned) |t| gpa.free(t);

    if (std.mem.eql(u8, first, "--template")) {
        const name = args.next() orelse {
            std.debug.print("synapse-bard fields: --template needs a name\n{s}", .{usage});
            return 2;
        };
        if (args.next()) |extra| {
            std.debug.print("synapse-bard fields: unexpected argument '{s}'\n{s}", .{ extra, usage });
            return 2;
        }
        template_name = name;
    } else {
        if (args.next()) |extra| {
            std.debug.print("synapse-bard fields: unexpected argument '{s}'\n{s}", .{ extra, usage });
            return 2;
        }

        var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
        defer store.deinit();

        const resolved = (try adapters.bard_cluster.resolveSlug(gpa, io, &store, first)) orelse {
            std.debug.print("{s}: not found\n", .{first});
            return 1;
        };
        defer {
            gpa.free(resolved.slug);
            gpa.free(resolved.path);
        }

        // Same extraction call `query` already makes -- reuses its already-
        // correct kind/unquoting logic rather than re-deriving a second way
        // to read `template:` out of raw YAML.
        var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
        defer ex.deinit(gpa);
        const out = try ex.port().extract(gpa, io, roots.repo_root, &.{resolved.path});
        defer common.freeOutcomes(gpa, out);

        const tags = switch (out[0]) {
            .unsupported => {
                std.debug.print("{s}: unsupported ({t})\n", .{ first, ex.last_refusals[0] orelse .not_a_note });
                return 1;
            },
            .tags => |t| t,
        };
        var kind: ?[]const u8 = null;
        for (tags) |t| if (t.role == .def) {
            kind = t.kind;
            break;
        };
        owned = try gpa.dupe(u8, kind orelse "entity");
        template_name = owned.?;
    }

    const template_path = try std.fmt.allocPrint(gpa, "{s}/_templates/{s}_template.md", .{ roots.repo_root, template_name });
    defer gpa.free(template_path);

    const template_src = Io.Dir.cwd().readFileAlloc(io, template_path, gpa, .limited(1 << 20)) catch {
        std.debug.print("synapse-bard fields: no template file for '{s}' ({s})\n", .{ template_name, template_path });
        return 1;
    };
    defer gpa.free(template_src);

    const keys = (try adapters.bard_frontmatter.rootKeys(gpa, template_src)) orelse {
        std.debug.print("synapse-bard fields: '{s}_template.md' has no frontmatter\n", .{template_name});
        return 1;
    };
    defer {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    for (keys) |k| try w.interface.print("{s}\n", .{k});
    try w.interface.flush();
    return 0;
}
