with Ada.Calendar;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Working_Trees;

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

   --  The folder the run Id worked in, by its summary; empty when the
   --  summary has none.
   function Directory_Of (Env : Environment; Id : String) return String is
      Held : constant Registry_Store.Maybe_Content :=
        Env.Registry.Read_Summary (Id);
   begin
      if not Held.Found then
         return "";
      end if;
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (To_String (Held.Value));
      begin
         return
           (if Parsed.Ok
              and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Object
            then Text_Of (Parsed.Item, "directory") else "");
      end;
   end Directory_Of;

   --  Deletes the refs that pin the snapshots of the run Id in the folder it
   --  worked in. A ref that is not there is left as it is, and nothing here
   --  stops the removal of the run.
   procedure Unpin_Snapshots (Env : Environment; Id : String) is
      Directory : constant String := Directory_Of (Env, Id);
   begin
      if Directory /= "" then
         Env.Trees.Unpin (Directory, Working_Trees.Run_Ref (Id, "start"));
         Env.Trees.Unpin (Directory, Working_Trees.Run_Ref (Id, "end"));
      end if;
   end Unpin_Snapshots;

   --  Whether the execution Name in the work directory Work is running,
   --  because its socket answers.
   function Is_Running
     (Env : Environment; Work, Name : String) return Boolean
   is
      Answered : Boolean;
      Answer   : Unbounded_String;
      Ok       : Boolean := False;
      Result   : JSON.Value := JSON.Null_Value;
      Message  : Unbounded_String;
   begin
      Env.Inspector.Ask
        (Env.Inspector.Endpoint_For (Work, Name), "{""command"":""info""}",
         Answered, Answer);
      if Answered then
         Clients.Read_Answer (To_String (Answer), Ok, Result, Message);
      end if;
      return Ok;
   end Is_Running;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   --  What one cleanup did: the executions removed (or, with Dry, that
   --  would be) and the ones kept, each with why. With As_JSON nothing is
   --  printed per execution; the whole of it is printed at the end instead.
   type Report is record
      Dry     : Boolean := False;
      As_JSON : Boolean := False;
      Removed : Lists.Vector;
      Kept    : Lists.Vector;
      Reasons : Lists.Vector;
   end record;

   --  Records that Name was removed and, in text, says Line on stdout.
   procedure Note_Removed
     (Env : Environment; R : in out Report; Name, Line : String) is
   begin
      R.Removed.Append (To_Unbounded_String (Name));
      if not R.As_JSON then
         Say (Env, Line & LF);
      end if;
   end Note_Removed;

   --  Records that Name was kept for Reason and, in text, says Line on
   --  stderr when there is one.
   procedure Note_Kept
     (Env    : Environment;
      R      : in out Report;
      Name   : String;
      Reason : String;
      Line   : String := "") is
   begin
      R.Kept.Append (To_Unbounded_String (Name));
      R.Reasons.Append (To_Unbounded_String (Reason));
      if not R.As_JSON and then Line /= "" then
         Complain (Env, Line & LF);
      end if;
   end Note_Kept;

   --  The synapse-pipeline-cleanup/v1 document of R.
   function Document_Of (R : Report) return String is
      Removed : JSON.Value_Array (1 .. Natural (R.Removed.Length));
      Kept    : JSON.Value_Array (1 .. Natural (R.Kept.Length));
   begin
      for I in Removed'Range loop
         Removed (I) :=
           JSON.Make_String
             (To_String (R.Removed (R.Removed.First_Index + I - 1)));
      end loop;
      for I in Kept'Range loop
         Kept (I) :=
           JSON.Make_Object
             ([Member
                 ("id",
                  JSON.Make_String
                    (To_String (R.Kept (R.Kept.First_Index + I - 1)))),
               Member
                 ("reason",
                  JSON.Make_String
                    (To_String (R.Reasons (R.Reasons.First_Index + I - 1))))]);
      end loop;
      return
        JSON.To_String
          (JSON.Make_Object
             ([Member
                 ("format", JSON.Make_String ("synapse-pipeline-cleanup/v1")),
               Member ("dry_run", JSON.Make_Boolean (R.Dry)),
               Member ("removed", JSON.Make_Array (Removed)),
               Member ("kept", JSON.Make_Array (Kept))]));
   end Document_Of;

   --  Removes the execution Name, its snapshots unpinned first, and notes
   --  it; with R.Dry only notes that it would be. False when the removal
   --  failed.
   function Remove_One
     (Env : Environment; R : in out Report; Name : String) return Boolean is
   begin
      if R.Dry then
         Note_Removed (Env, R, Name, "would remove " & Name);
         return True;
      end if;
      Unpin_Snapshots (Env, Name);
      if Env.Registry.Remove (Name) then
         Note_Removed (Env, R, Name, "removed " & Name);
         return True;
      end if;
      Note_Kept
        (Env, R, Name, "cannot_remove", "error: cannot remove " & Name);
      return False;
   end Remove_One;

   --  Removes the executions Given, in order and once each, whatever their
   --  age or status, but one that is running or not recorded. True when
   --  every one was removed (or, with R.Dry, would be).
   function Remove_Given
     (Env   : Environment;
      R     : in out Report;
      Work  : String;
      Given : Lists.Vector) return Boolean
   is
      Known       : constant Lists.Vector := Env.Registry.Ids;
      Seen        : Lists.Vector;
      All_Removed : Boolean := True;
   begin
      for Id of Given loop
         if not Seen.Contains (Id) then
            Seen.Append (Id);
            declare
               Name : constant String := To_String (Id);
            begin
               if not Known.Contains (Id) then
                  Note_Kept
                    (Env, R, Name, "not_found", "error: no execution " & Name);
                  All_Removed := False;
               elsif Is_Running (Env, Work, Name) then
                  Note_Kept
                    (Env, R, Name, "running",
                     "error: " & Name & " is running, not removed");
                  All_Removed := False;
               elsif not Remove_One (Env, R, Name) then
                  All_Removed := False;
               end if;
            end;
         end if;
      end loop;
      return All_Removed;
   end Remove_Given;

   --  Removes the recorded executions that are not running and whose last
   --  write is older than Age or, with Every, that completed or failed.
   --  Failed is set when a removal failed.
   procedure Remove_Over
     (Env    : Environment;
      R      : in out Report;
      Work   : String;
      Age    : Duration;
      Every  : Boolean;
      Failed : in out Boolean) is
   begin
      for Id of Env.Registry.Ids loop
         declare
            Name     : constant String := To_String (Id);
            Recorded : Boolean;
            Brief    : JSON.Value;
         begin
            Clients.Recorded_Brief (Env, Work, Name, Recorded, Brief);
            if Recorded and then Is_Running (Env, Work, Name) then
               Note_Kept (Env, R, Name, "running");
            elsif Recorded then
               declare
                  Status : constant String := Text_Of (Brief, "status");
                  Wrote  : constant Registry_Store.Time_Options.Option :=
                    Env.Registry.Last_Write (Name);
                  Old    : constant Boolean :=
                    Wrote.Found
                    and then Ada.Calendar.Clock - Wrote.Value > Age;
                  Over   : constant Boolean :=
                    Status in "completed" | "failed";
               begin
                  if not (Old or else (Every and then Over)) then
                     Note_Kept (Env, R, Name, "too_recent");
                  elsif not Remove_One (Env, R, Name) then
                     Failed := True;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Remove_Over;

   --  Whether Arg is written as an option, starting with --.
   function Is_Option (Arg : String) return Boolean is
     (Arg'Length >= 2 and then Arg (Arg'First .. Arg'First + 1) = "--");

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Age        : Duration := Default_Age;
      Dry        : Boolean := False;
      Format     : Unbounded_String := To_Unbounded_String ("text");
      Has_Format : Boolean := False;
      Every      : Boolean := False;
      Has_Age    : Boolean := False;
      I          : Positive := Args.First_Index;
      Work       : Unbounded_String;
      Found      : Boolean;
      Failed     : Boolean := False;
      Given      : Lists.Vector;
      R          : Report;
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
            elsif Arg = "--format" then
               if Has_Format or else I = Args.Last_Index then
                  return Usage_Error (Env, Usage);
               end if;
               I := I + 1;
               Format := Args (I);
               if To_String (Format) not in "json" | "text" then
                  return Usage_Error (Env, Usage);
               end if;
               Has_Format := True;
            elsif Arg = "--dry-run" and then not Dry then
               Dry := True;
            elsif Arg = "--all" and then not Every then
               Every := True;
            elsif not Is_Option (Arg)
              and then Registry_Store.Is_Plain_Name (Arg)
            then
               Given.Append (Args (I));
            else
               return Usage_Error (Env, Usage);
            end if;
         end;
         I := I + 1;
      end loop;
      if not Given.Is_Empty and then (Has_Age or else Every) then
         return Usage_Error (Env, Usage);
      end if;
      Clients.Work_Directory (Env, Work, Found);
      if not Found then
         return 1;
      end if;
      Env.Registry.Open (To_String (Work));
      R.Dry := Dry;
      R.As_JSON := To_String (Format) = "json";
      if not Given.Is_Empty then
         Failed := not Remove_Given (Env, R, To_String (Work), Given);
      else
         Remove_Over (Env, R, To_String (Work), Age, Every, Failed);
      end if;
      if R.As_JSON then
         Say (Env, Document_Of (R) & LF);
      end if;
      return (if Failed then 1 else 0);
   end Run;

end Synapse.Pipeline.Commands.Cleanup;
