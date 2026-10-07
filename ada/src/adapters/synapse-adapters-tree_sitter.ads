--  Safe Ada view of libtree-sitter, covering what Synapse uses: parsing text
--  into a syntax tree, walking nodes, and running queries over a tree.
--
--  Every C object has exactly one owner that frees it: Parser, Tree, Query and
--  Cursor are limited controlled types. A Node is a plain value that points
--  into its Tree and must not outlive it. Byte offsets are 0-based and refer
--  to the text that was parsed, as in tree-sitter itself; Child indexes are
--  1-based.

with Ada.Containers.Vectors;
with Ada.Finalization;

private with Synapse.Adapters.Tree_Sitter_Thin;
private with System;

package Synapse.Adapters.Tree_Sitter with SPARK_Mode => Off is

   --  Grammar ABI versions the vendored runtime parses with.
   ABI_Min : constant := 13;
   ABI_Max : constant := 15;

   ---------------------------------------------------------------------------
   --  Languages
   ---------------------------------------------------------------------------

   --  A grammar's language object. It lives as long as the library it came
   --  from, which the loader never unloads.
   type Language is private;

   No_Language : constant Language;

   function Is_Null (L : Language) return Boolean;

   function ABI_Version (L : Language) return Natural
   with Pre => not Is_Null (L);

   ---------------------------------------------------------------------------
   --  Nodes
   ---------------------------------------------------------------------------

   type Point is record
      Row    : Natural;
      Column : Natural;
   end record;

   type Node is private;

   No_Node : constant Node;

   function Is_Null (N : Node) return Boolean;

   function Kind (N : Node) return String
   with Pre => not Is_Null (N);

   function Start_Byte (N : Node) return Natural
   with Pre => not Is_Null (N);

   --  One past the last byte.
   function End_Byte (N : Node) return Natural
   with Pre => not Is_Null (N);

   function Start_Point (N : Node) return Point
   with Pre => not Is_Null (N);

   function End_Point (N : Node) return Point
   with Pre => not Is_Null (N);

   function Named_Child_Count (N : Node) return Natural
   with Pre => not Is_Null (N);

   function Named_Child (N : Node; Index : Positive) return Node
   with Pre => not Is_Null (N) and then Index <= Named_Child_Count (N);

   --  Whether the bytes of N lie within Source, the text that was parsed.
   function Lies_Within (N : Node; Source : String) return Boolean
   with Pre => not Is_Null (N);

   --  The text of N in Source, which is the text that was parsed.
   function Text_Of (N : Node; Source : String) return String
   with Pre => not Is_Null (N) and then Lies_Within (N, Source);

   --  The child filling a named grammar field; null when there is none.
   function Child_By_Field (N : Node; Field : String) return Node
   with Pre => not Is_Null (N);

   ---------------------------------------------------------------------------
   --  Parsing
   ---------------------------------------------------------------------------

   type Parser is limited private;

   type Tree is limited private;

   procedure Set_Language (P : in out Parser; L : Language; OK : out Boolean)
   with Pre => not Is_Null (L);

   --  Parses Source. The result is null when no language has been set.
   function Parse (P : in out Parser; Source : String) return Tree;

   function Is_Null (T : Tree) return Boolean;

   function Root (T : Tree) return Node
   with Pre => not Is_Null (T);

   ---------------------------------------------------------------------------
   --  Queries
   ---------------------------------------------------------------------------

   type Query_Status is
     (Compiled,
      Syntax_Error,
      Unknown_Node_Type,
      Unknown_Field,
      Unknown_Capture,
      Structure_Error,
      Language_Mismatch);

   type Query is limited private;

   --  Compiles Source for L. On failure Error_Offset is the byte offset of the
   --  problem and the query stays empty.
   procedure Compile
     (Q            : in out Query;
      L            : Language;
      Source       : String;
      Status       : out Query_Status;
      Error_Offset : out Natural)
   with Pre => not Is_Null (L);

   function Is_Compiled (Q : Query) return Boolean;

   function Pattern_Count (Q : Query) return Natural
   with Pre => Is_Compiled (Q);

   --  Stops a pattern from matching; its index stays valid.
   procedure Disable_Pattern (Q : in out Query; Index : Natural)
   with Pre => Is_Compiled (Q) and then Index < Pattern_Count (Q);

   --  The name of capture Id, without its leading '@'.
   function Capture_Name (Q : Query; Id : Natural) return String
   with Pre => Is_Compiled (Q);

   --  The string a predicate step refers to.
   function String_Value (Q : Query; Id : Natural) return String
   with Pre => Is_Compiled (Q);

   type Predicate_Kind is (Done, Capture, String_Literal);

   type Predicate_Step is record
      Kind  : Predicate_Kind;
      Value : Natural;  --  a capture id or a string id, per Kind
   end record;

   type Predicate_Steps is array (Positive range <>) of Predicate_Step;

   --  The predicate steps of one pattern: groups ending in a Done step.
   function Predicates (Q : Query; Pattern : Natural) return Predicate_Steps
   with Pre => Is_Compiled (Q) and then Pattern < Pattern_Count (Q);

   type Cursor is limited private;

   --  Starts running Q over the nodes below Root. Q and the Tree behind Root
   --  must stay alive until the matches have been read.
   procedure Exec (C : in out Cursor; Q : Query; Root : Node)
   with Pre => Is_Compiled (Q) and then not Is_Null (Root);

   type Match_Capture is record
      Captured : Node;
      Id       : Natural;  --  index for Capture_Name
   end record;

   --  One match: the pattern that matched and its captures.
   type Match is private;

   function Pattern (M : Match) return Natural;

   function Capture_Count (M : Match) return Natural;

   function Capture (M : Match; Index : Positive) return Match_Capture
   with Pre => Index <= Capture_Count (M);

   --  The next match; Found is False once the matches are exhausted.
   procedure Next_Match
     (C : in out Cursor; Found : out Boolean; M : out Match);

