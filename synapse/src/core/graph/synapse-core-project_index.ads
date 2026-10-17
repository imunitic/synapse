with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  `synapse/{repo}@{branch}/Index.md`: the node map of a namespace. It lives
--  in core because it is written once and read in three places: the session
--  start checks its `remote`, a query's preamble checks `remote` and
--  `branch`, and writing a node checks both.
--
--  `project` is the repository half alone (the key is already the title and
--  the folder name), so a bare repository name groups every branch's
--  namespace in a vault query; `branch` stays its own field so identity can
--  be checked without parsing a directory name.

package Synapse.Core.Project_Index is

   use Ada.Strings.Unbounded;

   --  One node's line in the map.
   type Bullet is record
      --  The node's file name without the extension, already sanitized: what
      --  the link resolves against.
      Link    : Unbounded_String;
      Files   : Natural;
      --  The node's own `summary`, read back off the node.
      Summary : Unbounded_String;
   end record;

   package Bullet_Vectors is new Ada.Containers.Vectors (Positive, Bullet);

   type Params is record
      Namespace   : Unbounded_String;  --  `repo@branch`
      Project     : Unbounded_String;  --  the repository half alone
      Branch      : Unbounded_String;
      Remote      : Unbounded_String;
      Built_At    : Unbounded_String;
      Total_Files : Natural := 0;
      --  Sorted by Link by the caller, since a reader scans for a name.
      Bullets     : Bullet_Vectors.Vector;
   end record;

   --  The text of the index. The node count is the number of bullets, so it
   --  cannot disagree with what is printed.
   function Image (P : Params) return String;

end Synapse.Core.Project_Index;
