with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.List is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.List_Help);

   type Row is record
      Id, Pipeline, Status, Step : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   function Text_Of (Item : JSON.Value; Key : String) return String is
     (if JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Padded (Text : String; Width : Natural) return String is
     (Text & [1 .. Width - Text'Length => ' ']);

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Work  : Unbounded_String;
      Found : Boolean;
      Rows  : Row_Vectors.Vector;
   begin
      if not Args.Is_Empty then
         return Usage_Error (Env, Usage);
      end if;
      Clients.Work_Directory (Env, Work, Found);
      if not Found then
         return 1;
      end if;
      for Id of Env.Inspector.Ids (To_String (Work)) loop
         declare
            Answered : Boolean;
            Answer   : Unbounded_String;
            Ok       : Boolean;
            Result   : JSON.Value;
            Message  : Unbounded_String;
         begin
            Env.Inspector.Ask
              (Env.Inspector.Endpoint_For (To_String (Work), To_String (Id)),
               "{""command"":""info""}", Answered, Answer);
            if Answered then
               Clients.Read_Answer (To_String (Answer), Ok, Result, Message);
               if Ok and then JSON.Kind_Of (Result) = JSON.JSON_Object then
                  Rows.Append
                    (Row'
                       (Id       => Id,
                        Pipeline => To_Unbounded_String
                                      (Text_Of (Result, "pipeline")),
                        Status   => To_Unbounded_String
                                      (Text_Of (Result, "status")),
                        Step     => To_Unbounded_String
                                      (Text_Of (Result, "current_step"))));
               end if;
            end if;
         end;
      end loop;
      if Rows.Is_Empty then
         return 0;
      end if;
      declare
         Widths : array (1 .. 3) of Natural :=
           [1 => 9, 2 => 8, 3 => 6];
      begin
         for R of Rows loop
            Widths (1) := Natural'Max (Widths (1), Length (R.Id));
            Widths (2) := Natural'Max (Widths (2), Length (R.Pipeline));
            Widths (3) := Natural'Max (Widths (3), Length (R.Status));
         end loop;
         Say
           (Env,
            Padded ("EXECUTION", Widths (1)) & "  "
            & Padded ("PIPELINE", Widths (2)) & "  "
            & Padded ("STATUS", Widths (3)) & "  STEP" & LF);
         for R of Rows loop
            Say
              (Env,
               Padded (To_String (R.Id), Widths (1)) & "  "
               & Padded (To_String (R.Pipeline), Widths (2)) & "  "
               & Padded (To_String (R.Status), Widths (3)) & "  "
               & To_String (R.Step) & LF);
         end loop;
      end;
      return 0;
   end Run;

end Synapse.Pipeline.Commands.List;
