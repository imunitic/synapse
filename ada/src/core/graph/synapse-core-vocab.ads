--  The keys vocabulary evidence is grouped under: where a file sits, and what
--  kind of artifact it is. Splitting identifiers into words is `Core.Words`.

package Synapse.Core.Vocab is

   --  The name a file with no directory is grouped under. Named and not
   --  dropped, so it stays visible; the per-group counts use the same key.
   Repo_Root_Group : constant String := "(repo root)";

   --  The first Depth directory segments of a `/` separated path:
   --  `src/main` from `src/main/java/Foo.java` at depth 2. A shallower path
   --  groups by the prefix it has, and the file name is never a group.
   function Group_Of (Path : String; Depth : Natural) return String;

   --  What kind of artifact a path is: its lowercased extension, or its
   --  lowercased file name when it has none, since `Makefile` and `dune` are
   --  evidence and not noise to fold into one bucket. A leading dot makes an
   --  extension (`.gitignore` is `gitignore`) and a trailing one makes none.
   --  Only ASCII letters are lowercased.
   function Artifact_Of (Path : String) return String;

end Synapse.Core.Vocab;
