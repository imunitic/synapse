with Ada.Calendar;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Registry_Store;

package body Synapse.Pipeline.Commands.Cleanup is

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Cleanup_Help);

   --  Executions are kept this long after their last write.
   Default_Age : constant Duration := 30.0 * 24.0 * 3600.0;

   --  The age Text stands for, a whole number and a unit of d, h, m or s,
   --  such as 30d. Valid is False for anything else.
   procedure Parse_Age
     (Text : String; Valid : out Boolean; Age : out Duration)
   is
      Count : Long_Long_Integer := 0;
   begin
      Valid := False;
      Age := 0.0;
      if Text'Length < 2 or else Text'Length > 8 then
         return;
      end if;
      for I in Text'First .. Text'Last - 1 loop
         if Text (I) not in '0' .. '9' then
            return;
         end if;
         Count :=
           Count * 10 + Long_Long_Integer (Character'Pos (Text (I)) - 48);
      end loop;
      case Text (Text'Last) is
         when 's'    => Age := Duration (Count);
         when 'm'    => Age := Duration (Count * 60);
         when 'h'    => Age := Duration (Count * 3600);
         when 'd'    => Age := Duration (Count * 86400);
         when others => return;
      end case;
      Valid := True;
   end Parse_Age;

   function Text_Of (Item : JSON.Value; Key : String) return String is
     (if JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Age     : Duration := Default_Age;
      Dry     : Boolean := False;
      Every   : Boolean := False;
      Has_Age : Boolean := False;
      I       : Positive := Args.First_Index;
      Work    : Unbounded_String;
      Found   : Boolean;
      Failed  : Boolean := False;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--older-than" then
               declare
                  Valid : Boolean;
               begin
                  if Has_Age or else I = Args.Last_Index then
                     return Usage_Error (Env, Usage);
                  end if;
                  I := I + 1;
                  Parse_Age (To_String (Args (I)), Valid, Age);
                  if not Valid then
                     return Usage_Error (Env, Usage);
                  end if;
                  Has_Age := True;
               end;
            elsif Arg = "--dry-run" and then not Dry then
               Dry := True;
            elsif Arg = "--all" and then not Every then
               Every := True;
            else
               return Usage_Error (Env, Usage);
            end if;
         end;
         I := I + 1;
      end loop;
      Clients.Work_Directory (Env, Work, Found);
      if not Found then
         return 1;
      end if;
      Env.Registry.Open (To_String (Work));
      for Id of Env.Registry.Ids loop
         declare
            Name     : constant String := To_String (Id);
            Answered : Boolean;
            Answer   : Unbounded_String;
            Ok       : Boolean := False;
            Result   : JSON.Value := JSON.Null_Value;
            Message  : Unbounded_String;
            Recorded : Boolean;
            Brief    : JSON.Value;
         begin
            Env.Inspector.Ask
              (Env.Inspector.Endpoint_For (To_String (Work), Name),
               "{""command"":""info""}", Answered, Answer);
            if Answered then
               Clients.Read_Answer (To_String (Answer), Ok, Result, Message);
            end if;
            Clients.Recorded_Brief
              (Env, To_String (Work), Name, Recorded, Brief);
            if not Ok and then Recorded then
               declare
                  Status : constant String := Text_Of (Brief, "status");
                  Wrote  : constant Registry_Store.Time_Options.Option :=
                    Env.Registry.Last_Write (Name);
                  Old    : constant Boolean :=
                    Wrote.Found
                    and then Ada.Calendar.Clock - Wrote.Value > Age;
                  Over   : constant Boolean :=
                    Status in "completed" | "failed";
                  Remove : constant Boolean :=
                    Old or else (Every and then Over);
               begin
                  if Remove then
                     if Dry then
                        Say (Env, "would remove " & Name & LF);
                     elsif Env.Registry.Remove (Name) then
                        Say (Env, "removed " & Name & LF);
                     else
                        Complain (Env, "error: cannot remove " & Name & LF);
                        Failed := True;
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
      return (if Failed then 1 else 0);
   end Run;

end Synapse.Pipeline.Commands.Cleanup;
