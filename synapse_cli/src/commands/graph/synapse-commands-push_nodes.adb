with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Write_Node;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Node_Query;

package body Synapse.Commands.Push_Nodes is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Image renames Synapse.Core.Decimal_Image;

   Prog : constant String    := "synapse-push-nodes";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse push-nodes [NN ...]" & LF & LF &
     "  NN   three-digit node numbers to push. Default: every b-NN.md and " &
     "lists/NN.title." & LF;

   Largest_Body  : constant := 64 * 1_024 * 1_024;
   Largest_List  : constant := 256 * 1_024 * 1_024;
   Largest_Title : constant := 1_024 * 1_024;

   --  The `NNN` of every entry of Dir named `<Prefix>NNN<Suffix>`, exactly
   --  three digits: `b-1.md` and `b-1000.md` are not node files. Tied to the
   --  three digit width of `Node_Format.Max_Nodes`.
   procedure Collect (Dir, Prefix, Suffix : String; Into : in out Lists.Vector)
   is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Dir) then
         return;
      end if;
      Ada.Directories.Start_Search
        (Search, Dir, "*",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String  := Ada.Directories.Simple_Name (Item);
            Mid  : constant Natural := Name'First + Prefix'Length;
         begin
            if Name'Length = Prefix'Length + 3 + Suffix'Length
              and then Name (Name'First .. Mid - 1) = Prefix
              and then Name (Mid + 3 .. Name'Last) = Suffix
              and then (for all C of Name (Mid .. Mid + 2) => C in '0' .. '9')
            then
               Into.Append (To_Unbounded_String (Name (Mid .. Mid + 2)));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Collect;

   --  The union of `lists/NNN.title` and `b-NNN.md`, in byte order and
   --  without repeats: either side alone would let a mismatched node vanish
   --  silently.
   function Discover (Work, Lists_Dir : String) return Lists.Vector is
      Found : Lists.Vector;

      function Before (Left, Right : Unbounded_String) return Boolean is
        (Left < Right);

      package Sorting is new Lists.Vectors.Generic_Sorting (Before);
   begin
      Collect (Lists_Dir, "", ".title", Found);
      Collect (Work, "b-", ".md", Found);
      Sorting.Sort (Found);
      declare
         Result : Lists.Vector;
      begin
         for Item of Found loop
            if Result.Is_Empty or else Result.Last_Element /= Item then
               Result.Append (Item);
            end if;
         end loop;
         return Result;
      end;
   end Discover;

   function Trim_End_Line_Feeds (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) = LF loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trim_End_Line_Feeds;

   function Push
     (Env      : Environment; Ctx : Context.Context; Targets : Lists.Vector;
      Explicit : Boolean) return Exit_Code
   is
      Work      : constant String := To_String (Ctx.Work_Dir);
      Lists_Dir : constant String := Work & "/lists";
      Names     : Lists.Vector    := Targets;
      Pushed    : Natural         := 0;
      Failed    : Natural         := 0;
   begin
      if not Ada.Directories.Exists (Lists_Dir) then
         Complain
           (Env,
            Prog & ": no lists/ in " & Work &
            " -- run `synapse build-lists` first" & LF);
         return 1;
      end if;

      if not Explicit then
         Names.Append_Vector (Discover (Work, Lists_Dir));
         if Names.Is_Empty then
            Complain
              (Env,
               Prog & ": nothing to push (no lists/NN.title or b-NN.md in " &
               Work & ")" & LF);
            return 1;
         end if;
      end if;

      for Name of Names loop
         declare
            NN        : constant String := To_String (Name);
            Body_Text : Unbounded_String;
            List_Text : Unbounded_String;
            Title     : Unbounded_String;
            Have      : Boolean;
         begin
            Support.Read_File
              (Work & "/b-" & NN & ".md", Largest_Body, Body_Text, Have);
            if not Have then
               Say (Env, NN & HT & "SKIP (no body)" & LF);
               goto Next;
            end if;
            Support.Read_File
              (Lists_Dir & "/" & NN & ".txt", Largest_List, List_Text, Have);
            if not Have then
               List_Text := Null_Unbounded_String;
            end if;
            Support.Read_File
              (Lists_Dir & "/" & NN & ".title", Largest_Title, Title, Have);
            --  An empty list is a skip too: a node claiming no files is not
            --  one.
            if not Have or else Length (List_Text) = 0 then
               Say (Env, NN & HT & "SKIP (no list/title)" & LF);
               goto Next;
            end if;

            declare
               Summary : constant Core.Node_Query.Maybe_Text :=
                 Core.Node_Query.Field (To_String (Body_Text), "summary");
            begin
               --  A failure and not a skip: the body exists, so a missing
               --  summary is a mistake in it and not unfinished work.
               if not Summary.Found or else Length (Summary.Value) = 0 then
                  Say
                    (Env,
                     NN & HT & "FAILED (no `summary:` frontmatter in b-" & NN &
                     ".md)" & LF);
                  Failed := Failed + 1;
                  goto Next;
               end if;

               declare
                  Line : Unbounded_String;
                  Code : Exit_Code;
               begin
                  begin
                     Code :=
                       Write_Node.Write
                         (Env, Ctx,
                          (Title     =>
                             To_Unbounded_String
                               (Trim_End_Line_Feeds (To_String (Title))),
                           Summary   => Summary.Value, Paths_Text => List_Text,
                           Body_Text =>
                             To_Unbounded_String
                               (Core.Node_Query.Body_After_Frontmatter
                                  (To_String (Body_Text)))),
                          Line);
                  exception
                     when others =>
                        Code := 1;
                  end;
                  if Code = 0 then
                     Say (Env, NN & HT & To_String (Line));
                     Pushed := Pushed + 1;
                  else
                     Say (Env, NN & HT & "FAILED" & LF);
                     Failed := Failed + 1;
                  end if;
               end;
            end;
         end;
         <<Next>>
         null;
      end loop;

      if Failed /= 0 then
         Complain
           (Env, Prog & ": " & Image.Image (Failed) & " node(s) failed" & LF);
         return 1;
      end if;
      if Pushed = 0 then
         Complain
           (Env,
            Prog & ": nothing to push (no node had both a list and a body)" &
            LF);
         return 1;
      end if;
      return 0;
   end Push;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Targets  : Lists.Vector;
      Explicit : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg'Length /= 0 and then Arg (Arg'First) = '-' then
               return Usage_Error (Env, Usage_Text);
            end if;
            Explicit := True;
            Targets.Append (Arg_Item);
         end;
      end loop;
      declare
         Found : constant Context.Maybe_Context := Context.Resolve (Env, Prog);
      begin
         if not Found.Found then
            return 1;
         end if;
         return Push (Env, Found.Value, Targets, Explicit);
      end;
   end Run;

end Synapse.Commands.Push_Nodes;
