with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.Options;

--  Where a command is: the vault, the namespace of the checkout, its work
--  directory and the module boilerplate, found once. The shared preamble of
--  the commands that read or write a graph: find the vault, name the
--  namespace, load the boilerplate, refuse if the namespace's index names a
--  different repository or branch. One chain and not several that could
--  disagree.
--
--  Identity comes from `.git`, `HEAD` and `config`, with no process started.
--  The environment still wins when it is set, which is how a test pins a
--  namespace without a real remote. Reads of a known path go straight to disk,
--  where a search round trip would buy nothing.

package Synapse.Commands.Context is

   use Ada.Strings.Unbounded;

   type Context is record
      --  The vault root, from `SYNAPSE_VAULT_DIR`, as a variable or a
      --  `synapse.conf` setting.
      Vault              : Unbounded_String;
      --  `{repo}@{branch}`: the namespace's directory name, never a bare
      --  repository name.
      Namespace          : Unbounded_String;
      Repo_Root          : Unbounded_String;
      --  Where `_index.bin` and `_tags_cache.bin` live: disposable, and
      --  outside the vault.
      Work_Dir           : Unbounded_String;
      Branch             : Unbounded_String;
      Remote             : Unbounded_String;
      --  Set when the namespace was named directly (`--namespace`) and not
      --  derived from the checkout, so there is no remote of the current
      --  directory to compare it with.
      Namespace_Explicit : Boolean := False;
      --  Path segments chains that module grouping collapses. None only
      --  stops the grouping from collapsing scaffolding; it is not a failure.
      Chains             : Lists.Vector;
      --  `synapse/{namespace}`, relative to the vault.
      Dir                : Unbounded_String;
      --  The same directory as an absolute path.
      Abs_Dir            : Unbounded_String;
   end record;

   package Maybe_Context_Options is new Synapse.Core.Options (Context);

   subtype Maybe_Context is Maybe_Context_Options.Option;

   --  The context of the checkout containing the current directory, or what
   --  is missing explained on standard error, prefixed with Prog, and none.
   --  The namespace, repository root and branch come from the environment
   --  only when all three are set, and from the checkout otherwise: a mixture
   --  of the two would be the very disagreement this exists to prevent.
   function Resolve (Env : Environment; Prog : String) return Maybe_Context;

   --  The context of a namespace named directly as `{repo}@{branch}`, with no
   --  look at git: how a query addresses another checkout's graph. The
   --  repository root stays empty unless `SYNAPSE_REPO_ROOT` gives one.
   function Resolve_Explicit
     (Env : Environment; Prog : String; Namespace : String)
      return Maybe_Context;

   --  Whether the namespace has an index, and it belongs to this repository
   --  and this branch. Catches a folder renamed by hand, whose directory name
   --  and recorded fields disagree and would let one branch's graph answer for
   --  another. An absent field is a mismatch and not a match of empty against
   --  empty. A mismatch of the remote is the caller's to report.
   function Verify_Namespace
     (Env : Environment; Ctx : Context; Prog : String) return Boolean;

   --  A node's absolute path, whether Name has its `.md` or not.
   function Node_Path (Ctx : Context; Name : String) return String;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  One node's text, or none when there is no such node.
   function Read_Node (Ctx : Context; Name : String) return Maybe_Text;

   --  Name without its `.md`, which is how every finding names a node.
   function Strip_Md (Name : String) return String;

end Synapse.Commands.Context;
