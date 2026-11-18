with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

package body Synapse.Pipeline.Git_Working_Trees is

   use Ada.Strings.Unbounded;

   package Env renames Ada.Environment_Variables;

   Run_Limit : constant := 10 * 60;

   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set
       (' ' & Character'Val (9) & Character'Val (10) & Character'Val (13));

   function U (Text : String) return Unbounded_String renames
     To_Unbounded_String;

   --  The words that are given, in order; one that is empty is not given.
   function Words
     (A : String; B, C, D, E, F, G, H : String := "")
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;

      procedure Add (Word : String) is
      begin
         if Word /= "" then
            Result.Append (U (Word));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      Add (D);
      Add (E);
      Add (F);
      Add (G);
      Add (H);
      return Result;
   end Words;

   function No_Variables return Synapse.Core.Text_Lists.Vector is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      return Result;
   end No_Variables;

   --  Runs git in Directory with Arguments and the extra variables, with
   --  what keeps it from asking anyone anything and from reading the user's
   --  configuration of diff programs and quoting.
   function Run_Git
     (T         : in out Git_Working_Trees;
      Directory : String;
      Arguments : Synapse.Core.Text_Lists.Vector;
      Variables : Synapse.Core.Text_Lists.Vector := No_Variables)
      return Session_Process.Process_Outcome
   is
      Request : Session_Process.Process_Request;
   begin
      Request.Program := U ("git");
      for Item of Words
        ("--no-pager", "-c", "core.quotepath=off", "--literal-pathspecs")
      loop
         Request.Arguments.Append (Item);
      end loop;
      for Item of Arguments loop
         Request.Arguments.Append (Item);
      end loop;
      Request.Directory := U (Directory);
      Request.Environment.Append (U ("GIT_OPTIONAL_LOCKS=0"));
      Request.Environment.Append (U ("GIT_TERMINAL_PROMPT=0"));
      for Item of Variables loop
         Request.Environment.Append (Item);
      end loop;
      Request.Timeout_Seconds := Run_Limit;
      return T.Process.Run (Request);
   end Run_Git;

   function Succeeded
     (Outcome : Session_Process.Process_Outcome) return Boolean
   is (Outcome.Started and then not Outcome.Timed_Out
       and then Outcome.Exit_Code = 0);

   --  Text without the blanks and line breaks around it, as git ends what it
   --  prints.
   function Trimmed (Text : Unbounded_String) return String is
     (Ada.Strings.Fixed.Trim
        (To_String (Text),
         Left  => Blanks,
         Right => Blanks));

   --  Where the temporary index of the snapshot called Name is kept.
   function Index_Path (Name : String) return String is
      Folder : constant String :=
        (if Env.Exists ("TMPDIR") and then Env.Value ("TMPDIR") /= ""
         then Env.Value ("TMPDIR")
         elsif Env.Exists ("TEMP") and then Env.Value ("TEMP") /= ""
         then Env.Value ("TEMP")
         else "/tmp");
   begin
      return Folder & "/synapse-changes-" & Name & ".index";
   end Index_Path;

   procedure Forget (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Forget;

   overriding
   function Snapshot
     (T : in out Git_Working_Trees; Directory, Name : String)
      return Working_Trees.Maybe_Text
   is
      Index     : constant String := Index_Path (Name);
      Variables : constant Synapse.Core.Text_Lists.Vector :=
        Words ("GIT_INDEX_FILE=" & Index);
      Inside    : constant Session_Process.Process_Outcome :=
        Run_Git (T, Directory, Words ("rev-parse", "--is-inside-work-tree"));
   begin
      if not Succeeded (Inside) or else Trimmed (Inside.Output) /= "true" then
         return Working_Trees.Maybe_Text'(Found => False);
      end if;
      declare
         Added : constant Session_Process.Process_Outcome :=
           Run_Git (T, Directory, Words ("add", "-A"), Variables);
      begin
         if not Succeeded (Added) then
            Forget (Index);
            return Working_Trees.Maybe_Text'(Found => False);
         end if;
      end;
      declare
         Tree : constant Session_Process.Process_Outcome :=
           Run_Git (T, Directory, Words ("write-tree"), Variables);
      begin
         Forget (Index);
         if not Succeeded (Tree) or else Trimmed (Tree.Output) = "" then
            return Working_Trees.Maybe_Text'(Found => False);
         end if;
         return Working_Trees.Maybe_Text'
           (Found => True, Value => U (Trimmed (Tree.Output)));
      end;
   end Snapshot;

   overriding
   function Changes
     (T : in out Git_Working_Trees; Directory, Before, After : String)
      return Working_Trees.Maybe_Text
   is
      Diff : constant Session_Process.Process_Outcome :=
        Run_Git
          (T, Directory,
           Words
             ("diff", "--no-color", "--no-ext-diff", "--no-textconv",
              "--find-renames", Before, After));
   begin
      if not Succeeded (Diff) then
         return Working_Trees.Maybe_Text'(Found => False);
      end if;
      return Working_Trees.Maybe_Text'(Found => True, Value => Diff.Output);
   end Changes;

end Synapse.Pipeline.Git_Working_Trees;
