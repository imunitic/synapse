with Synapse.Core.JSON;

package body Synapse.Core.Kind_Synonyms is

   package J renames Synapse.Core.JSON;

   use type J.Kind;

   function String_Member
     (Object : J.Value; Key : String; Found : out Boolean) return String
   is
   begin
      Found := False;
      if not J.Has_Member (Object, Key) then
         return "";
      end if;
      declare
         Item : constant J.Value := J.Member_Value (Object, Key);
      begin
         if J.Kind_Of (Item) /= J.JSON_String then
            return "";
         end if;
         Found := True;
         return J.As_String (Item);
      end;
   end String_Member;

   function Parse (Text : String) return Rule_List is
      Parsed : constant J.Parse_Result := J.Parse (Text);
      Result : Rule_List;
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
            if J.Kind_Of (Item) = J.JSON_Object then
               declare
                  Has_Match, Has_Kind, Has_Scope : Boolean;
                  Match                          : constant String :=
                    String_Member (Item, "match", Has_Match);
                  Kind                           : constant String :=
                    String_Member (Item, "kind", Has_Kind);
                  Scope                          : constant String :=
                    String_Member (Item, "scope", Has_Scope);
               begin
                  if Has_Match and then Has_Kind and then Kind'Length > 0 then
                     Result.Rules.Append
                       (Rule'
                          (Match     => To_Unbounded_String (Match),
                           Has_Scope => Has_Scope and then Scope'Length > 0,
                           Scope     => To_Unbounded_String (Scope),
                           Kind      => To_Unbounded_String (Kind)));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Parse;

   function Kind_For
     (List : Rule_List; Spelling, Grammar_Scope : String) return Maybe_Kind
   is
   begin
      for R of List.Rules loop
         if To_String (R.Match) = Spelling
           and then
           (not R.Has_Scope or else To_String (R.Scope) = Grammar_Scope)
         then
            return (Found => True, Kind => R.Kind);
         end if;
      end loop;
      return (Found => False);
   end Kind_For;

end Synapse.Core.Kind_Synonyms;
