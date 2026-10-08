--  A git repository holding a fixture grammar, to clone from: the real path
--  from a registry entry to a loaded grammar without leaving the machine.

package Synapse.Test_Grammar_Repos is

   --  Makes the repository `<Dir>/<Name>` from the fixture grammar `Fixture`
   --  (its sources and, when it has one, its `node-types.json`), with
   --  `queries/tags.scm` and `queries/locals.scm` when their text is not
   --  empty, committed on one commit.
   procedure Make
     (Dir        : String;
      Name       : String;
      Fixture    : String;
      Tags_Scm   : String := "";
      Locals_Scm : String := "");

end Synapse.Test_Grammar_Repos;
