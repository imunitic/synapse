with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.Info is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Info_Help);

   function Text_Of (Item : JSON.Value; Key : String) return String is
     (if JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   --  The run in brief for a person.
   function Describe (Brief : JSON.Value) return String is
      Result : Unbounded_String;
   begin
      Append (Result, "execution  " & Text_Of (Brief, "execution_id") & LF);
      Append (Result, "pipeline   " & Text_Of (Brief, "pipeline") & LF);
      Append (Result, "status     " & Text_Of (Brief, "status") & LF);
      Append (Result, "step       " & Text_Of (Brief, "current_step") & LF);
      if JSON.Has_Member (Brief, "steps_run")
        and then JSON.Kind_Of (JSON.Member_Value (Brief, "steps_run")) =
                 JSON.JSON_Integer
      then
         Append
           (Result,
            "steps run  "
            & JSON.To_String (JSON.Member_Value (Brief, "steps_run")) & LF);
      end if;
      if JSON.Has_Member (Brief, "failure")
        and then JSON.Kind_Of (JSON.Member_Value (Brief, "failure")) =
                 JSON.JSON_Object
      then
         declare
            Cause : constant JSON.Value :=
              JSON.Member_Value (Brief, "failure");
         begin
            Append
              (Result,
               "failure    step " & Text_Of (Cause, "step") & " failed: "
               & Text_Of (Cause, "kind") & ": " & Text_Of (Cause, "message")
               & (if Text_Of (Cause, "reset") /= ""
                  then " (resets at " & Text_Of (Cause, "reset") & ")"
                  else "") & LF);
         end;
      end if;
      return To_String (Result);
   end Describe;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Id        : Unbounded_String;
      Format    : Unbounded_String := To_Unbounded_String ("text");
      Query     : Unbounded_String;
      Has_Query : Boolean := False;
      Has_Format : Boolean := False;
      I         : Positive := Args.First_Index;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--format" or else Arg = "--query" then
               if I = Args.Last_Index
                 or else (Arg = "--format" and then Has_Format)
                 or else (Arg = "--query" and then Has_Query)
               then
                  return Usage_Error (Env, Usage);
               end if;
               I := I + 1;
               if Arg = "--format" then
                  Has_Format := True;
                  Format := Args (I);
               else
                  Has_Query := True;
                  Query := Args (I);
               end if;
            elsif Arg'Length >= 2
              and then Arg (Arg'First .. Arg'First + 1) = "--"
            then
               return Usage_Error (Env, Usage);
            elsif Length (Id) > 0 then
               return Usage_Error (Env, Usage);
            else
               Id := Args (I);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Id) = 0
        or else (To_String (Format) /= "text"
                 and then To_String (Format) /= "json")
      then
         return Usage_Error (Env, Usage);
      end if;

      declare
         Work     : Unbounded_String;
         Found    : Boolean;
         Request  : Unbounded_String :=
           To_Unbounded_String ("{""command"":""info""}");
      begin
         if Has_Query then
            declare
               Rule : constant JSON.Parse_Result :=
                 JSON.Parse (To_String (Query));
            begin
               if not Rule.Ok then
                  Complain (Env, "error: --query is not JSON" & LF);
                  return 1;
               end if;
               Request :=
                 To_Unbounded_String
                   (JSON.To_String
                      (JSON.Make_Object
                         ([Member ("command", JSON.Make_String ("query")),
                           Member ("expression", Rule.Item)])));
            end;
         end if;
         Clients.Work_Directory (Env, Work, Found);
         if not Found then
            return 1;
         end if;
         declare
            Answered : Boolean;
            Answer   : Unbounded_String;
            Ok       : Boolean;
            Result   : JSON.Value;
            Message  : Unbounded_String;
         begin
            Env.Inspector.Ask
              (Env.Inspector.Endpoint_For (To_String (Work), To_String (Id)),
               To_String (Request), Answered, Answer);
            if not Answered then
               Complain
                 (Env,
                  "error: no run named '" & To_String (Id)
                  & "' is listening (" & To_String (Answer) & ")" & LF);
               return 1;
            end if;
            Clients.Read_Answer (To_String (Answer), Ok, Result, Message);
            if not Ok then
               Complain (Env, "error: " & To_String (Message) & LF);
               return 1;
            end if;
            if To_String (Format) = "json" then
               Say (Env, JSON.To_String (Result) & LF);
            elsif Has_Query then
               Say
                 (Env,
                  (if JSON.Kind_Of (Result) = JSON.JSON_String
                   then JSON.As_String (Result) else JSON.To_String (Result))
                  & LF);
            else
               Say (Env, Describe (Result));
            end if;
            return 0;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Info;
