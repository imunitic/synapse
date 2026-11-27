with Ada.Strings.Unbounded;

with Synapse.Core.Object_Schema;

package body Synapse.Pipeline.Inputs is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   function Member_Or_Null (V : JSON.Value; Key : String) return JSON.Value is
     (if JSON.Kind_Of (V) = JSON.JSON_Object and then JSON.Has_Member (V, Key)
      then JSON.Member_Value (V, Key)
      else JSON.Null_Value);

   function Is_Required (Rule : JSON.Value) return Boolean is
     (JSON.Kind_Of (Member_Or_Null (Rule, "required")) = JSON.JSON_Boolean
      and then JSON.As_Boolean (Member_Or_Null (Rule, "required")));

   function Is_Empty (V : JSON.Value) return Boolean is
     ((JSON.Kind_Of (V) = JSON.JSON_String and then JSON.As_String (V) = "")
      or else (JSON.Kind_Of (V) = JSON.JSON_Array
               and then JSON.Length (V) = 0));

   function Single_Text_Field
     (Declared : JSON.Value) return Synapse.Core.Optional_Text.Option
   is
      Fields : constant JSON.Value := Member_Or_Null (Declared, "fields");
      Found  : Synapse.Core.Optional_Text.Option;
   begin
      if JSON.Kind_Of (Fields) /= JSON.JSON_Object then
         return Synapse.Core.Optional_Text.None;
      end if;
      for I in 1 .. JSON.Length (Fields) loop
         declare
            Rule : constant JSON.Value := JSON.Member_At (Fields, I);
            Kind : constant JSON.Value := Member_Or_Null (Rule, "type");
         begin
            if Is_Required (Rule) then
               if Found.Found
                 or else JSON.Kind_Of (Kind) /= JSON.JSON_String
                 or else JSON.As_String (Kind) /= "string"
               then
                  return Synapse.Core.Optional_Text.None;
               end if;
               Found :=
                 Synapse.Core.Optional_Text.Of_Value
                   (To_Unbounded_String (JSON.Member_Key (Fields, I)));
            end if;
         end;
      end loop;
      return Found;
   end Single_Text_Field;

   --  Given as the object to check: a plain string in the one text field,
   --  and nothing at all as no fields.
   function Object_Of (Declared, Given : JSON.Value) return JSON.Value is
      Text_Field : constant Synapse.Core.Optional_Text.Option :=
        Single_Text_Field (Declared);
   begin
      if JSON.Kind_Of (Given) = JSON.JSON_Null then
         return JSON.Make_Object ([]);
      elsif JSON.Kind_Of (Given) = JSON.JSON_String and then Text_Field.Found
      then
         return JSON.Make_Object
           ([(Key => Text_Field.Value, Item => Given)]);
      else
         return Given;
      end if;
   end Object_Of;

   --  Object without the optional fields Declared names that are given
   --  empty.
   function Without_Empty_Optionals
     (Declared, Object : JSON.Value) return JSON.Value
   is
      Fields : constant JSON.Value := Member_Or_Null (Declared, "fields");
      Kept   : JSON.Member_Array (1 .. JSON.Length (Object));
      Count  : Natural := 0;
   begin
      for I in 1 .. JSON.Length (Object) loop
         declare
            Name : constant String     := JSON.Member_Key (Object, I);
            Item : constant JSON.Value := JSON.Member_At (Object, I);
         begin
            if not (Is_Empty (Item)
                    and then not Is_Required (Member_Or_Null (Fields, Name)))
            then
               Count := Count + 1;
               Kept (Count) :=
                 (Key => To_Unbounded_String (Name), Item => Item);
            end if;
         end;
      end loop;
      return JSON.Make_Object (Kept (1 .. Count));
   end Without_Empty_Optionals;

   function Accept_Input (Declared, Given : JSON.Value) return Acceptance is
   begin
      if JSON.Kind_Of (Declared) = JSON.JSON_Null then
         return (Accepted => True, Input => Given);
      end if;

      declare
         Object   : constant JSON.Value := Object_Of (Declared, Given);
         Problems : constant Synapse.Core.Text_Lists.Vector :=
           Synapse.Core.Object_Schema.Validate_Object (Declared, Object);
      begin
         if not Problems.Is_Empty then
            return (Accepted => False, Problems => Problems);
         end if;
         return
           (Accepted => True,
            Input    => Without_Empty_Optionals (Declared, Object));
      end;
   end Accept_Input;

end Synapse.Pipeline.Inputs;
