//! The graph itself: def/ref model, source-path index and reverse, tokenizer,
//! vocabulary, ranking, query/traversal, staleness bookkeeping, tags cache.
//! Operates only on defs and refs, never on extraction or storage.
//!
//! Purity: reaches the system only through an injected `std.Io` and the
//! ports, never naming `std.fs`/`std.process`/`std.time`/`std.http` directly
//! -- enforced by `just check`'s purity gate, which the build graph can't.

const std = @import("std");

pub const ports = @import("ports");
pub const model = @import("model");
pub const tag_line = @import("tag_line.zig");

pub const tags_cache = @import("tags_cache.zig");
pub const index_map = @import("index_map.zig");
pub const enumerate = @import("enumerate.zig");
pub const vocab = @import("vocab.zig");
pub const namespace = @import("namespace.zig");
pub const deps = @import("deps.zig");
pub const kind_synonyms = @import("kind_synonyms.zig");
pub const links = @import("links.zig");
pub const rarity = @import("rarity.zig");
pub const rank = @import("rank.zig");
pub const node = @import("node.zig");
pub const query = @import("query.zig");
pub const verify = @import("verify.zig");
pub const drift = @import("drift.zig");
pub const symbol = @import("symbol.zig");
pub const emit = @import("emit.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const patch = @import("patch.zig");
pub const regex_lite = @import("regex_lite.zig");
pub const schema_pattern = @import("schema_pattern.zig");
pub const schema_yaml = @import("schema_yaml.zig");
pub const note_schema = @import("note_schema.zig");
pub const jsonlogic = @import("jsonlogic.zig");
pub const vault_query = @import("vault_query.zig");
pub const text_search = @import("text_search.zig");
pub const node_path = @import("node_path.zig");
pub const fence_languages = @import("fence_languages.zig");
pub const refs = @import("refs.zig");
pub const gate = @import("gate.zig");
pub const project_index = @import("project_index.zig");
pub const graph_clean = @import("graph_clean.zig");
pub const identity = @import("identity.zig");
pub const conf = @import("conf.zig");
pub const doctor = @import("doctor.zig");
pub const task_status = @import("task_status.zig");
pub const wikilinks = @import("wikilinks.zig");

test {
    std.testing.refAllDecls(@This());
    _ = model;
    _ = tag_line;
    _ = tags_cache;
    _ = index_map;
    _ = enumerate;
    _ = vocab;
    _ = namespace;
    _ = deps;
    _ = links;
    _ = rank;
    _ = node;
    _ = query;
    _ = verify;
    _ = drift;
    _ = symbol;
    _ = emit;
    _ = frontmatter;
    _ = patch;
    _ = regex_lite;
    _ = schema_pattern;
    _ = schema_yaml;
    _ = note_schema;
    _ = jsonlogic;
    _ = vault_query;
    _ = text_search;
    _ = node_path;
    _ = fence_languages;
    _ = refs;
    _ = gate;
    _ = project_index;
    _ = graph_clean;
    _ = identity;
    _ = conf;
    _ = doctor;
    _ = task_status;
    _ = wikilinks;
    _ = @import("tags_cache/format.zig");
    _ = @import("tags_cache/payload.zig");
    _ = @import("index_map/format.zig");
}
