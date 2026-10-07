with Ada.Strings.Unbounded;

with Synapse.Core.Namespace;
with Synapse.Core.Optional_Text;

--  What the commands over a namespace's work directory share: finding the
--  directory, how much of a listing to read, and running `grep`.
package Synapse.Commands.Graph_Support is

   subtype Maybe_Path is Synapse.Core.Optional_Text.Option;

   --  The work directory of the repository at Repo: `SYNAPSE_WORK_DIR` when
   --  set, else the cache directory named for the namespace, which is
   --  `SYNAPSE_NAMESPACE` when set and the checkout's own otherwise. Not
   --  found, after saying why on standard error with Prog in front, when
   --  there is no repository, the head is detached or there is no home.
   function Work_Dir
     (Env : Environment; Prog : String; Repo : String := ".")
      return Maybe_Path;

   --  The work directory of a namespace named as `{repo}@{branch}`, which
   --  needs no checkout. Not found, after saying why, for a name without
   --  the `@` or with no home to hold the cache.
   function Work_Dir_For_Namespace
     (Env : Environment; Namespace : String; Prog : String) return Maybe_Path;

   --  The root of the checkout containing Repo, or the working directory
   --  when Repo is empty: `git rev-parse --show-toplevel`. Empty when it is
   --  in none.
   function Repo_Root (Env : Environment; Repo : String) return String;

   --  Whether the name of Path ends in `.ext` for an Ext of Usable. A name
   --  that only starts with its dot, as `.profile` does, has no extension.
   function Has_Usable_Extension
     (Path : String; Usable : Lists.Vector) return Boolean;

   --  A registry of per extension rules (`synapse-namespace-rules.conf`,
   --  `synapse-dependency-rules.conf`): the file Variable_Name names when that
   --  is set, else Conf_Name found through the configuration tiers, else in
   --  the home's `.claude`. A missing file is no rules; Ok is false for one
   --  that is there and cannot be read or is not JSON.
   procedure Load_Rule_Registry
     (Env   :     Environment; Variable_Name, Conf_Name : String;
      Rules : out Core.Namespace.Registry; Ok : out Boolean);

   --  How many bytes of a listing a command reads: `SYNAPSE_MAX_LISTING_BYTES`
   --  when it is a number, else Default. Raising it is a deliberate act of
   --  one invocation and not a setting that follows every clone.
   function Max_Listing_Bytes
     (Env : Environment; Default : Natural) return Natural;

   --  The text of a file and whether it could be read: not when it is
   --  missing, unreadable or over Limit bytes.
   procedure Read_File
     (Path :     String; Limit : Natural;
      Text : out Ada.Strings.Unbounded.Unbounded_String; Found : out Boolean);

   --  Creates or replaces a file, making its directory if it has none.
   procedure Write_File (Path, Text : String);

   --  What `grep` made of its input: success, or why not.
   type Grep_Outcome is (Matched, Nothing_Matched, Failed);

   --  `grep Flag Pattern` over Input (`-E` keeps the lines that match, `-vE`
   --  drops them). It is the real `grep`: the patterns are the user's own
   --  and mean what `grep` says they mean.
   procedure Grep
     (Env    :     Environment; Flag, Pattern, Input : String;
      Output : out Ada.Strings.Unbounded.Unbounded_String;
      Result : out Grep_Outcome);

   --  Removes the namespace directory Ns_Dir, which must lie inside
   --  `{Vault}/synapse/`: a recursive delete of a resolved path is one
   --  substitution away from a much larger one. False, after saying why with
   --  Prog in front, for a directory outside it or one that cannot be
   --  removed.
   function Remove_Namespace
     (Env : Environment; Vault, Ns_Dir, Prog : String) return Boolean;

end Synapse.Commands.Graph_Support;
