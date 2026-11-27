with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Data_Shapes is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;
   use type JSON.Member;

   package Member_Lists is new Ada.Containers.Vectors (Positive, JSON.Member);

   function Is_Object (Item : JSON.Value) return Boolean is
     (JSON.Kind_Of (Item) = JSON.JSON_Object);

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function To_Object (List : Member_Lists.Vector) return JSON.Value is
      Members : JSON.Member_Array (1 .. Natural (List.Length));
   begin
      for I in Members'Range loop
         Members (I) := List (I);
      end loop;
      return JSON.Make_Object (Members);
   end To_Object;

   --  The field mapping Shapes declares, or null when it has none.
   function Fields_Of (Shapes : JSON.Value) return JSON.Value is
     (if Is_Object (Shapes) and then JSON.Has_Member (Shapes, "fields")
        and then Is_Object (JSON.Member_Value (Shapes, "fields"))
      then JSON.Member_Value (Shapes, "fields") else JSON.Null_Value);

   function Is_Named (Value : JSON.Value) return Boolean is
     (JSON.Kind_Of (Value) = JSON.JSON_Array);

   function Names_Of (Value : JSON.Value)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      if Is_Named (Value) then
         for I in 1 .. JSON.Length (Value) loop
            if JSON.Kind_Of (JSON.Element (Value, I)) = JSON.JSON_String then
               Result.Append
                 (To_Unbounded_String
                    (JSON.As_String (JSON.Element (Value, I))));
            end if;
         end loop;
      end if;
      return Result;
   end Names_Of;

   function Name_List_Problems (Value : JSON.Value; Root : String)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Seen   : Synapse.Core.Text_Lists.Set;
   begin
      if not Is_Named (Value) then
         return Result;
      elsif JSON.Length (Value) = 0 then
         Result.Append
           (To_Unbounded_String (Root & ": the list of names is empty"));
         return Result;
      end if;
      for I in 1 .. JSON.Length (Value) loop
         declare
            Item : constant JSON.Value := JSON.Element (Value, I);
         begin
            if JSON.Kind_Of (Item) /= JSON.JSON_String
              or else JSON.As_String (Item)'Length = 0
            then
               Result.Append
                 (To_Unbounded_String
                    (Root & ": item "
                     & Ada.Strings.Fixed.Trim (I'Image, Ada.Strings.Left)
                     & " is not a name"));
            elsif Seen.Contains (JSON.As_String (Item)) then
               Result.Append
                 (To_Unbounded_String
                    (Root & ": '" & JSON.As_String (Item)
                     & "' is named twice"));
            else
               Seen.Insert (JSON.As_String (Item));
            end if;
         end;
      end loop;
      return Result;
   end Name_List_Problems;

   function Declares (Shapes : JSON.Value; Name : String) return Boolean is
      Fields : constant JSON.Value := Fields_Of (Shapes);
   begin
      return Is_Object (Fields) and then JSON.Has_Member (Fields, Name);
   end Declares;

   function Named_Fields (Shapes, Names : JSON.Value) return JSON.Value is
      Fields : constant JSON.Value := Fields_Of (Shapes);
      Result : Member_Lists.Vector;
   begin
      for Name of Names_Of (Names) loop
         if Declares (Shapes, To_String (Name)) then
            Result.Append
              (Member (To_String (Name),
                       JSON.Member_Value (Fields, To_String (Name))));
         end if;
      end loop;
      return To_Object (Result);
   end Named_Fields;

   function Resolve_Data (Shapes, Data : JSON.Value) return JSON.Value is
     (if Is_Named (Data)
      then JSON.Make_Object
             ([1 => Member ("fields", Named_Fields (Shapes, Data))])
      else Data);

   function Resolve_Outcomes (Shapes, Outcomes : JSON.Value)
      return JSON.Value
   is
      Result : Member_Lists.Vector;
   begin
      if not Is_Object (Outcomes) then
         return Outcomes;
      end if;
      for I in 1 .. JSON.Length (Outcomes) loop
         declare
            Word    : constant String := JSON.Member_Key (Outcomes, I);
            Meaning : constant JSON.Value := JSON.Member_At (Outcomes, I);
            Kept    : Member_Lists.Vector;
         begin
            if Is_Object (Meaning)
              and then JSON.Has_Member (Meaning, "data")
              and then Is_Named (JSON.Member_Value (Meaning, "data"))
            then
               for K in 1 .. JSON.Length (Meaning) loop
                  if JSON.Member_Key (Meaning, K) = "data" then
                     Kept.Append
                       (Member ("data",
                                Named_Fields
                                  (Shapes, JSON.Member_At (Meaning, K))));
                  else
                     Kept.Append
                       (Member (JSON.Member_Key (Meaning, K),
                                JSON.Member_At (Meaning, K)));
                  end if;
               end loop;
               Result.Append (Member (Word, To_Object (Kept)));
            else
               Result.Append (Member (Word, Meaning));
            end if;
         end;
      end loop;
      return To_Object (Result);
   end Resolve_Outcomes;

   function Undeclared (Shapes, Value : JSON.Value)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      for Name of Names_Of (Value) loop
         if not Declares (Shapes, To_String (Name)) then
            Result.Append (Name);
         end if;
      end loop;
      return Result;
   end Undeclared;

end Synapse.Pipeline.Data_Shapes;
