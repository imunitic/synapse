with Synapse.Core.Prose;

package body Synapse.Core.Note_Operators is

   use JSON;

   overriding
   function Has_Operator (Set : Note_Operators; Name : String) return Boolean
   is (Name in "on_create" | "no_hard_wrap" | "hard_wrap"
             | "no_stray_frontmatter");

   function Is_Create (Data : Value) return Boolean
   is (Kind_Of (Data) = JSON_Object
       and then Has_Member (Data, "is_create")
       and then JSON_Logic.Truthy (Member_Value (Data, "is_create")));

   overriding
   function Apply
     (Set   : Note_Operators;
      Name  : String;
      Args  : JSON.Value_Array;
      Where : JSON_Logic.Scope) return JSON.Value
   is
      function Eval (Index : Positive) return Value
      is (JSON_Logic.Evaluate (Args (Args'First + Index - 1), Where, Set));

      procedure Require (Count : Positive) is
      begin
         if Args'Length < Count then
            raise JSON_Logic.Invalid_Arguments with Name;
         end if;
      end Require;
   begin
      if Name = "on_create" then
         Require (1);
         return (if Is_Create (Where.Data) then Eval (1)
                 else Make_Boolean (True));
      elsif Name = "no_hard_wrap" then
         Require (1);
         declare
            Text : constant Value := Eval (1);
         begin
            return
              Make_Boolean
                (Kind_Of (Text) /= JSON_String
                 or else Prose.No_Hard_Wrap (As_String (Text)));
         end;
      elsif Name = "no_stray_frontmatter" then
         Require (1);
         declare
            Text : constant Value := Eval (1);
         begin
            return
              Make_Boolean
                (Kind_Of (Text) /= JSON_String
                 or else Prose.No_Stray_Frontmatter (As_String (Text)));
         end;
      elsif Name = "hard_wrap" then
         Require (2);
         declare
            Text  : constant Value := Eval (1);
            Width : constant Value := Eval (2);
         begin
            if Kind_Of (Text) /= JSON_String then
               return Make_Boolean (True);
            end if;
            if Kind_Of (Width) /= JSON_Integer
              or else As_Integer (Width) < 1
              or else As_Integer (Width) > Long_Long_Integer (Positive'Last)
            then
               raise JSON_Logic.Invalid_Arguments with Name;
            end if;
            return
              Make_Boolean
                (Prose.Hard_Wrap
                   (As_String (Text), Positive (As_Integer (Width))));
         end;
      end if;
      raise JSON_Logic.Unknown_Operator with Name;
   end Apply;

end Synapse.Core.Note_Operators;
