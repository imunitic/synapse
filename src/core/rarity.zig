//! The one shared number behind two independent rarity floors --
//! `gate.zig`'s vocabulary-distinctiveness judgement and `links.zig`'s
//! reference-weighting filter both compute `max(2, N/20)`, over different
//! entities (words-per-cluster vs. symbols-per-node) and with no other
//! dependency between the two modules. Centralizing the *function* wasn't
//! worth a cross-module dependency to save one line of arithmetic -- but the
//! `20` itself recalibrating in one site and not the other, silently, is a
//! real risk `gate.zig`'s own calibration story makes plausible, so it gets
//! one shared name instead of two independent magic numbers that happen to
//! agree today.

/// Below this many clusters/nodes sharing a word/symbol, it counts as rare.
/// A floor of 2 applies regardless of `N` -- see each call site for what
/// "sharing" means in its own context.
pub const divisor: usize = 20;
