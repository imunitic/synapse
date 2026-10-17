with Synapse.Hooks.Common;

--  `staleness`: PostToolUse on a write or an edit. Three jobs per edit: flag
--  every node that covers the file, report cited evidence that stopped
--  matching, and once per session per file name the nodes that depend on the
--  owners of the file.
--
--  The hook knows for certain which file changed, so flagging is bookkeeping
--  and no hash is verified here; `query stale` does that at read time. The
--  correction it asks for is narrow on purpose: only when the edit landed on
--  evidence a node cites (its crux source or a grounded range), because a
--  nudge on any edit to any of a node's files would fire constantly and be
--  tuned out. The blast radius, the inbound relations to the owning nodes, is
--  said once per session per file, since editing one file again and again
--  would repeat it every time.
--
--  Docstring staleness has its own tier here: the stored line range of each
--  tracked declaration is hashed again, never a fresh parse, since this program
--  links no parser.
--
--  Each owning node gets one `stale: true` line, by read and rewrite, never by
--  a frontmatter patch: that leaves a false positive no rebuild clears.
package Synapse.Hooks.Staleness is

   procedure Run (Env : Environment);

   --  The context for an edit of Raw_File in the session Sid, or none when
   --  nothing should be said, with the vault already found.
   function Build
     (Env : Environment; Vault, Raw_File, Sid : String)
      return Common.Maybe_Text;

end Synapse.Hooks.Staleness;
