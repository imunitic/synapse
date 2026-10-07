with Ada.Directories;

with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Core.Node_Path;
with Synapse.Core.Node_Query;

package body Synapse.Commands.Frontmatter is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-frontmatter";
   LF   : constant Character := Character'Val (10);

   Max_Note_Bytes : constant := 256 * 1_024 * 1_024;

   function Parse_Set (Args : Lists.Vector) return Request is
      Positional : array (1 .. 3) of Unbounded_String;
      Count      : Natural   := 0;
      Flag       : Operation := Invalid;
      Tag        : Unbounded_String;
      I          : Positive  := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--add-tag" or else Arg = "--remove-tag" then
               if Flag /= Invalid or else I = Natural (Args.Length) then
                  return (others => <>);
               end if;
               Flag := (if Arg = "--add-tag" then Add_Tag else Remove_Tag);
               I    := I + 1;
               Tag  := Args (I);
            else
               if Count = Positional'Length then
                  return (others => <>);
               end if;
               Count              := Count + 1;
               Positional (Count) := Args (I);
            end if;
         end;
         I := I + 1;
      end loop;

      if Count = 0 then
         return (others => <>);
      end if;
      if Flag /= Invalid then
         return
           (if Count = 1 then
              (Flag, Positional (1), Null_Unbounded_String, Tag)
            else (others => <>));
      end if;
      return
        (if Count = 3 then
           (Set_Value, Positional (1), Positional (2), Positional (3))
         else (others => <>));
   end Parse_Set;

   function Parse (Args : Lists.Vector) return Request is
   begin
      if Args.Is_Empty then
         return (others => <>);
      end if;
      declare
         Sub  : constant String := To_String (Args (1));
         Rest : Lists.Vector    := Args;
      begin
         Rest.Delete_First;
         if Sub = "get" then
            if Natural (Rest.Length) /= 2 or else Length (Rest (1)) = 0
              or else Length (Rest (2)) = 0
            then
               return (others => <>);
            end if;
            return (Get, Rest (1), Rest (2), Null_Unbounded_String);
         elsif Sub = "set" then
            return Parse_Set (Rest);
         end if;
         return (others => <>);
      end;
   end Parse;

   --  The value of Key in the note at Path, nothing printed for an absent key.
   function Get (Env : Environment; Vault, Path, Key : String) return Exit_Code
   is
      Absolute : constant String := Vault & "/" & Path;
   begin
      if not Core.Node_Path.Is_Safe (Path) then
         Complain (Env, Prog & ": no such note: " & Path & LF);
         return 1;
      end if;
      if not Ada.Directories.Exists (Absolute) then
         Complain (Env, Prog & ": no such note: " & Path & LF);
         return 1;
      end if;
      declare
         Text  : constant String                     :=
           Adapters.File_Bytes.Read (Absolute, Max_Note_Bytes);
         Value : constant Core.Node_Query.Maybe_Text :=
           Core.Node_Query.Field (Text, Key);
      begin
         if Value.Found then
            Say (Env, To_String (Value.Value) & LF);
         end if;
         return 0;
      end;
   exception
      when others =>
         Complain (Env, Prog & ": read failed" & LF);
         return 1;
   end Get;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      for Arg of Args loop
         if Cli_Args.Is_Help (To_String (Arg)) then
            Complain (Env, Vault_Usage.Frontmatter);
            return 0;
         end if;
      end loop;
      declare
         Wanted : constant Request := Parse (Args);
         Vault  : Unbounded_String;
         Found  : Boolean;
      begin
         if Wanted.Op = Invalid then
            return Usage_Error (Env, Vault_Usage.Frontmatter);
         end if;
         Support.Find_Vault (Env, Prog, Vault, Found);
         if not Found then
            return 1;
         end if;
         case Wanted.Op is
            when Get =>
               return
                 Get
                   (Env, To_String (Vault), To_String (Wanted.Path),
                    To_String (Wanted.Key));
            when others =>
               Complain (Env, Prog & ": set is not available yet" & LF);
               return 1;
         end case;
      end;
   end Run;

end Synapse.Commands.Frontmatter;
