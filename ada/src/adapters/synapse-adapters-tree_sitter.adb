with Ada.Unchecked_Conversion;

with Interfaces.C;
with Interfaces.C.Strings;

package body Synapse.Adapters.Tree_Sitter with SPARK_Mode => Off is

   use type Interfaces.C.int;
   use type System.Address;
   use type Thin.Language_Ptr;
   use type Thin.Parser_Ptr;
   use type Thin.Tree_Ptr;
   use type Thin.Query_Ptr;
   use type Thin.Cursor_Ptr;
   use type Thin.uint32_t;

   function To_Chars_Ptr is new
     Ada.Unchecked_Conversion (System.Address, Interfaces.C.Strings.chars_ptr);

   --  A NUL-terminated C string as an Ada string.
   function Text_Of (Item : System.Address) return String
   is (if Item = System.Null_Address
       then ""
       else
         Interfaces.C.To_Ada
           (Interfaces.C.Strings.Value (To_Chars_Ptr (Item))));

   --  A counted C string (not necessarily NUL-terminated) as an Ada string.
   function Text_Of
     (Item : System.Address; Length : Thin.uint32_t) return String
   is
   begin
      if Item = System.Null_Address or else Length = 0 then
         return "";
      end if;
      return
        Interfaces.C.To_Ada
          (Interfaces.C.Strings.Value
             (To_Chars_Ptr (Item), Interfaces.C.size_t (Length)),
           Trim_Nul => False);
   end Text_Of;

   function To_Natural (Value : Thin.uint32_t) return Natural
   is (Natural (Value));

   ---------------------------------------------------------------------------
   --  Languages
   ---------------------------------------------------------------------------

   function Is_Null (L : Language) return Boolean
   is (L.Handle = Thin.Null_Language);

   function ABI_Version (L : Language) return Natural
   is (To_Natural (Thin.ts_language_abi_version (L.Handle)));

   ---------------------------------------------------------------------------
   --  Nodes
   ---------------------------------------------------------------------------

   function Is_Null (N : Node) return Boolean
   is (Boolean (Thin.ts_node_is_null (N.Handle)));

   function Kind (N : Node) return String
   is (Text_Of (Thin.ts_node_type (N.Handle)));

   function Start_Byte (N : Node) return Natural
   is (To_Natural (Thin.ts_node_start_byte (N.Handle)));

   function End_Byte (N : Node) return Natural
   is (To_Natural (Thin.ts_node_end_byte (N.Handle)));

   function To_Point (Item : Thin.Point) return Point
   is (Row => To_Natural (Item.Row), Column => To_Natural (Item.Column));

   function Start_Point (N : Node) return Point
   is (To_Point (Thin.ts_node_start_point (N.Handle)));

   function End_Point (N : Node) return Point
   is (To_Point (Thin.ts_node_end_point (N.Handle)));

   function Named_Child_Count (N : Node) return Natural
   is (To_Natural (Thin.ts_node_named_child_count (N.Handle)));

   function Named_Child (N : Node; Index : Positive) return Node
   is (Handle =>
         Thin.ts_node_named_child (N.Handle, Thin.uint32_t (Index - 1)));

   function Child_By_Field (N : Node; Field : String) return Node
   is (Handle =>
         Thin.ts_node_child_by_field_name
           (N.Handle, Field'Address, Thin.uint32_t (Field'Length)));

   ---------------------------------------------------------------------------
   --  Parsing
   ---------------------------------------------------------------------------

   overriding
   procedure Initialize (O : in out Parser_Owner) is
   begin
      O.Handle := Thin.ts_parser_new;
   end Initialize;

   overriding
   procedure Finalize (O : in out Parser_Owner) is
   begin
      if O.Handle /= Thin.Null_Parser then
         Thin.ts_parser_delete (O.Handle);
         O.Handle := Thin.Null_Parser;
      end if;
   end Finalize;

   overriding
   procedure Finalize (O : in out Tree_Owner) is
   begin
      if O.Handle /= Thin.Null_Tree then
         Thin.ts_tree_delete (O.Handle);
         O.Handle := Thin.Null_Tree;
      end if;
   end Finalize;

   procedure Set_Language
     (P : in out Parser; L : Language; OK : out Boolean)
   is
   begin
      OK :=
        Boolean (Thin.ts_parser_set_language (P.Owner.Handle, L.Handle));
   end Set_Language;

   function Parse (P : in out Parser; Source : String) return Tree is
   begin
      return Result : Tree do
         Result.Owner.Handle :=
           Thin.ts_parser_parse_string
             (P.Owner.Handle,
              Thin.Null_Tree,
              Source'Address,
              Thin.uint32_t (Source'Length));
      end return;
   end Parse;

   function Is_Null (T : Tree) return Boolean
   is (T.Owner.Handle = Thin.Null_Tree);

   function Root (T : Tree) return Node
   is (Handle => Thin.ts_tree_root_node (T.Owner.Handle));

   ---------------------------------------------------------------------------
   --  Queries
   ---------------------------------------------------------------------------

   overriding
   procedure Finalize (O : in out Query_Owner) is
   begin
      if O.Handle /= Thin.Null_Query then
         Thin.ts_query_delete (O.Handle);
         O.Handle := Thin.Null_Query;
      end if;
   end Finalize;

   procedure Compile
     (Q            : in out Query;
      L            : Language;
      Source       : String;
      Status       : out Query_Status;
      Error_Offset : out Natural)
   is
      Offset : aliased Thin.uint32_t := 0;
      Error  : aliased Thin.Query_Error := Thin.None;
   begin
      Finalize (Q.Owner);
      Q.Owner.Handle :=
        Thin.ts_query_new
          (L.Handle,
           Source'Address,
           Thin.uint32_t (Source'Length),
           Offset'Access,
           Error'Access);
      Error_Offset := To_Natural (Offset);
      Status :=
        (case Error is
           when Thin.None      => Compiled,
           when Thin.Syntax    => Syntax_Error,
           when Thin.Node_Type => Unknown_Node_Type,
           when Thin.Field     => Unknown_Field,
           when Thin.Capture   => Unknown_Capture,
           when Thin.Structure => Structure_Error,
           when Thin.Language  => Language_Mismatch);
      if Status /= Compiled then
         Q.Owner.Handle := Thin.Null_Query;
      end if;
   end Compile;

   function Is_Compiled (Q : Query) return Boolean
   is (Q.Owner.Handle /= Thin.Null_Query);

   function Pattern_Count (Q : Query) return Natural
   is (To_Natural (Thin.ts_query_pattern_count (Q.Owner.Handle)));

   procedure Disable_Pattern (Q : in out Query; Index : Natural) is
   begin
      Thin.ts_query_disable_pattern (Q.Owner.Handle, Thin.uint32_t (Index));
   end Disable_Pattern;

   function Capture_Name (Q : Query; Id : Natural) return String is
      Length : aliased Thin.uint32_t := 0;
      Name   : constant System.Address :=
        Thin.ts_query_capture_name_for_id
          (Q.Owner.Handle, Thin.uint32_t (Id), Length'Access);
   begin
      return Text_Of (Name, Length);
   end Capture_Name;

   function String_Value (Q : Query; Id : Natural) return String is
      Length : aliased Thin.uint32_t := 0;
      Value  : constant System.Address :=
        Thin.ts_query_string_value_for_id
          (Q.Owner.Handle, Thin.uint32_t (Id), Length'Access);
   begin
      return Text_Of (Value, Length);
   end String_Value;

   function Predicates (Q : Query; Pattern : Natural) return Predicate_Steps is
      Count : aliased Thin.uint32_t := 0;
      Steps : constant System.Address :=
        Thin.ts_query_predicates_for_pattern
          (Q.Owner.Handle, Thin.uint32_t (Pattern), Count'Access);
   begin
      if Steps = System.Null_Address or else Count = 0 then
         return [1 .. 0 => (Kind => Done, Value => 0)];
      end if;

      declare
         type Step_Array is
           array (Natural range <>) of Thin.Predicate_Step
         with Convention => C;

         Raw : Step_Array (0 .. Natural (Count) - 1)
         with Import, Address => Steps;

         function To_Step (Item : Thin.Predicate_Step) return Predicate_Step
         is (Kind  =>
               (if Item.Kind = Thin.Step_Capture
                then Capture
                elsif Item.Kind = Thin.Step_String
                then String_Literal
                else Done),
             Value => To_Natural (Item.Value_Id));
         Result : Predicate_Steps (1 .. Raw'Length);
      begin
         for I in Result'Range loop
            Result (I) := To_Step (Raw (I - 1));
         end loop;
         return Result;
      end;
   end Predicates;

   ---------------------------------------------------------------------------
   --  Cursors
   ---------------------------------------------------------------------------

   overriding
   procedure Initialize (O : in out Cursor_Owner) is
   begin
      O.Handle := Thin.ts_query_cursor_new;
   end Initialize;

   overriding
   procedure Finalize (O : in out Cursor_Owner) is
   begin
      if O.Handle /= Thin.Null_Cursor then
         Thin.ts_query_cursor_delete (O.Handle);
         O.Handle := Thin.Null_Cursor;
      end if;
   end Finalize;

   procedure Exec (C : in out Cursor; Q : Query; Root : Node) is
   begin
      Thin.ts_query_cursor_exec (C.Owner.Handle, Q.Owner.Handle, Root.Handle);
   end Exec;

   function Pattern (M : Match) return Natural
   is (M.Pattern_Index);

   function Capture_Count (M : Match) return Natural
   is (Natural (M.Items.Length));

   function Capture (M : Match; Index : Positive) return Match_Capture
   is (M.Items (Index));

   procedure Next_Match
     (C : in out Cursor; Found : out Boolean; M : out Match)
   is
      Raw : aliased Thin.Query_Match;
   begin
      Found :=
        Boolean (Thin.ts_query_cursor_next_match (C.Owner.Handle, Raw'Access));
      M.Items.Clear;
      M.Pattern_Index := 0;
      if not Found then
         return;
      end if;

      declare
         Count : constant Natural := Natural (Raw.Capture_Count);

         type Capture_Raw_Array is
           array (Natural range <>) of Thin.Query_Capture
         with Convention => C;

         Captures : Capture_Raw_Array (0 .. Count - 1)
         with Import, Address => Raw.Captures;
      begin
         M.Pattern_Index := Natural (Raw.Pattern_Index);
         for I in Captures'Range loop
            M.Items.Append
              (Match_Capture'
                 (Captured => (Handle => Captures (I).Node),
                  Id       => To_Natural (Captures (I).Index)));
         end loop;
      end;
   end Next_Match;

end Synapse.Adapters.Tree_Sitter;
