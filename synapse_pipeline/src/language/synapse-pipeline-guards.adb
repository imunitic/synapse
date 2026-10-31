with Ada.Exceptions;

with Synapse.Core.JSON_Logic;

package body Synapse.Pipeline.Guards is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   package Logic renames Synapse.Core.JSON_Logic;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function View
     (Outcome, Summary : String; Data : JSON.Value) return JSON.Value is
     (JSON.Make_Object
        ([Member ("outcome", JSON.Make_String (Outcome)),
          Member ("summary", JSON.Make_String (Summary)),
          Member ("data", Data)]));

   --  The member of Result called Key, or null when it has none.
   function Seen (Result : JSON.Value; Key : String) return JSON.Value is
     (if JSON.Kind_Of (Result) = JSON.JSON_Object
        and then JSON.Has_Member (Result, Key)
      then JSON.Member_Value (Result, Key) else JSON.Null_Value);

   --  The name of the first operator in Item that the evaluator does not
   --  have. A one-key object is a rule; any other object is a literal, whose
   --  members are looked into all the same.
   function Unknown_Operator (Item : JSON.Value)
      return Synapse.Core.Optional_Text.Option
   is
      None : constant Synapse.Core.Optional_Text.Option :=
        Synapse.Core.Optional_Text.None;
   begin
      case JSON.Kind_Of (Item) is
         when JSON.JSON_Array =>
            for I in 1 .. JSON.Length (Item) loop
               declare
                  Found : constant Synapse.Core.Optional_Text.Option :=
                    Unknown_Operator (JSON.Element (Item, I));
               begin
                  if Found.Found then
                     return Found;
                  end if;
               end;
            end loop;

         when JSON.JSON_Object =>
            if JSON.Length (Item) = 1
              and then not Logic.Is_Built_In (JSON.Member_Key (Item, 1))
            then
               return Synapse.Core.Optional_Text.Of_Value
                 (To_Unbounded_String (JSON.Member_Key (Item, 1)));
            end if;
            for I in 1 .. JSON.Length (Item) loop
               declare
                  Found : constant Synapse.Core.Optional_Text.Option :=
                    Unknown_Operator (JSON.Member_At (Item, I));
               begin
                  if Found.Found then
                     return Found;
                  end if;
               end;
            end loop;

         when others =>
            null;
      end case;
      return None;
   end Unknown_Operator;

   function Problem (Guard : JSON.Value)
      return Synapse.Core.Optional_Text.Option
   is
   begin
      if JSON.Kind_Of (Guard) /= JSON.JSON_Object
        or else JSON.Length (Guard) /= 1
      then
         return Synapse.Core.Optional_Text.Of_Value
           (To_Unbounded_String
              ("a guard is a single JsonLogic rule, an object with one key "
               & "such as {""=="": [...]}"));
      end if;
      declare
         Unknown : constant Synapse.Core.Optional_Text.Option :=
           Unknown_Operator (Guard);
      begin
         if Unknown.Found then
            return Synapse.Core.Optional_Text.Of_Value
              (To_Unbounded_String
                 ("'" & To_String (Unknown.Value)
                  & "' is not a JsonLogic operator"));
         end if;
      end;
      return Synapse.Core.Optional_Text.None;
   end Problem;

   function Holds
     (Guard : JSON.Value; Result : JSON.Value) return Guard_Results.Result
   is
      Seen_Result : constant JSON.Value :=
        View
          (Outcome =>
             (if JSON.Kind_Of (Seen (Result, "outcome")) = JSON.JSON_String
              then JSON.As_String (Seen (Result, "outcome")) else ""),
           Summary =>
             (if JSON.Kind_Of (Seen (Result, "summary")) = JSON.JSON_String
              then JSON.As_String (Seen (Result, "summary")) else ""),
           Data    => Seen (Result, "data"));
   begin
      declare
         Answer : constant JSON.Value :=
           Logic.Evaluate (Guard, (Data => Seen_Result, others => <>));
      begin
         if JSON.Kind_Of (Answer) /= JSON.JSON_Boolean then
            return Guard_Results.Failure
              (To_Unbounded_String
                 ("the guard did not come to true or false but to "
                  & JSON.To_String (Answer)));
         end if;
         return Guard_Results.Success (JSON.As_Boolean (Answer));
      end;
   exception
      when E : Logic.Unknown_Operator =>
         return Guard_Results.Failure
           (To_Unbounded_String
              ("the guard names an operator that does not exist: "
               & Ada.Exceptions.Exception_Message (E)));
      when Logic.Invalid_Arguments =>
         return Guard_Results.Failure
           (To_Unbounded_String
              ("the guard gives an operator too few arguments"));
      when E : Logic.Pattern_Too_Complex =>
         return Guard_Results.Failure
           (To_Unbounded_String
              ("the guard has a pattern that is too complex: "
               & Ada.Exceptions.Exception_Message (E)));
   end Holds;

   function Route_After
     (Edges  : Resolved.Edge_Vectors.Vector;
      Fired  : Count_Vectors.Vector;
      Step   : String;
      Result : JSON.Value) return Route_Results.Result
   is
   begin
      for I in Edges.First_Index .. Edges.Last_Index loop
         declare
            E     : constant Resolved.Edge := Edges (I);
            Count : constant Natural :=
              (if I <= Fired.Last_Index then Fired (I) else 0);
         begin
            if To_String (E.From) = Step
              and then not (E.Max_Iterations > 0
                            and then Count >= E.Max_Iterations)
            then
               if not E.Has_Guard then
                  return Route_Results.Success ((Fires => True, Edge => I));
               end if;
               declare
                  Held : constant Guard_Results.Result :=
                    Holds (E.Guard, Result);
               begin
                  if not Guard_Results.Is_Success (Held) then
                     return Route_Results.Failure
                       (To_Unbounded_String
                          ("edge " & To_String (E.From) & " -> "
                           & To_String (E.To) & ": "
                           & To_String (Guard_Results.Error (Held))));
                  elsif Guard_Results.Value (Held) then
                     return Route_Results.Success
                       ((Fires => True, Edge => I));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Route_Results.Success ((Fires => False));
   end Route_After;

end Synapse.Pipeline.Guards;
