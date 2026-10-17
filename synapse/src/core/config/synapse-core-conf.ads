with Synapse.Core.Optional_Text;
with Synapse.Ports.Variables;

--  Shell-style configuration files: `KEY=value` lines, read directly and
--  never sourced. Values expand like a shell expands a path.

package Synapse.Core.Conf is

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  One key's raw value from a file's text. Blank lines and `#` lines are
   --  skipped, an `export ` prefix is allowed, the key must be followed
   --  directly by `=` (a longer key is not matched by a shorter one), and
   --  the last assignment wins. A value in matching quotes loses them; an
   --  unquoted one is cut at its first blank or `#`.
   function Get (Text, Key : String) return Maybe_Text;

   --  A leading `~` (alone or before `/`) replaced by HOME; `$NAME` and
   --  `${NAME}` by the variable, nothing when it is unset, as in a shell;
   --  `\$` is a literal `$`. `~user`, `${V:-default}`, an unterminated `${`,
   --  a `$` that starts no name and every other backslash stay as written.
   function Expand
     (Raw : String; Vars : Ports.Variables.Variables'Class) return String;

   --  Get, then Expand.
   function Value
     (Text, Key : String; Vars : Ports.Variables.Variables'Class)
      return Maybe_Text;

end Synapse.Core.Conf;
