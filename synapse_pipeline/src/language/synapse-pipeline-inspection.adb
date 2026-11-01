with Ada.Exceptions;

with Synapse.Core.JSON_Logic;

package body Synapse.Pipeline.Inspection is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   package Logic renames Synapse.Core.JSON_Logic;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Event_JSON (Item : Event) return JSON.Value is
     (JSON.Make_Object
        ([Member
            ("sequence",
             JSON.Make_Integer (Long_Long_Integer (Item.Sequence))),
         Member ("kind", JSON.Make_String (To_String (Item.Kind))),
         Member ("step", JSON.Make_String (To_String (Item.Step))),
         Member ("detail", Item.Detail)]));

   --  The events after the one numbered After, as a list.
   function Events_JSON (Seen : Snapshot; After : Natural) return JSON.Value is
      Kept : Event_Vectors.Vector;
   begin
      for E of Seen.Events loop
         if E.Sequence > After then
            Kept.Append (E);
         end if;
      end loop;
      declare
         Items : JSON.Value_Array (1 .. Natural (Kept.Length));
      begin
         for I in Items'Range loop
            Items (I) := Event_JSON (Kept (I));
         end loop;
         return JSON.Make_Array (Items);
      end;
   end Events_JSON;

   function Info (Seen : Snapshot) return JSON.Value is
      Document : constant JSON.Value := States.To_JSON (Seen.Run);
   begin
      return JSON.Make_Object
        ([Member
            ("execution_id", JSON.Make_String (To_String (Seen.Execution_Id))),
         Member ("pipeline", JSON.Member_Value (Document, "pipeline")),
         Member ("status", JSON.Member_Value (Document, "status")),
         Member
           ("current_step", JSON.Member_Value (Document, "current_step")),
         Member ("steps_run", JSON.Member_Value (Document, "steps_run")),
         Member ("failure", JSON.Member_Value (Document, "failure"))]);
   end Info;

   --  What a query is evaluated over.
   function Projection (Seen : Snapshot) return JSON.Value is
      Brief  : constant JSON.Value := Info (Seen);
      Fields : JSON.Member_Array (1 .. JSON.Length (Brief) + 3);
      Last   : Natural := 0;
   begin
      --  `pipeline` in a query is the description; the name is its `name`.
      for I in 1 .. JSON.Length (Brief) loop
         if JSON.Member_Key (Brief, I) /= "pipeline" then
            Last := Last + 1;
            Fields (Last) :=
              Member (JSON.Member_Key (Brief, I), JSON.Member_At (Brief, I));
         end if;
      end loop;
      Fields (Last + 1) := Member ("pipeline", Seen.Description);
      Last := Last + 1;
      Fields (Last + 1) := Member ("state", States.To_JSON (Seen.Run));
      Fields (Last + 2) := Member ("events", Events_JSON (Seen, 0));
      return JSON.Make_Object (Fields (1 .. Last + 2));
   end Projection;

   function Refusal (Why : String) return String is
     (JSON.To_String
        (JSON.Make_Object
           ([Member ("ok", JSON.Make_Boolean (False)),
             Member ("error", JSON.Make_String (Why))])));

   function Answer (Result : JSON.Value) return String is
      Text : constant String :=
        JSON.To_String
          (JSON.Make_Object
             ([Member ("ok", JSON.Make_Boolean (True)),
               Member ("result", Result)]));
   begin
      if Text'Length > Max_Response_Bytes then
         return Refusal
           ("the answer is larger than" & Natural'Image (Max_Response_Bytes)
            & " bytes");
      end if;
      return Text;
   end Answer;

   function Respond (Seen : Snapshot; Request : String) return String is
   begin
      if Request'Length > Max_Request_Bytes then
         return Refusal
           ("the request is larger than" & Natural'Image (Max_Request_Bytes)
            & " bytes");
      end if;
      declare
         Parsed : constant JSON.Parse_Result := JSON.Parse (Request);
      begin
         if not Parsed.Ok then
            return Refusal ("the request is not JSON");
         elsif JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object then
            return Refusal ("the request is not an object");
         elsif not JSON.Has_Member (Parsed.Item, "command")
           or else JSON.Kind_Of (JSON.Member_Value (Parsed.Item, "command")) /=
                   JSON.JSON_String
         then
            return Refusal ("the request has no command");
         end if;
         declare
            Command : constant String :=
              JSON.As_String (JSON.Member_Value (Parsed.Item, "command"));
         begin
            if Command = "info" then
               return Answer (Info (Seen));
            elsif Command = "state" then
               return Answer (States.To_JSON (Seen.Run));
            elsif Command = "pipeline" then
               return Answer (Seen.Description);
            elsif Command = "events" then
               declare
                  After : Natural := 0;
               begin
                  if JSON.Has_Member (Parsed.Item, "after") then
                     declare
                        Given : constant JSON.Value :=
                          JSON.Member_Value (Parsed.Item, "after");
                     begin
                        if JSON.Kind_Of (Given) /= JSON.JSON_Integer
                          or else JSON.As_Integer (Given) not in 0 .. 2**30
                        then
                           return Refusal
                             ("'after' is a whole number, 0 or more");
                        end if;
                        After := Natural (JSON.As_Integer (Given));
                     end;
                  end if;
                  return Answer (Events_JSON (Seen, After));
               end;
            elsif Command = "query" then
               if not JSON.Has_Member (Parsed.Item, "expression") then
                  return Refusal ("a query has an 'expression'");
               end if;
               return Answer
                 (Logic.Evaluate
                    (JSON.Member_Value (Parsed.Item, "expression"),
                     (Data => Projection (Seen), others => <>)));
            end if;
            return Refusal
              ("'" & Command & "' is not a command; the commands are info, "
               & "state, pipeline, events and query");
         end;
      end;
   exception
      when E : Logic.Unknown_Operator =>
         return Refusal
           ("the expression names an operator that does not exist: "
            & Ada.Exceptions.Exception_Message (E));
      when Logic.Invalid_Arguments =>
         return Refusal ("the expression gives an operator too few arguments");
      when E : Logic.Pattern_Too_Complex =>
         return Refusal
           ("the expression has a pattern that is too complex: "
            & Ada.Exceptions.Exception_Message (E));
      when others =>
         return Refusal ("the request could not be answered");
   end Respond;

end Synapse.Pipeline.Inspection;
