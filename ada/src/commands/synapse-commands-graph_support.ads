with Ada.Strings.Unbounded;

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

end Synapse.Commands.Graph_Support;