private

   package Thin renames Synapse.Adapters.Tree_Sitter_Thin;

   type Language is record
      Handle : Thin.Language_Ptr := Thin.Null_Language;
   end record;

   No_Language : constant Language := (Handle => Thin.Null_Language);

   type Node is record
      Handle : Thin.Node;
   end record;

   No_Node : constant Node :=
     (Handle =>
        (Context => [others => 0],
         Id      => System.Null_Address,
         Tree    => System.Null_Address));

   package Capture_Vectors is new
     Ada.Containers.Vectors (Positive, Match_Capture);

   type Match is record
      Pattern_Index : Natural := 0;
      Items         : Capture_Vectors.Vector;
   end record;

   --  Each C object is owned by a controlled component, so the visible types
   --  themselves stay untagged and carry no dispatching operations.

   type Parser_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : Thin.Parser_Ptr := Thin.Null_Parser;
   end record;

   overriding
   procedure Initialize (O : in out Parser_Owner);

   overriding
   procedure Finalize (O : in out Parser_Owner);

   type Parser is limited record
      Owner : Parser_Owner;
   end record;

   type Tree_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : Thin.Tree_Ptr := Thin.Null_Tree;
   end record;

   overriding
   procedure Finalize (O : in out Tree_Owner);

   type Tree is limited record
      Owner : Tree_Owner;
   end record;

   type Query_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : Thin.Query_Ptr := Thin.Null_Query;
   end record;

   overriding
   procedure Finalize (O : in out Query_Owner);

   type Query is limited record
      Owner : Query_Owner;
   end record;

   type Cursor_Owner is new Ada.Finalization.Limited_Controlled with record
      Handle : Thin.Cursor_Ptr := Thin.Null_Cursor;
   end record;

   overriding
   procedure Initialize (O : in out Cursor_Owner);

   overriding
   procedure Finalize (O : in out Cursor_Owner);

   type Cursor is limited record
      Owner : Cursor_Owner;
   end record;

end Synapse.Adapters.Tree_Sitter;
