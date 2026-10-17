with Synapse.Core.Glob;
with Synapse.Core.Regex_Lite;

package body Synapse.Core.JSON_Logic with SPARK_Mode => Off is

   use JSON;

   ---------------------------------------------------------------------------
   --  The operator list
   ---------------------------------------------------------------------------

   function Built_In_Name (Index : Positive) return String
   is (case Index is
         when 1  => "var",
         when 2  => "and",
         when 3  => "or",
         when 4  => "!",
         when 5  => "==",
         when 6  => "!=",
         when 7  => "in",
         when 8  => "<",
         when 9  => "<=",
         when 10 => ">",
         when 11 => ">=",
         when 12 => "glob",
         when 13 => "regexp",
         when 14 => "all",
         when 15 => "xor",
         when others => "starts_with");

   function Is_Built_In (Name : String) return Boolean is
   begin
      for I in 1 .. Built_In_Count loop
         if Built_In_Name (I) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Is_Built_In;

   overriding
   function Has_Operator (Set : No_Operators_Set; Name : String) return Boolean
   is (False);

   overriding
   function Apply
     (Set   : No_Operators_Set;
      Name  : String;
      Args  : JSON.Value_Array;
      Where : Scope) return JSON.Value
   is
   begin
      raise Unknown_Operator with Name;
      return JSON.Null_Value;
   end Apply;

   ---------------------------------------------------------------------------
   --  Truthiness, numbers, equality
   ---------------------------------------------------------------------------

   function Truthy (V : Value) return Boolean is
   begin
      case Kind_Of (V) is
         when JSON_Null =>
            return False;

         when JSON_Boolean =>
            return As_Boolean (V);

         when JSON_Integer =>
            return As_Integer (V) /= 0;

         when JSON_Float =>
            return As_Float (V) /= 0.0;

         when JSON_Number_String =>
            declare
               Text : constant String := As_String (V);
            begin
               return Text'Length /= 0 and then Text /= "0";
            end;

         when JSON_String =>
            return As_String (V)'Length /= 0;

         when JSON_Array | JSON_Object =>
            return Kind_Of (V) = JSON_Object or else Length (V) /= 0;
      end case;
   end Truthy;

   type Number (Found : Boolean := False) is record
      case Found is
         when True  => Item : Long_Float;
         when False => null;
      end case;
   end record;

   --  A string reads as a number only when every byte is an ASCII digit.
   function Digits_To_Number (S : String) return Number is
   begin
      if S'Length = 0 then
         return (Found => False);
      end if;
      for C of S loop
         if C not in '0' .. '9' then
            return (Found => False);
         end if;
      end loop;
      return (Found => True, Item => Long_Float'Value (S));
   exception
      when Constraint_Error =>
         return (Found => False);
   end Digits_To_Number;

   function Number_Of (V : Value) return Number is
   begin
      case Kind_Of (V) is
         when JSON_Integer =>
            return (Found => True, Item => Long_Float (As_Integer (V)));

         when JSON_Float =>
            return (Found => True, Item => As_Float (V));

         when JSON_String | JSON_Number_String =>
            return Digits_To_Number (As_String (V));

         when others =>
            return (Found => False);
      end case;
   end Number_Of;

   function Equals_Number (X : Long_Float; B : Value) return Boolean is
      N : constant Number := Number_Of (B);
   begin
      return N.Found and then X = N.Item;
   end Equals_Number;

   function Loosely_Equal (A, B : Value) return Boolean is
      KB : constant Kind := Kind_Of (B);
   begin
      case Kind_Of (A) is
         when JSON_Null =>
            return KB = JSON_Null;

         when JSON_Boolean =>
            return KB = JSON_Boolean and then As_Boolean (A) = As_Boolean (B);

         when JSON_Integer =>
            return Equals_Number (Long_Float (As_Integer (A)), B);

         when JSON_Float =>
            return Equals_Number (As_Float (A), B);

         when JSON_Number_String | JSON_String =>
            if KB = Kind_Of (A) then
               return As_String (A) = As_String (B);
            elsif KB in JSON_Integer | JSON_Float then
               declare
                  N : constant Number := Digits_To_Number (As_String (A));
               begin
                  return N.Found and then Equals_Number (N.Item, B);
               end;
            else
               return False;
            end if;

         when JSON_Array =>
            if KB /= JSON_Array or else Length (A) /= Length (B) then
               return False;
            end if;
            for I in 1 .. Length (A) loop
               if not Loosely_Equal (Element (A, I), Element (B, I)) then
                  return False;
               end if;
            end loop;
            return True;

         when JSON_Object =>
            if KB /= JSON_Object or else Length (A) /= Length (B) then
               return False;
            end if;
            for I in 1 .. Length (A) loop
               declare
                  Key : constant String := Member_Key (A, I);
               begin
                  if not Has_Member (B, Key)
                    or else not Loosely_Equal
                                  (Member_At (A, I), Member_Value (B, Key))
                  then
                     return False;
                  end if;
               end;
            end loop;
            return True;
      end case;
   end Loosely_Equal;

   type Comparison is (Less, Less_Or_Equal, Greater, Greater_Or_Equal);

   function Holds_For_Numbers
     (A, B : Long_Float; Op : Comparison) return Boolean
   is (case Op is
         when Less             => A < B,
         when Less_Or_Equal    => A <= B,
         when Greater          => A > B,
         when Greater_Or_Equal => A >= B);

   function Holds_For_Strings (A, B : String; Op : Comparison) return Boolean
   is (case Op is
         when Less             => A < B,
         when Less_Or_Equal    => A <= B,
         when Greater          => A > B,
         when Greater_Or_Equal => A >= B);

   ---------------------------------------------------------------------------
   --  Evaluation
   ---------------------------------------------------------------------------

   function Arguments_Of (Raw : Value) return Value_Array is
   begin
      if Kind_Of (Raw) = JSON_Array then
         declare
            Result : Value_Array (1 .. Length (Raw));
         begin
            for I in Result'Range loop
               Result (I) := Element (Raw, I);
            end loop;
            return Result;
         end;
      end if;
      return [Raw];
   end Arguments_Of;

   function Current_Or_Data (Where : Scope) return Value
   is (if Where.Has_Item then Where.Item else Where.Data);

   --  A path through nested objects, one dotted segment at a time.
   function Eval_Var (Args : Value_Array; Where : Scope) return Value is
   begin
      if Args'Length = 0 or else Kind_Of (Args (Args'First)) /= JSON_String
      then
         return Current_Or_Data (Where);
      end if;

      declare
         Path    : constant String := As_String (Args (Args'First));
         Default : constant Value :=
           (if Args'Length >= 2 then Args (Args'First + 1) else Null_Value);
         Current : Value := Where.Data;
         First   : Positive := Path'First;
      begin
         if Path'Length = 0 then
            return Current_Or_Data (Where);
         end if;
         loop
            declare
               Stop : Natural := First;
            begin
               while Stop <= Path'Last and then Path (Stop) /= '.' loop
                  Stop := Stop + 1;
               end loop;
               declare
                  Segment : constant String := Path (First .. Stop - 1);
               begin
                  if Kind_Of (Current) /= JSON_Object
                    or else not Has_Member (Current, Segment)
                  then
                     return Default;
                  end if;
                  Current := Member_Value (Current, Segment);
               end;
               exit when Stop > Path'Last;
               First := Stop + 1;
            end;
         end loop;
         return Current;
      end;
   end Eval_Var;

   function Evaluate
     (Rule  : Value;
      Where : Scope;
      Ops   : Operator_Set'Class := No_Operators) return Value
   is

      function Eval (V : Value) return Value
      is (Evaluate (V, Where, Ops));

      procedure Require (Args : Value_Array; Count : Positive; Op : String) is
      begin
         if Args'Length < Count then
            raise Invalid_Arguments with Op;
         end if;
      end Require;

      function Eval_And (Args : Value_Array) return Value is
         Last : Value := Make_Boolean (True);
      begin
         for A of Args loop
            Last := Eval (A);
            if not Truthy (Last) then
               return Last;
            end if;
         end loop;
         return Last;
      end Eval_And;

      function Eval_Or (Args : Value_Array) return Value is
         Last : Value := Make_Boolean (False);
      begin
         for A of Args loop
            Last := Eval (A);
            if Truthy (Last) then
               return Last;
            end if;
         end loop;
         return Last;
      end Eval_Or;

      function Eval_Xor (Args : Value_Array) return Value is
         Count : Natural := 0;
      begin
         for A of Args loop
            if Truthy (Eval (A)) then
               Count := Count + 1;
            end if;
         end loop;
         return Make_Boolean (Count = 1);
      end Eval_Xor;

      function Eval_Compare
        (Args : Value_Array; Op : Comparison; Name : String) return Value
      is
      begin
         Require (Args, 2, Name);
         declare
            A : constant Value := Eval (Args (Args'First));
            B : constant Value := Eval (Args (Args'First + 1));
         begin
            --  Two strings compare as text even when both are digits.
            if Kind_Of (A) = JSON_String and then Kind_Of (B) = JSON_String
            then
               return
                 Make_Boolean
                   (Holds_For_Strings (As_String (A), As_String (B), Op));
            end if;
            declare
               NA : constant Number := Number_Of (A);
               NB : constant Number := Number_Of (B);
            begin
               return
                 Make_Boolean
                   (NA.Found
                    and then NB.Found
                    and then Holds_For_Numbers (NA.Item, NB.Item, Op));
            end;
         end;
      end Eval_Compare;

      function Eval_In (Args : Value_Array) return Value is
      begin
         Require (Args, 2, "in");
         declare
            Needle   : constant Value := Eval (Args (Args'First));
            Haystack : constant Value := Eval (Args (Args'First + 1));
         begin
            case Kind_Of (Haystack) is
               when JSON_Array =>
                  for I in 1 .. Length (Haystack) loop
                     if Loosely_Equal (Needle, Element (Haystack, I)) then
                        return Make_Boolean (True);
                     end if;
                  end loop;
                  return Make_Boolean (False);

               when JSON_String =>
                  if Kind_Of (Needle) /= JSON_String then
                     return Make_Boolean (False);
                  end if;
                  declare
                     Text : constant String := As_String (Haystack);
                     Sub  : constant String := As_String (Needle);
                  begin
                     if Sub'Length = 0 then
                        return Make_Boolean (True);
                     end if;
                     for I in Text'First .. Text'Last - Sub'Length + 1 loop
                        if Text (I .. I + Sub'Length - 1) = Sub then
                           return Make_Boolean (True);
                        end if;
                     end loop;
                     return Make_Boolean (False);
                  end;

               when others =>
                  return Make_Boolean (False);
            end case;
         end;
      end Eval_In;

      --  glob, regexp and starts_with: two string operands or false.
      type String_Operator is (Glob_Op, Regexp_Op, Starts_With_Op);

      function Eval_Strings
        (Args : Value_Array; Op : String_Operator; Name : String) return Value
      is
      begin
         Require (Args, 2, Name);
         declare
            First  : constant Value := Eval (Args (Args'First));
            Second : constant Value := Eval (Args (Args'First + 1));
         begin
            if Kind_Of (First) /= JSON_String
              or else Kind_Of (Second) /= JSON_String
            then
               return Make_Boolean (False);
            end if;
            declare
               A : constant String := As_String (First);
               B : constant String := As_String (Second);
            begin
               case Op is
                  when Glob_Op =>
                     --  glob: [pattern, text]
                     return Make_Boolean (Glob.Glob_Match (A, B));

                  when Regexp_Op =>
                     --  regexp: [pattern, text]
                     case Regex_Lite.Search (A, B) is
                        when Regex_Lite.Matched =>
                           return Make_Boolean (True);

                        when Regex_Lite.Not_Matched =>
                           return Make_Boolean (False);

                        when Regex_Lite.Too_Complex =>
                           raise Pattern_Too_Complex with A;
                     end case;

                  when Starts_With_Op =>
                     --  starts_with: [text, prefix]
                     return
                       Make_Boolean
                         (A'Length >= B'Length
                          and then A (A'First .. A'First + B'Length - 1) = B);
               end case;
            end;
         end;
      end Eval_Strings;

      function Eval_All (Args : Value_Array) return Value is
      begin
         Require (Args, 2, "all");
         declare
            Items : constant Value := Eval (Args (Args'First));
         begin
            if Kind_Of (Items) /= JSON_Array then
               return Make_Boolean (False);
            end if;
            for I in 1 .. Length (Items) loop
               declare
                  Inner : constant Scope :=
                    (Data     => Where.Data,
                     Item     => Element (Items, I),
                     Has_Item => True);
               begin
                  if not Truthy
                           (Evaluate (Args (Args'First + 1), Inner, Ops))
                  then
                     return Make_Boolean (False);
                  end if;
               end;
            end loop;
            return Make_Boolean (True);
         end;
      end Eval_All;

   begin
      if Kind_Of (Rule) /= JSON_Object or else Length (Rule) /= 1 then
         return Rule;
      end if;

      declare
         Op   : constant String := Member_Key (Rule, 1);
         Args : constant Value_Array := Arguments_Of (Member_At (Rule, 1));
      begin
         if Op = "var" then
            return Eval_Var (Args, Where);
         elsif Op = "and" then
            return Eval_And (Args);
         elsif Op = "or" then
            return Eval_Or (Args);
         elsif Op = "!" then
            if Args'Length = 0 then
               return Make_Boolean (True);
            end if;
            return Make_Boolean (not Truthy (Eval (Args (Args'First))));
         elsif Op = "==" or else Op = "!=" then
            Require (Args, 2, Op);
            declare
               Same : constant Boolean :=
                 Loosely_Equal
                   (Eval (Args (Args'First)), Eval (Args (Args'First + 1)));
            begin
               return Make_Boolean (if Op = "==" then Same else not Same);
            end;
         elsif Op = "in" then
            return Eval_In (Args);
         elsif Op = "<" then
            return Eval_Compare (Args, Less, Op);
         elsif Op = "<=" then
            return Eval_Compare (Args, Less_Or_Equal, Op);
         elsif Op = ">" then
            return Eval_Compare (Args, Greater, Op);
         elsif Op = ">=" then
            return Eval_Compare (Args, Greater_Or_Equal, Op);
         elsif Op = "glob" then
            return Eval_Strings (Args, Glob_Op, Op);
         elsif Op = "regexp" then
            return Eval_Strings (Args, Regexp_Op, Op);
         elsif Op = "all" then
            return Eval_All (Args);
         elsif Op = "xor" then
            return Eval_Xor (Args);
         elsif Op = "starts_with" then
            return Eval_Strings (Args, Starts_With_Op, Op);
         elsif Ops.Has_Operator (Op) then
            return Ops.Apply (Op, Args, Where);
         end if;
         raise Unknown_Operator with Op;
      end;
   end Evaluate;

end Synapse.Core.JSON_Logic;
