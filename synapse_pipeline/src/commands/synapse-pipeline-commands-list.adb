with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Registry_Store;

package body Synapse.Pipeline.Commands.List is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.List_Help);

   type Row is record
      Id, Name, Pipeline, Status, Step : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   function Text_Of (Item : JSON.Value; Key : String) return String is
     (if JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Padded (Text : String; Width : Natural) return String is
     (Text & [1 .. Width - Text'Length => ' ']);

   function Row_Of
     (Id : String; Name : Registry_Store.Maybe_Content; Brief : JSON.Value)
      return Row
   is
     (Id       => To_Unbounded_String (Id),
      Name     =>
        (if Name.Found then Name.Value else Null_Unbounded_String),
      Pipeline => To_Unbounded_String (Text_Of (Brief, "pipeline")),
      Status   => To_Unbounded_String (Text_Of (Brief, "status")),
      Step     => To_Unbounded_String (Text_Of (Brief, "current_step")));

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Work  : Unbounded_String;
      Found : Boolean;
      Rows  : Row_Vectors.Vector;
      Every : Boolean := False;
      Ids   : Synapse.Core.Text_Lists.Sets.Set;
   begin
      if Natural (Args.Length) > 1
        or else (not Args.Is_Empty and then To_String (Args.First_Element) /=
                 "--all")
      then
         return Usage_Error (Env, Usage);
      end if;
      Every := not Args.Is_Empty;
      Clients.Work_Directory (Env, Work, Found);
      if not Found then
         return 1;
      end if;
      for Id of Env.Inspector.Ids (To_String (Work)) loop
         Ids.Include (To_String (Id));
      end loop;
      Env.Registry.Open (To_String (Work));
      if Every then
         for Id of Env.Registry.Ids loop
            Ids.Include (To_String (Id));
         end loop;
      end if;
      for Id of Ids loop
         declare
            Answered : Boolean;
            Answer   : Unbounded_String;
            Ok       : Boolean := False;
            Result   : JSON.Value := JSON.Null_Value;
            Message  : Unbounded_String;
         begin
            Env.Inspector.Ask
              (Env.Inspector.Endpoint_For (To_String (Work), Id),
               "{""command"":""info""}", Answered, Answer);
            if Answered then
               Clients.Read_Answer (To_String (Answer), Ok, Result, Message);
            end if;
            if Ok and then JSON.Kind_Of (Result) = JSON.JSON_Object then
               Rows.Append (Row_Of (Id, Env.Registry.Read_Name (Id), Result));
            elsif Every then
               declare
                  Recorded : Boolean;
                  Brief    : JSON.Value;
               begin
                  Clients.Recorded_Brief
                    (Env, To_String (Work), Id, Recorded, Brief);
                  if Recorded then
                     Rows.Append
                       (Row_Of (Id, Env.Registry.Read_Name (Id), Brief));
                  end if;
               end;
            end if;
         end;
      end loop;
      if Rows.Is_Empty then
         return 0;
      end if;
      declare
         Widths : array (1 .. 4) of Natural :=
           [1 => 9, 2 => 4, 3 => 8, 4 => 6];
      begin
         for R of Rows loop
            Widths (1) := Natural'Max (Widths (1), Length (R.Id));
            Widths (2) := Natural'Max (Widths (2), Length (R.Name));
            Widths (3) := Natural'Max (Widths (3), Length (R.Pipeline));
            Widths (4) := Natural'Max (Widths (4), Length (R.Status));
         end loop;
         Say
           (Env,
            Padded ("EXECUTION", Widths (1)) & "  "
            & Padded ("NAME", Widths (2)) & "  "
            & Padded ("PIPELINE", Widths (3)) & "  "
            & Padded ("STATUS", Widths (4)) & "  STEP" & LF);
         for R of Rows loop
            Say
              (Env,
               Padded (To_String (R.Id), Widths (1)) & "  "
               & Padded (To_String (R.Name), Widths (2)) & "  "
               & Padded (To_String (R.Pipeline), Widths (3)) & "  "
               & Padded (To_String (R.Status), Widths (4)) & "  "
               & To_String (R.Step) & LF);
         end loop;
      end;
      return 0;
   end Run;

end Synapse.Pipeline.Commands.List;
