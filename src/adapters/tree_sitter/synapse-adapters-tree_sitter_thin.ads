--  Direct bindings to the libtree-sitter C API, for the functions Synapse
--  calls and nothing else. Everything here is unchecked C: use the safe
--  wrapper in Synapse.Adapters.Tree_Sitter instead.

with Interfaces;
with Interfaces.C;
with System;

package Synapse.Adapters.Tree_Sitter_Thin with SPARK_Mode => Off is

   subtype uint32_t is Interfaces.Unsigned_32;
   subtype uint16_t is Interfaces.Unsigned_16;

   --  Opaque C objects. Each is only ever passed back to the library.
   type Parser_Ptr is new System.Address;
   type Tree_Ptr is new System.Address;
   type Query_Ptr is new System.Address;
   type Cursor_Ptr is new System.Address;
   type Language_Ptr is new System.Address;

   Null_Parser   : constant Parser_Ptr := Parser_Ptr (System.Null_Address);
   Null_Tree     : constant Tree_Ptr := Tree_Ptr (System.Null_Address);
   Null_Query    : constant Query_Ptr := Query_Ptr (System.Null_Address);
   Null_Cursor   : constant Cursor_Ptr := Cursor_Ptr (System.Null_Address);
   Null_Language : constant Language_Ptr :=
     Language_Ptr (System.Null_Address);

   --  TSPoint, returned by value. Records are passed to C as pointers unless
   --  their convention is C_Pass_By_Copy (RM B.3), so the structs the C API
   --  takes or returns by value carry that convention.
   type Point is record
      Row    : uint32_t;
      Column : uint32_t;
   end record
   with Convention => C_Pass_By_Copy;

   type Context_Array is array (0 .. 3) of uint32_t with Convention => C;

   --  TSNode, passed and returned by value.
   type Node is record
      Context : Context_Array;
      Id      : System.Address;
      Tree    : System.Address;
   end record
   with Convention => C_Pass_By_Copy;

   type Query_Capture is record
      Node  : Tree_Sitter_Thin.Node;
      Index : uint32_t;
   end record
   with Convention => C;

   type Query_Match is record
      Id            : uint32_t;
      Pattern_Index : uint16_t;
      Capture_Count : uint16_t;
      Captures      : System.Address;  --  const TSQueryCapture *
   end record
   with Convention => C;

   --  TSQueryPredicateStepType values.
   Step_Done    : constant Interfaces.C.int := 0;
   Step_Capture : constant Interfaces.C.int := 1;
   Step_String  : constant Interfaces.C.int := 2;

   type Predicate_Step is record
      Kind     : Interfaces.C.int;
      Value_Id : uint32_t;
   end record
   with Convention => C;

   --  TSQueryError values.
   type Query_Error is
     (None, Syntax, Node_Type, Field, Capture, Structure, Language)
   with Convention => C;

   function ts_parser_new return Parser_Ptr
   with Import, Convention => C, External_Name => "ts_parser_new";

   procedure ts_parser_delete (Parser : Parser_Ptr)
   with Import, Convention => C, External_Name => "ts_parser_delete";

   function ts_parser_set_language
     (Parser : Parser_Ptr; Language : Language_Ptr) return Interfaces.C.C_bool
   with Import, Convention => C, External_Name => "ts_parser_set_language";

   function ts_parser_parse_string
     (Parser   : Parser_Ptr;
      Old_Tree : Tree_Ptr;
      Source   : System.Address;
      Length   : uint32_t) return Tree_Ptr
   with Import, Convention => C, External_Name => "ts_parser_parse_string";

   procedure ts_tree_delete (Tree : Tree_Ptr)
   with Import, Convention => C, External_Name => "ts_tree_delete";

   function ts_tree_root_node (Tree : Tree_Ptr) return Node
   with Import, Convention => C, External_Name => "ts_tree_root_node";

   function ts_node_type (Item : Node) return System.Address
   with Import, Convention => C, External_Name => "ts_node_type";

   function ts_node_start_byte (Item : Node) return uint32_t
   with Import, Convention => C, External_Name => "ts_node_start_byte";

   function ts_node_end_byte (Item : Node) return uint32_t
   with Import, Convention => C, External_Name => "ts_node_end_byte";

   function ts_node_start_point (Item : Node) return Point
   with Import, Convention => C, External_Name => "ts_node_start_point";

   function ts_node_end_point (Item : Node) return Point
   with Import, Convention => C, External_Name => "ts_node_end_point";

   function ts_node_is_null (Item : Node) return Interfaces.C.C_bool
   with Import, Convention => C, External_Name => "ts_node_is_null";

   function ts_node_named_child_count (Item : Node) return uint32_t
   with Import, Convention => C, External_Name => "ts_node_named_child_count";

   function ts_node_named_child (Item : Node; Index : uint32_t) return Node
   with Import, Convention => C, External_Name => "ts_node_named_child";

   function ts_node_child_by_field_name
     (Item : Node; Name : System.Address; Name_Length : uint32_t) return Node
   with
     Import,
     Convention    => C,
     External_Name => "ts_node_child_by_field_name";

   function ts_query_new
     (Language     : Language_Ptr;
      Source       : System.Address;
      Source_Len   : uint32_t;
      Error_Offset : access uint32_t;
      Error_Type   : access Query_Error) return Query_Ptr
   with Import, Convention => C, External_Name => "ts_query_new";

   procedure ts_query_delete (Query : Query_Ptr)
   with Import, Convention => C, External_Name => "ts_query_delete";

   function ts_query_pattern_count (Query : Query_Ptr) return uint32_t
   with Import, Convention => C, External_Name => "ts_query_pattern_count";

   procedure ts_query_disable_pattern
     (Query : Query_Ptr; Pattern_Index : uint32_t)
   with Import, Convention => C, External_Name => "ts_query_disable_pattern";

   function ts_query_predicates_for_pattern
     (Query         : Query_Ptr;
      Pattern_Index : uint32_t;
      Step_Count    : access uint32_t) return System.Address
   with
     Import,
     Convention    => C,
     External_Name => "ts_query_predicates_for_pattern";

   function ts_query_capture_name_for_id
     (Query : Query_Ptr; Index : uint32_t; Length : access uint32_t)
      return System.Address
   with
     Import,
     Convention    => C,
     External_Name => "ts_query_capture_name_for_id";

   function ts_query_string_value_for_id
     (Query : Query_Ptr; Index : uint32_t; Length : access uint32_t)
      return System.Address
   with
     Import,
     Convention    => C,
     External_Name => "ts_query_string_value_for_id";

   function ts_query_cursor_new return Cursor_Ptr
   with Import, Convention => C, External_Name => "ts_query_cursor_new";

   procedure ts_query_cursor_delete (Cursor : Cursor_Ptr)
   with Import, Convention => C, External_Name => "ts_query_cursor_delete";

   procedure ts_query_cursor_exec
     (Cursor : Cursor_Ptr; Query : Query_Ptr; Root : Node)
   with Import, Convention => C, External_Name => "ts_query_cursor_exec";

   function ts_query_cursor_next_match
     (Cursor : Cursor_Ptr; Item : access Query_Match)
      return Interfaces.C.C_bool
   with
     Import,
     Convention    => C,
     External_Name => "ts_query_cursor_next_match";

   function ts_language_abi_version (Language : Language_Ptr) return uint32_t
   with Import, Convention => C, External_Name => "ts_language_abi_version";

end Synapse.Adapters.Tree_Sitter_Thin;
