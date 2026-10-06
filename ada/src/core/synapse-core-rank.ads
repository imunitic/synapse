with Ada.Strings.Unbounded;

--  Which of a node's sources are worth reading first when its prose is
--  written. Reading order only: `sources` stays exhaustive, so coverage,
--  staleness and search are unaffected. Three decisions that are functions of
--  a path: is it a test, what stem and module does it key under, and which
--  code file consumes a declaration. Tagging, sizing and printing belong to
--  the command.

package Synapse.Core.Rank is

   use Ada.Strings.Unbounded;

   --  Whether a path names a test, by its spelling alone. Any of:
   --
   --  1. a directory segment that is exactly `test`, `tests`, `spec`,
   --     `specs`, `__tests__` or `testing`; the file name does not count;
   --  2. a file stem ending in `Test`, `Tests` or `Spec` after a lowercase
   --     letter, a digit or a `.`, so that `Latest` is not a test;
   --  3. a file stem ending in `test`, `tests` or `spec` after `.`, `_` or
   --     `-`;
   --  4. a file name starting `test_` or `Test_`;
   --  5. a file stem longer than `_SUITE` that ends in it.
   --
   --  Alternatives 2 to 5 need the name to have an extension.
   function Is_Test (Path : String) return Boolean;

   --  How a path is keyed for the hop from a declaration to its consumer.
   type Key is record
      --  The file name with its final extension removed.
      Stem   : Unbounded_String;
      --  The first two directories, a shallower path's whole prefix, or
      --  `Repo_Root_Module` for a file with none: root files resolve only
      --  against each other.
      Module : Unbounded_String;
      Path   : Unbounded_String;
   end record;

   Repo_Root_Module : constant String := "(repo root)";

   function Key_Of (Path : String) return Key;

   --  Below this many characters a stem prefixes half the repository and is
   --  not a hop worth making.
   Min_Stem : constant := 3;

   --  Whether the declaration's stem prefixes the code file's stem within one
   --  module (`Widget.decl` to `WidgetHandler.ext`). Prefix and not equality,
   --  and the declaration's stem is always the prefix.
   function Consumes (Declaration, Code : Key) return Boolean;

   --  Definitions per kilobyte, the score of the code tier. Raw counts would
   --  rank a generated table of constants first.
   function Density
     (Definitions : Natural; Size_Bytes : Positive) return Long_Float;

end Synapse.Core.Rank;
