with Synapse.Core.JSON;

package body Synapse.Core.Node_Types is

   package J renames Synapse.Core.JSON;

   use type J.Kind;

   LF : constant Character := Character'Val (10);

   function Lower (C : Character) return Character is
     (if C in 'A' .. 'Z' then Character'Val (Character'Pos (C) + 32) else C);

   function Equal_Ignoring_Case (A, B : String) return Boolean is
   begin
      if A'Length /= B'Length then
         return False;
      end if;
      for I in 0 .. A'Length - 1 loop
         if Lower (A (A'First + I)) /= Lower (B (B'First + I)) then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Ignoring_Case;

   type Word_List is array (Positive range <>) of access constant String;

   Class_W     : aliased constant String := "class";
   Struct_W    : aliased constant String := "struct";
   Enum_W      : aliased constant String := "enum";
   Interface_W : aliased constant String := "interface";
   Trait_W     : aliased constant String := "trait";
   Module_W    : aliased constant String := "module";
   Namespace_W : aliased constant String := "namespace";
   Const_W     : aliased constant String := "const";
   Var_W       : aliased constant String := "var";
   Variable_W  : aliased constant String := "variable";
   Param_W     : aliased constant String := "param";
   Parameter_W : aliased constant String := "parameter";
   Package_W   : aliased constant String := "package";
   Import_W    : aliased constant String := "import";
   Container_W : aliased constant String := "container";
   Error_W     : aliased constant String := "error";
   Test_W      : aliased constant String := "test";

   --  The words a declaration may start with, in the order they are tried.
   Prefix_Kinds : constant Word_List :=
     [Class_W'Access, Struct_W'Access, Enum_W'Access, Interface_W'Access,
     Trait_W'Access, Module_W'Access, Namespace_W'Access, Const_W'Access,
     Var_W'Access, Variable_W'Access, Param_W'Access, Parameter_W'Access,
     Package_W'Access, Import_W'Access, Container_W'Access, Error_W'Access,
     Test_W'Access];

   --  The kind a word stands for when it is not its own. Each is the kind a
   --  grammar's own local definitions already use for the same node, except
   --  for the last two, which have no such precedent and take the closest
   --  label there is.
   function Kind_Of_Word (Word : String) return String is
     (if Word = "const" then "constant" elsif Word = "variable" then "var"
      elsif Word = "param" then "parameter"
      elsif Word = "package" or else Word = "import" then "namespace"
      elsif Word = "container" or else Word = "error" then "type" else Word);

   function Starts_Word (Type_Name : String; Word : String) return Boolean is
   begin
      if Type_Name'Length < Word'Length
        or else not Equal_Ignoring_Case
          (Type_Name (Type_Name'First .. Type_Name'First + Word'Length - 1),
           Word)
      then
         return False;
      end if;
      if Type_Name'Length = Word'Length then
         return True;
      end if;
      declare
         Next : constant Character :=
           Type_Name (Type_Name'First + Word'Length);
      begin
         return Next = '_' or else Next in 'A' .. 'Z';
      end;
   end Starts_Word;

   --  The kind of the word the name starts with, or "" for none.
   function Matched_Prefix_Kind (Type_Name : String) return String is
   begin
      for Word of Prefix_Kinds loop
         if Starts_Word (Type_Name, Word.all) then
            return Kind_Of_Word (Word.all);
         end if;
      end loop;
      return "";
   end Matched_Prefix_Kind;

   function Ends_With_Ignoring_Case (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Equal_Ignoring_Case
        (Text (Text'Last - Suffix'Length + 1 .. Text'Last), Suffix));

   function Has_Declaration_Suffix (Type_Name : String) return Boolean is
     (Ends_With_Ignoring_Case (Type_Name, "declaration")
      or else Ends_With_Ignoring_Case (Type_Name, "definition")
      or else Ends_With_Ignoring_Case (Type_Name, "_item")
      or else Ends_With_Ignoring_Case (Type_Name, "_specifier")
      or else Ends_With_Ignoring_Case (Type_Name, "decl")
      or else Ends_With_Ignoring_Case (Type_Name, "def")
      or else Ends_With_Ignoring_Case (Type_Name, "_binding"));

   function Has_Name_Field_In (Object : J.Value) return Boolean is
   begin
      if not J.Has_Member (Object, "fields") then
         return False;
      end if;
      declare
         Fields : constant J.Value := J.Member_Value (Object, "fields");
      begin
         return
           J.Kind_Of (Fields) = J.JSON_Object
           and then J.Has_Member (Fields, "name");
      end;
   end Has_Name_Field_In;

   function Classify
     (Json_Text : String; Rules : Kind_Synonyms.Rule_List; Scope : String)
      return Guess_Vectors.Vector
   is
      Parsed : constant J.Parse_Result := J.Parse (Json_Text);
      Result : Guess_Vectors.Vector;
   begin
      if not Parsed.Ok then
         raise Malformed;
      end if;
      if J.Kind_Of (Parsed.Item) /= J.JSON_Array then
         return Result;
      end if;
      for I in 1 .. J.Length (Parsed.Item) loop
         declare
            Item : constant J.Value := J.Element (Parsed.Item, I);
         begin
            if J.Kind_Of (Item) = J.JSON_Object
              and then J.Has_Member (Item, "named")
              and then J.Kind_Of (J.Member_Value (Item, "named")) =
                J.JSON_Boolean
              and then J.As_Boolean (J.Member_Value (Item, "named"))
              and then J.Has_Member (Item, "type")
              and then J.Kind_Of (J.Member_Value (Item, "type")) =
                J.JSON_String
              and then J.As_String (J.Member_Value (Item, "type"))'Length > 0
            then
               declare
                  Type_Name : constant String                   :=
                    J.As_String (J.Member_Value (Item, "type"));
                  Ruled     : constant Kind_Synonyms.Maybe_Kind :=
                    Kind_Synonyms.Kind_For (Rules, Type_Name, Scope);
               begin
                  if Ruled.Found or else Has_Declaration_Suffix (Type_Name)
                  then
                     declare
                        Prefix : constant String :=
                          Matched_Prefix_Kind (Type_Name);
                     begin
                        Result.Append
                          (Guess'
                             (Type_Name => To_Unbounded_String (Type_Name),
                              Kind           =>
                                (if Ruled.Found then Ruled.Kind
                                 elsif Prefix /= "" then
                                   To_Unbounded_String (Prefix)
                                 else To_Unbounded_String (Generic_Kind)),
                              Has_Name_Field => Has_Name_Field_In (Item)));
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Classify;

   function Build_Query (Guesses : Guess_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for G of Guesses loop
         if G.Has_Name_Field then
            Append
              (Text,
               "(" & To_String (G.Type_Name) & " name: (_) @name) " &
               "@definition." & To_String (G.Kind) & LF);
         end if;
      end loop;
      return To_String (Text);
   end Build_Query;

end Synapse.Core.Node_Types;
