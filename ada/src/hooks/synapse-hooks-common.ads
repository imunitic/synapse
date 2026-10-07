with Ada.Strings.Unbounded;

with Synapse.Core.Identity;
with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;

--  What the hooks share: the payload on standard input, the vault, the
--  namespace and the one output shape Claude Code reads.
package Synapse.Hooks.Common is

   use Ada.Strings.Unbounded;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  The hook payload, as much of it as any hook reads. A payload that
   --  changes shape degrades to the hook doing nothing: every field is
   --  optional and every absent one is an early exit.
   type Payload is private;

   --  Reads and parses standard input; an empty or malformed one is a
   --  payload with no fields.
   function Read (Env : Environment) return Payload;

   --  A top-level string field; none when absent, not a string or empty.
   function Str (P : Payload; Key : String) return Maybe_Text;

   --  A string field of an object field, `Outer.Inner`.
   function Nested (P : Payload; Outer, Inner : String) return Maybe_Text;

   --  The file a mutating tool touched, over every payload shape: Claude
   --  Code's `tool_input.file_path` or `tool_response.filePath`, both
   --  absolute, and the first `*** Update File:` or `*** Add File:` line of
   --  an `apply_patch`, which is relative to the payload's own `cwd`.
   function Tool_File (P : Payload) return Maybe_Text;

   --  The vault directory when it is configured and is a directory.
   function Vault (Env : Environment) return Maybe_Text;

   --  A checkout's namespace: `{repo}@{branch}`, its root, branch and
   --  remote.
   type Namespace is record
      Key       : Unbounded_String;
      Repo_Root : Unbounded_String;
      Branch    : Unbounded_String;
      Remote    : Unbounded_String;
   end record;

   type Maybe_Namespace (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Namespace;

         when False =>
            null;
      end case;
   end record;

   --  From the environment when all of `SYNAPSE_NAMESPACE`,
   --  `SYNAPSE_REPO_ROOT` and `SYNAPSE_BRANCH` are set, so a second
   --  resolution cannot disagree with the first; otherwise asked of git for
   --  the repository containing Cwd. A detached head or no repository is an
   --  ordinary state and none.
   function Resolve_Namespace
     (Env : Environment; Cwd : String) return Maybe_Namespace;

   --  `$SYNAPSE_WORK_DIR`, else the cache directory named for the key under
   --  the home; none without one.
   function Work_Dir (Env : Environment; Key : String) return Maybe_Text;

   --  Whether the namespace's index names this repository and this branch.
   --  A field that is absent is a mismatch and not a match of empty against
   --  empty: absent provenance is not permission to write.
   function Index_Agrees (Index_Text : String; Ns : Namespace) return Boolean;

   function Namespace_Matches (Vault : String; Ns : Namespace) return Boolean;

   --  `{"hookSpecificOutput":{"hookEventName":Event,"additionalContext":
   --  Text}}` on standard output. Context and not a block: it is for the next
   --  turn and no reason to stop. Nothing for an empty text.
   procedure Emit_Context (Env : Environment; Event, Text : String);

   --  A JSON string literal, written here and not by a serializer: the
   --  escaping is what has to be right.
   function Json_String (Text : String) return String;

private

   type Payload is record
      Present : Boolean := False;
      Root    : Synapse.Core.JSON.Value;
   end record;

end Synapse.Hooks.Common;
