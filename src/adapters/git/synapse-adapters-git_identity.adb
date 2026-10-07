with Ada.Directories;
with Ada.Strings.Unbounded;
with GNAT.OS_Lib;

with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.Git_Identity is

   use Ada.Strings.Unbounded;
   use Core.Identity;
   use type Ada.Directories.File_Kind;

   Largest_Small_File : constant := 64 * 1_024;
   Largest_Config     : constant := 8 * 1_024 * 1_024;

   --  The path without symbolic links or `..`.
   function Real_Path (Path : String) return String is
     (GNAT.OS_Lib.Normalize_Pathname
        (Path, Resolve_Links => True, Case_Sensitive => True));

   function Is_Absolute (Path : String) return Boolean is
     (Path'Length > 0
      and then
      (Path (Path'First) in '/' | '\'
       or else (Path'Length > 1 and then Path (Path'First + 1) = ':')));

   function Joined (Base, Relative : String) return String is
     (if Is_Absolute (Relative) then Relative else Base & "/" & Relative);

   function Parent_Of (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return "";
   end Parent_Of;

   --  The file, or "" when it cannot be read.
   function Contents (Path : String; Limit : Natural) return String is
   begin
      return File_Bytes.Read (Path, Limit);
   exception
      when others =>
         return "";
   end Contents;

   function Is_Directory (Path : String) return Boolean is
   begin
      return Ada.Directories.Kind (Path) = Ada.Directories.Directory;
   exception
      when others =>
         return False;
   end Is_Directory;

   function Is_File (Path : String) return Boolean is
   begin
      return Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File;
   exception
      when others =>
         return False;
   end Is_File;

   function Trimmed (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last
        and then S (First) in
          ' ' | Character'Val (9) | Character'Val (13) | Character'Val (10)
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then S (Last) in
          ' ' | Character'Val (9) | Character'Val (13) | Character'Val (10)
      loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trimmed;

   function Layout_Of_Worktree (Root, Dot_Git : String) return Layout is
      Named : constant Maybe_Text :=
        Parse_Git_Dir_File (Contents (Dot_Git, Largest_Small_File));
   begin
      if not Named.Found then
         raise Not_A_Git_Repo;
      end if;
      declare
         Git_Dir : constant String := Joined (Root, To_String (Named.Value));
         --  `commondir` names, relative to the git directory, where the
         --  shared data is: `config` is there and never in the worktree's.
         Common  : constant String :=
           Trimmed (Contents (Git_Dir & "/commondir", Largest_Small_File));
      begin
         if Common'Length = 0 then
            return
              (Repo_Root  => To_Unbounded_String (Root),
               Git_Dir    => To_Unbounded_String (Git_Dir),
               Common_Dir => To_Unbounded_String (Git_Dir));
         end if;
         declare
            Joined_Path : constant String := Joined (Git_Dir, Common);
            Resolved    : constant String :=
              (if Ada.Directories.Exists (Joined_Path) then
                 Real_Path (Joined_Path)
               else Joined_Path);
         begin
            return
              (Repo_Root  => To_Unbounded_String (Root),
               Git_Dir    => To_Unbounded_String (Git_Dir),
               Common_Dir => To_Unbounded_String (Resolved));
         end;
      end;
   end Layout_Of_Worktree;

   function Find_Layout (Cwd : String) return Layout is
      Start : constant String  :=
        (if Ada.Directories.Exists (Cwd) then Real_Path (Cwd) else "");
      Dir   : Unbounded_String := To_Unbounded_String (Start);
   begin
      if Start'Length = 0 then
         raise Not_A_Git_Repo;
      end if;
      loop
         declare
            Root    : constant String := To_String (Dir);
            Dot_Git : constant String := Root & "/.git";
         begin
            if Is_Directory (Dot_Git) then
               return
                 (Repo_Root  => To_Unbounded_String (Root),
                  Git_Dir    => To_Unbounded_String (Dot_Git),
                  Common_Dir => To_Unbounded_String (Dot_Git));
            elsif Is_File (Dot_Git) then
               return Layout_Of_Worktree (Root, Dot_Git);
            end if;
            declare
               Parent : constant String := Parent_Of (Root);
            begin
               if Parent'Length = 0 or else Parent = Root then
                  raise Not_A_Git_Repo;
               end if;
               Dir := To_Unbounded_String (Parent);
            end;
         end;
      end loop;
   end Find_Layout;

   function Remote_Of (Where : Layout) return String is
      Config : constant String     :=
        Contents (To_String (Where.Common_Dir) & "/config", Largest_Config);
      Url : constant Maybe_Text := Remote_Url_From_Config (Config, "origin");
   begin
      return
        (if Url.Found then To_String (Url.Value)
         else To_String (Where.Repo_Root));
   end Remote_Of;

   function Resolve (Cwd : String) return Resolved is
      Where : constant Layout := Find_Layout (Cwd);
      Head  : constant String :=
        Contents (To_String (Where.Git_Dir) & "/HEAD", Largest_Small_File);
   begin
      if Head'Length = 0 then
         raise Not_A_Git_Repo;
      end if;
      declare
         Branch : constant Maybe_Text := Parse_Head (Head);
      begin
         if not Branch.Found then
            raise Detached_Head;
         end if;
         declare
            Remote : constant String := Remote_Of (Where);
            Key    : constant String :=
              Sanitize_Branch (To_String (Branch.Value));
         begin
            return
              (Where  => Where, Remote => To_Unbounded_String (Remote),
               Branch => Branch.Value, Branch_Key => To_Unbounded_String (Key),
               Key    =>
                 To_Unbounded_String (Namespace (Repo_Name (Remote), Key)));
         end;
      end;
   end Resolve;

end Synapse.Adapters.Git_Identity;
