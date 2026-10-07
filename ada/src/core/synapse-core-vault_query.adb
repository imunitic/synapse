with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Model;

package body Synapse.Core.Vault_Query is

   use type JSON.Kind;

   --  Evaluates Rule against Data; the three ways an evaluation can fail are
   --  one answer: it could not be done.
   procedure Evaluate_Against
     (Rule :     JSON.Value; Data : JSON.Value; Result : out JSON.Value;
      Done : out Boolean)
   is
   begin
      Result := JSON_Logic.Evaluate (Rule, (Data => Data, others => <>));
      Done   := True;
   exception
      when JSON_Logic.Unknown_Operator | JSON_Logic.Invalid_Arguments
        | JSON_Logic.Pattern_Too_Complex =>
         Result := JSON.Null_Value;
         Done   := False;
   end Evaluate_Against;

   function Path_Object (Name : String) return JSON.Value is
     (JSON.Make_Object
        ([
         1 =>
           (Key  => To_Unbounded_String ("path"),
            Item => JSON.Make_String (Name))]));

   function Path_Matches (Filter : JSON.Value; Name : String) return Boolean is
      Matched : JSON.Value;
      Done    : Boolean;
   begin
      Evaluate_Against (Filter, Path_Object (Name), Matched, Done);
      return Done and then JSON_Logic.Truthy (Matched);
   end Path_Matches;

   --  Whether evaluating Rule never looks at anything but `path`, so it gives
   --  the same answer against `{path}` as against the whole tree. Looks for a
   --  `{"var": X}` anywhere in the rule, and X must be exactly the string
   --  `path`: the array form with a default, or a non-string argument, count
   --  as not path only, since no query written here needs either.
   function References_Only_Path (Rule : JSON.Value) return Boolean is
   begin
      case JSON.Kind_Of (Rule) is
         when JSON.JSON_Object =>
            if JSON.Length (Rule) = 1
              and then JSON.Member_Key (Rule, 1) = "var"
            then
               declare
                  Argument : constant JSON.Value := JSON.Member_At (Rule, 1);
               begin
                  return
                    JSON.Kind_Of (Argument) = JSON.JSON_String
                    and then JSON.As_String (Argument) = "path";
               end;
            end if;
            for I in 1 .. JSON.Length (Rule) loop
               if not References_Only_Path (JSON.Member_At (Rule, I)) then
                  return False;
               end if;
            end loop;
            return True;

         when JSON.JSON_Array =>
            for I in 1 .. JSON.Length (Rule) loop
               if not References_Only_Path (JSON.Element (Rule, I)) then
                  return False;
               end if;
            end loop;
            return True;

         when others =>
            return True;
      end case;
   end References_Only_Path;

   --  The clauses of Filter that only ever mention `path`. For a top-level
   --  `and`, its children that qualify: `and` stops at the first falsy child,
   --  which is what makes a failing path-only child proof the row cannot
   --  match (`or` is not symmetric, and nothing here writes that shape). For
   --  anything else the whole filter is one clause when it qualifies, so a
   --  bare `glob` is skipped as well as one wrapped in an `and`.
   function Path_Only_Clauses (Filter : JSON.Value) return Value_Vectors.Vector
   is
      Result : Value_Vectors.Vector;
   begin
      if JSON.Kind_Of (Filter) = JSON.JSON_Object
        and then JSON.Length (Filter) = 1
        and then JSON.Member_Key (Filter, 1) = "and"
      then
         declare
            Children : constant JSON.Value := JSON.Member_At (Filter, 1);
         begin
            if JSON.Kind_Of (Children) = JSON.JSON_Array then
               for I in 1 .. JSON.Length (Children) loop
                  if References_Only_Path (JSON.Element (Children, I)) then
                     Result.Append (JSON.Element (Children, I));
                  end if;
               end loop;
            elsif References_Only_Path (Children) then
               Result.Append (Children);
            end if;
            return Result;
         end;
      end if;
      if References_Only_Path (Filter) then
         Result.Append (Filter);
      end if;
      return Result;
   end Path_Only_Clauses;

   function Note_Data (Path, Text : String) return JSON.Value is
      Frontmatter : constant JSON.Value :=
        Note_Model.Frontmatter_As_JSON (Text);
      Tags        : constant JSON.Value :=
        (if JSON.Has_Member (Frontmatter, "tags") then
           JSON.Member_Value (Frontmatter, "tags")
         else JSON.Make_Array (JSON.Value_Array'(1 .. 0 => JSON.Null_Value)));
   begin
      return
        JSON.Make_Object
          ([
           (Key  => To_Unbounded_String ("path"),
            Item => JSON.Make_String (Path)),
           (Key  => To_Unbounded_String ("content"),
            Item => JSON.Make_String (Text)),
           (Key => To_Unbounded_String ("frontmatter"), Item => Frontmatter),
           (Key => To_Unbounded_String ("tags"), Item => Tags)]);
   end Note_Data;

   function Query
     (Source : in out Synapse.Ports.Store.Store'Class; Filter : JSON.Value;
      Fields :        Text_Lists.Vector) return Row_Vectors.Vector
   is
      Names     : constant Text_Lists.Vector    := Source.List;
      Path_Only : constant Value_Vectors.Vector := Path_Only_Clauses (Filter);
      Result    : Row_Vectors.Vector;
   begin
      for Name_Item of Names loop
         declare
            Name    : constant String := To_String (Name_Item);
            Skipped : Boolean         := False;
         begin
            --  A clause that fails on the name alone proves the row cannot
            --  match, before the note is read.
            for Clause of Path_Only loop
               declare
                  Matched : JSON.Value;
                  Done    : Boolean;
               begin
                  Evaluate_Against (Clause, Path_Object (Name), Matched, Done);
                  if not Done or else not JSON_Logic.Truthy (Matched) then
                     Skipped := True;
                     exit;
                  end if;
               end;
            end loop;

            if not Skipped then
               declare
                  Content : constant Synapse.Ports.Store.Maybe_Text :=
                    Source.Read (Name);
               begin
                  if Content.Found then
                     declare
                        Data    : constant JSON.Value :=
                          Note_Data (Name, To_String (Content.Text));
                        Matched : JSON.Value;
                        Done    : Boolean;
                     begin
                        Evaluate_Against (Filter, Data, Matched, Done);
                        if Done and then JSON_Logic.Truthy (Matched) then
                           declare
                              Row_Result : Row;
                           begin
                              Row_Result.Path := Name_Item;
                              for Field of Fields loop
                                 declare
                                    Rule  : constant JSON.Value :=
                                      JSON.Make_Object
                                        ([
                                         1 =>
                                           (Key => To_Unbounded_String ("var"),
                                            Item =>
                                              JSON.Make_String
                                                (To_String (Field)))]);
                                    Value : JSON.Value;
                                    Read  : Boolean;
                                 begin
                                    Evaluate_Against (Rule, Data, Value, Read);
                                    Row_Result.Values.Append
                                      (if Read then Value
                                       else JSON.Null_Value);
                                 end;
                              end loop;
                              Result.Append (Row_Result);
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Query;

end Synapse.Core.Vault_Query;
