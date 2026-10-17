with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Store_Resolve;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Emit;
with Synapse.Core.Node_Query;
with Synapse.Core.Project_Index;
with Synapse.Core.Timestamps;
with Synapse.Ports.Store;

package body Synapse.Commands.Project_Index is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Index renames Synapse.Core.Project_Index;
   package Port renames Synapse.Ports.Store;

   Prog : constant String    := "synapse-build-project-index";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String := "usage: synapse build-project-index" & LF;

   package Sorting is new Lists.Vectors.Generic_Sorting
     ("<" => Ada.Strings.Unbounded."<");

   function Count_Lines (Text : String) return Natural is
      Count : Natural := 0;
   begin
      for C of Text loop
         if C = LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Lines;

   --  The `NNN` of every `lists/NNN<Suffix>` file, in byte order.
   function Stems (Dir, Suffix : String) return Lists.Vector is
      Result : Lists.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      begin
         Ada.Directories.Start_Search
           (Search, Dir, "*" & Suffix,
            [Ada.Directories.Ordinary_File => True, others => False]);
      exception
         when others =>
            return Result;
      end;
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length > Suffix'Length then
               Result.Append
                 (To_Unbounded_String
                    (Name (Name'First .. Name'Last - Suffix'Length)));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Sorting.Sort (Result);
      return Result;
   end Stems;

   --  `all.txt`'s line count, or the distinct paths of the lists when it is
   --  absent: the lists only cover what a node claimed, so the union is the
   --  honest fallback and not zero.
   function Total_Files
     (Env : Environment; Work_Dir, Lists_Dir : String) return Natural
   is
      Text : Unbounded_String;
      Read : Boolean;
      Seen : Core.Text_Lists.Set;
   begin
      Support.Read_File
        (Work_Dir & "/all.txt",
         Support.Max_Listing_Bytes (Env, 256 * 1_024 * 1_024), Text, Read);
      if Read and then Length (Text) > 0 then
         return Count_Lines (To_String (Text));
      end if;
      for Stem of Stems (Lists_Dir, ".txt") loop
         Support.Read_File
           (Lists_Dir & "/" & To_String (Stem) & ".txt", 256 * 1_024 * 1_024,
            Text, Read);
         if Read then
            declare
               Whole : constant String := To_String (Text);
               Start : Positive        := Whole'First;
            begin
               for I in Whole'First .. Whole'Last + 1 loop
                  if I > Whole'Last or else Whole (I) = LF then
                     if I > Start then
                        Seen.Include (Whole (Start .. I - 1));
                     end if;
                     Start := I + 1;
                  end if;
               end loop;
            end;
         end if;
      end loop;
      return Natural (Seen.Length);
   end Total_Files;

   function "<" (A, B : Index.Bullet) return Boolean is (A.Link < B.Link);

   package Bullet_Sorting is new Index.Bullet_Vectors.Generic_Sorting ("<");

   function Write (Env : Environment; Ctx : Context.Context) return Exit_Code
   is
      Work_Dir  : constant String       := To_String (Ctx.Work_Dir);
      Lists_Dir : constant String       := Work_Dir & "/lists";
      Names     : constant Lists.Vector := Stems (Lists_Dir, ".title");
      Bullets   : Index.Bullet_Vectors.Vector;
   begin
      if Names.Is_Empty then
         Complain (Env, Prog & ": no lists/NN.title in " & Work_Dir & LF);
         return 1;
      end if;
      for Stem of Names loop
         declare
            Title : Unbounded_String;
            List  : Unbounded_String;
            Read  : Boolean;
         begin
            Support.Read_File
              (Lists_Dir & "/" & To_String (Stem) & ".title", 1_048_576, Title,
               Read);
            if Read then
               declare
                  Raw  : constant String := To_String (Title);
                  Last : Natural         := Raw'Last;
               begin
                  while Last >= Raw'First and then Raw (Last) = LF loop
                     Last := Last - 1;
                  end loop;
                  declare
                     Link  : constant String             :=
                       Core.Emit.File_Title (Raw (Raw'First .. Last));
                     Files : Natural                     := 0;
                     Node  : constant Context.Maybe_Text :=
                       Context.Read_Node (Ctx, Link);
                  begin
                     Support.Read_File
                       (Lists_Dir & "/" & To_String (Stem) & ".txt",
                        256 * 1_024 * 1_024, List, Read);
                     if Read then
                        Files := Count_Lines (To_String (List));
                     end if;
                     if not Node.Found then
                        Complain
                          (Env,
                           Prog & ": node not in the vault: " & Link & ".md" &
                           LF &
                           "  the index is built from the nodes, so write " &
                           "them first" & LF);
                        return 1;
                     end if;
                     --  `Scalar` and not `Field`: unescaped, since the
                     --  summary goes into prose.
                     declare
                        Got     : constant Core.Node_Query.Maybe_Text :=
                          Core.Node_Query.Scalar
                            (To_String (Node.Value), "summary");
                        Summary : String                              :=
                          (if Got.Found then To_String (Got.Value) else "");
                     begin
                        if Summary'Length = 0 then
                           Complain
                             (Env,
                              Prog & ": no summary field on " & Link & ".md" &
                              LF);
                           return 1;
                        end if;
                        for C of Summary loop
                           if C = ASCII.HT then
                              C := ' ';
                           end if;
                        end loop;
                        Bullets.Append
                          (Index.Bullet'
                             (Link    => To_Unbounded_String (Link),
                              Files   => Files,
                              Summary => To_Unbounded_String (Summary)));
                     end;
                  end;
               end;
            end if;
         end;
      end loop;
      Bullet_Sorting.Sort (Bullets);

      declare
         Total : constant Natural := Total_Files (Env, Work_Dir, Lists_Dir);
         Namespace : constant String  := To_String (Ctx.Namespace);
         At_Sign   : Natural          := Namespace'Last + 1;
         Params    : Index.Params;
      begin
         for I in Namespace'Range loop
            if Namespace (I) = '@' then
               At_Sign := I;
               exit;
            end if;
         end loop;
         Params.Namespace   := Ctx.Namespace;
         Params.Project     :=
           To_Unbounded_String (Namespace (Namespace'First .. At_Sign - 1));
         Params.Branch      := Ctx.Branch;
         Params.Remote      := Ctx.Remote;
         Params.Built_At    :=
           To_Unbounded_String
             (Core.Timestamps.Built_At (Env.Clock.Timestamp));
         Params.Total_Files := Total;
         Params.Bullets     := Bullets;

         declare
            Stack : Adapters.Store_Resolve.Stack;
            Ok    : Boolean;
         begin
            Adapters.Store_Resolve.Resolve
              (S => Stack, Vars => Env.Vars, Vault => To_String (Ctx.Vault),
               Namespace => To_String (Ctx.Dir), Prog => Prog, Spawner => null,
               Valid     => Ok);
            if not Ok then
               return 1;
            end if;
            declare
               Wrote : constant Port.Write_Result :=
                 Adapters.Store_Resolve.Store (Stack).Write
                   ("Index.md", Index.Image (Params));
            begin
               if not Wrote.Accepted then
                  Complain
                    (Env,
                     Prog & ": write rejected (" &
                     Core.Decimal_Image.Image (Wrote.Status) & "): " &
                     To_String (Wrote.Body_Text) & LF);
                  return 1;
               end if;
            end;
            Say
              (Env,
               "Index.md written: " &
               Core.Decimal_Image.Image (Natural (Bullets.Length)) &
               " nodes, " & Core.Decimal_Image.Image (Total) &
               " tracked files, remote=" & To_String (Ctx.Remote) & LF);
            return 0;
         exception
            when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
               Complain (Env, Prog & ": write failed" & LF);
               return 1;
         end;
      end;
   end Write;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      for Arg_Item of Args loop
         Complain (Env, Usage_Text);
         return (if Cli_Args.Is_Help (To_String (Arg_Item)) then 0 else 2);
      end loop;
      declare
         Ctx : constant Context.Maybe_Context := Context.Resolve (Env, Prog);
      begin
         if not Ctx.Found then
            return 1;
         end if;
         return Write (Env, Ctx.Value);
      end;
   end Run;

end Synapse.Commands.Project_Index;
