with Synapse.Core.JSON;

package body Synapse.Core.Fence_Languages is

   package J renames Synapse.Core.JSON;

   use type J.Kind;

   function Parse (Text : String) return Registry is
      Parsed : constant J.Parse_Result := J.Parse (Text);
      Result : Registry;
   begin
      if not Parsed.Ok then
         raise Malformed;
      end if;
      if J.Kind_Of (Parsed.Item) /= J.JSON_Object then
         return Result;
      end if;
      for I in 1 .. J.Length (Parsed.Item) loop
         declare
            Item : constant J.Value := J.Member_At (Parsed.Item, I);
         begin
            if J.Kind_Of (Item) = J.JSON_String then
               Result.Entries.Append
                 (Entry_Type'
                    (Extension =>
                       To_Unbounded_String (J.Member_Key (Parsed.Item, I)),
                     Language  => To_Unbounded_String (J.As_String (Item))));
            end if;
         end;
      end loop;
      return Result;
   end Parse;

   function Language_For (R : Registry; Path : String) return String is
   begin
      for E of R.Entries loop
         declare
            Extension : constant String := To_String (E.Extension);
         begin
            if Path'Length >= Extension'Length
              and then Path (Path'Last - Extension'Length + 1 .. Path'Last) =
                Extension
            then
               return To_String (E.Language);
            end if;
         end;
      end loop;
      return "";
   end Language_For;

end Synapse.Core.Fence_Languages;
