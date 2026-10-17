with Ada.Strings.Unbounded;

--  Checking the docstrings of a file against the docstring index: a real
--  parse, a comparison with what the index holds, and the index brought up to
--  date. Shared by `comments-check` (one file) and `comments-sweep` (every
--  file) so the two agree on what checking a file is.
package Synapse.Commands.Docstring_Check is

   --  Skipped: the feature is off, the extension has no usable grammar, the
   --  file cannot be read or the index cannot be written to. Failed: the
   --  configuration or the parse is unusable, and Why says how.
   type Status is (Skipped, Checked, Failed);

   type Result is record
      Which   : Status  := Skipped;
      --  What is new or changed, for a person; empty when nothing is.
      Report  : Ada.Strings.Unbounded.Unbounded_String;
      Why     : Ada.Strings.Unbounded.Unbounded_String;
      Pairs   : Natural := 0;
      Updated : Natural := 0;
      Evicted : Natural := 0;
   end record;

   --  The file at Rel_Path below Repo_Root, its index under Work.
   function Check_File
     (Env : Environment; Repo_Root, Work, Rel_Path : String) return Result;

end Synapse.Commands.Docstring_Check;
