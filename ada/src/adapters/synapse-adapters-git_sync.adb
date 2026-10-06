with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;

with Synapse.Core.Text_Lists;
with Ada.Strings.Unbounded;

package body Synapse.Adapters.Git_Sync is

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;

   LF : constant Character := Character'Val (10);

   Max_Named_Files : constant := 4;

   --  Git's own limit on how long a connect may hang, so a key that wants a
   --  passphrase cannot wait for a prompt nobody sees.
   Ssh_Option : constant String :=
     "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10";

   function Lock_Path (Vault : String) return String
   is (Vault & "/.git/synapse-sync.lock");

   procedure Try_Acquire (Vault : String; L : in out Dir_Lock.Lock) is
   begin
      Dir_Lock.Try_Acquire (Lock_Path (Vault), Lock_Stale_After, L);
   end Try_Acquire;

   procedure Acquire_With_Retry
     (Vault : String; Max_Tries : Positive; L : in out Dir_Lock.Lock) is
   begin
      Dir_Lock.Acquire_With_Retry
        (Lock_Path (Vault), Lock_Stale_After, Max_Tries, L);
   end Acquire_With_Retry;

   function Trimmed (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last
        and then S (First) in ' ' | Character'Val (9) | Character'Val (13) | LF
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then S (Last) in ' ' | Character'Val (9) | Character'Val (13) | LF
      loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trimmed;

   --  The non-empty ones of the arguments, as a list.
   function Words
     (A1 : String;
      A2, A3, A4, A5, A6, A7 : String := "") return Core.Text_Lists.Vector
   is
      Result : Core.Text_Lists.Vector;

      procedure Add (Item : String) is
      begin
         if Item'Length > 0 then
            Result.Append (To_Unbounded_String (Item));
         end if;
      end Add;
   begin
      Add (A1);
      Add (A2);
      Add (A3);
      Add (A4);
      Add (A5);
      Add (A6);
      Add (A7);
      return Result;
   end Words;

   function Git
     (R     : in out Runner.Runner'Class;
      Vault : String;
      Args  : Core.Text_Lists.Vector) return Runner.Result
   is (R.Run ("git", Args,
              (Cwd => To_Unbounded_String (Vault), others => <>)));

   function Upstream_Of
     (R : in out Runner.Runner'Class; Vault : String)
      return Ports.Store.Maybe_Text
   is
      Result : constant Runner.Result :=
        Git (R, Vault,
             Words ("rev-parse", "--abbrev-ref", "--symbolic-full-name",
                    "@{upstream}"));
      Name   : constant String := Trimmed (To_String (Result.Output));
   begin
      if not Runner.Succeeded (Result) or else Name'Length = 0 then
         return (Found => False);
      end if;
      return (Found => True, Text => To_Unbounded_String (Name));
   end Upstream_Of;

   function Pull (R : in out Runner.Runner'Class; Vault : String)
      return Boolean is
   begin
      if not Upstream_Of (R, Vault).Found then
         return True;
      end if;
      declare
         Result : constant Runner.Result :=
           Git (R, Vault,
                Words ("-c", Ssh_Option, "pull", "--rebase", "--autostash",
                       "--quiet"));
      begin
         if Runner.Succeeded (Result) then
            return True;
         end if;
      end;
      declare
         Ignore : constant Runner.Result :=
           Git (R, Vault, Words ("rebase", "--abort"));
      begin
         return False;
      end;
   exception
      when Ports.Process_Runner.Process_Failure =>
         return False;
   end Pull;

   function Commit_Message (Staged : String) return String is
      Count : Natural := 1;
      Names : Unbounded_String;
   begin
      for C of Staged loop
         if C = LF then
            Count := Count + 1;
         end if;
      end loop;
      if Count > Max_Named_Files then
         declare
            Text : constant String := Natural'Image (Count);
         begin
            return "vault:" & Text & " files";
         end;
      end if;
      for C of Staged loop
         if C = LF then
            Append (Names, ", ");
         else
            Append (Names, C);
         end if;
      end loop;
      return "vault: " & To_String (Names);
   end Commit_Message;

   --  Sets a local identity only when none resolves from any configuration:
   --  a vault made here, or one that arrived with a bare `.git` on a machine
   --  with no identity, cannot commit without one.
   procedure Ensure_Identity (R : in out Runner.Runner'Class; Vault : String)
   is
      Check : constant Runner.Result :=
        Git (R, Vault, Words ("config", "user.email"));
   begin
      if Runner.Succeeded (Check)
        and then Trimmed (To_String (Check.Output))'Length > 0
      then
         return;
      end if;
      declare
         Ignore_Email : constant Runner.Result :=
           Git (R, Vault,
                Words ("config", "user.email", "vault@synapse.local"));
         Ignore_Name  : constant Runner.Result :=
           Git (R, Vault, Words ("config", "user.name", "Synapse Vault"));
      begin
         null;
      end;
   end Ensure_Identity;

   procedure Commit_If_Dirty (R : in out Runner.Runner'Class; Vault : String)
   is
      Add : constant Runner.Result := Git (R, Vault, Words ("add", "-A"));
   begin
      if not Runner.Succeeded (Add) then
         return;
      end if;
      declare
         --  core.quotePath=false: git would otherwise write any non-ASCII
         --  byte of a path as an octal escape, and that text would land in
         --  the commit message.
         Names  : constant Runner.Result :=
           Git (R, Vault,
                Words ("-c", "core.quotePath=false", "diff", "--cached",
                       "--name-only"));
         Staged : constant String := Trimmed (To_String (Names.Output));
      begin
         if not Runner.Succeeded (Names) or else Staged'Length = 0 then
            return;
         end if;
         Ensure_Identity (R, Vault);
         declare
            Ignore : constant Runner.Result :=
              Git (R, Vault,
                   Words ("commit", "--quiet", "-m", Commit_Message (Staged)));
         begin
            null;
         end;
      end;
   end Commit_If_Dirty;

   function Commits_Ahead (R : in out Runner.Runner'Class; Vault : String)
      return Natural
   is
      Upstream : constant Ports.Store.Maybe_Text := Upstream_Of (R, Vault);
   begin
      if not Upstream.Found then
         return 0;
      end if;
      declare
         Result : constant Runner.Result :=
           Git (R, Vault,
                Words ("rev-list", "--count",
                       To_String (Upstream.Text) & "..HEAD"));
         Text   : constant String := Trimmed (To_String (Result.Output));
      begin
         if not Runner.Succeeded (Result) or else Text'Length = 0
           or else not (for all C of Text => C in '0' .. '9')
           or else Text'Length > 9
         then
            return 0;
         end if;
         return Natural'Value (Text);
      end;
   end Commits_Ahead;

   procedure Push_If_Ahead (R : in out Runner.Runner'Class; Vault : String) is
   begin
      if Commits_Ahead (R, Vault) = 0 then
         return;
      end if;
      declare
         Ignore : constant Runner.Result :=
           Git (R, Vault, Words ("-c", Ssh_Option, "push", "--quiet"));
      begin
         null;
      end;
   exception
      when Ports.Process_Runner.Process_Failure =>
         null;
   end Push_If_Ahead;

   procedure Ensure_Repo (R : in out Runner.Runner'Class; Vault : String) is
      Dot_Git : constant String := Vault & "/.git";
   begin
      if Ada.Directories.Exists (Dot_Git)
        and then Ada.Directories.Kind (Dot_Git) = Ada.Directories.Directory
      then
         return;
      end if;
      declare
         Ignore : constant Runner.Result :=
           Git (R, Vault, Words ("init", "-q"));
      begin
         null;
      end;
   end Ensure_Repo;

   procedure Report (Text : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "synapse: " & Text);
   end Report;

   procedure Commit_Under_Lock
     (R : in out Runner.Runner'Class; Vault : String; Committed : out Boolean)
   is
      L : Dir_Lock.Lock;
   begin
      Committed := False;
      begin
         Ensure_Repo (R, Vault);
      exception
         when E : others =>
            Report ("git repo init failed, change kept local ("
                    & Ada.Exceptions.Exception_Name (E) & ")");
            return;
      end;
      Try_Acquire (Vault, L);
      if not Dir_Lock.Held (L) then
         return;
      end if;
      begin
         Commit_If_Dirty (R, Vault);
         Committed := True;
      exception
         when E : others =>
            Report ("git commit failed, change kept local ("
                    & Ada.Exceptions.Exception_Name (E) & ")");
      end;
   end Commit_Under_Lock;

   procedure Run_Pusher (R : in out Runner.Runner'Class; Vault : String) is
      L : Dir_Lock.Lock;
   begin
      Acquire_With_Retry (Vault, 10, L);
      if not Dir_Lock.Held (L) then
         return;
      end if;
      if not Pull (R, Vault) then
         return;
      end if;
      begin
         Commit_If_Dirty (R, Vault);
      exception
         when others =>
            null;
      end;
      Push_If_Ahead (R, Vault);
   exception
      when others =>
         null;
   end Run_Pusher;

end Synapse.Adapters.Git_Sync;
