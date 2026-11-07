with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Variables;

--  Finding and reading Synapse's configuration files. Where a variable comes
--  from is passed in, so none of this touches the real environment unless the
--  caller hands it the system's.

package Synapse.Adapters.Conf_Files is

   package Vars renames Synapse.Ports.Variables;

   subtype Variables is Vars.Variables'Class;

   --  There is no home directory to put a new file in.
   No_Home : exception;

   subtype Maybe_Path is Synapse.Core.Optional_Text.Option;

   --  The configuration files, in the order they are tried. The second is the
   --  name the first had before it was renamed.
   Primary_Name : constant String := "synapse.conf";
   Legacy_Name  : constant String := "second-brain.conf";

   --  The first of these that exists:
   --  1. `$XDG_CONFIG_HOME/synapse/Name`, when that variable is set and not
   --     empty;
   --  2. `~/.config/synapse/Name`;
   --  3. `~/.claude/Name`;
   --  4. read-only, `Name.template` under `$SYNAPSE_CONTENT_ROOT`, the folder
   --     the npm package is installed in: the defaults the package ships
   --     with, which never shadow a file a user made.
   function Resolve_Conf_Path (V : Variables; Name : String) return Maybe_Path;

   --  Where to write Name: an existing file of the first three tiers, else a
   --  new one under `$XDG_CONFIG_HOME/synapse/` when that is set, else under
   --  `~/.config/synapse/` when `~/.config` is a directory, else under
   --  `~/.claude/`. Never the template. Raises No_Home without one of the
   --  variables that gives a place.
   function Resolve_Write_Path (V : Variables; Name : String) return String;

   --  A key's value: the variable of that name when it is set and not empty,
   --  else the first of the two configuration files, each found through
   --  Resolve_Conf_Path, that defines it as non-empty, expanded. Nothing when
   --  nothing names it. A file over 1 MiB is ignored.
   function Resolve (V : Variables; Key : String) return Maybe_Path;

   --  Where a key's value comes from.
   type Origin is (Nowhere, From_Variable, From_File);

   type Detail is record
      --  Where the value Resolve gives comes from.
      From      : Origin := Nowhere;

      --  That value, expanded.
      Value     : Core.Optional_Text.Option;

      --  The file that defines the key, as it is written there, and which
      --  file it is, whether or not a variable shadows it.
      File      : Maybe_Path;
      Raw       : Core.Optional_Text.Option;

      --  A variable of the key's name is set and the file defines it too.
      Shadowed  : Boolean := False;
   end record;

   --  Everything Resolve looks at, and where it found the value. A variable
   --  of the key's name is looked at only when Use_Variable.
   function Describe
     (V : Variables; Key : String; Use_Variable : Boolean := True)
      return Detail;

   function Vault_Dir (V : Variables) return Maybe_Path;

   --  How many commits ahead of the upstream make a push due: the value of
   --  SYNAPSE_VAULT_PUSH_EVERY, 5 when it is unset or not a number. Zero
   --  means never.
   function Push_Every (V : Variables) return Natural;

   --  The words of `synapse-prompt-stopwords.conf`, found through
   --  Resolve_Conf_Path and then `~/.claude/`; empty with no home or no file.
   function Load_Stopwords (V : Variables) return Core.Text_Lists.Set;

end Synapse.Adapters.Conf_Files;
