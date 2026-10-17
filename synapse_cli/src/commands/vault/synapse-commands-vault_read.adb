with Ada.Strings.Unbounded;

with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Core.Patch;
with Synapse.Ports.Store;

package body Synapse.Commands.Vault_Read is

   use Ada.Strings.Unbounded;

   package Port renames Synapse.Ports.Store;
   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-vault";
   LF   : constant Character := Character'Val (10);

   --  The text of Path, or false after saying why not.
   procedure Fetch
     (Env  : Environment; Stack : in out Support.Store_Resolve.Stack;
      Path : String; Text : out Unbounded_String; Found : out Boolean)
   is
   begin
      Text  := Null_Unbounded_String;
      Found := False;
      declare
         Got : constant Port.Maybe_Text :=
           Support.Store_Resolve.Store (Stack).Read (Path);
      begin
         if Got.Found then
            Text  := Got.Value;
            Found := True;
         else
            Complain (Env, Prog & ": no such note: " & Path & LF);
         end if;
      end;
   exception
      when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
         Complain (Env, Prog & ": read failed" & LF);
   end Fetch;

   function Run_Read (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Path  : Unbounded_String;
      Done  : Boolean;
      Code  : Exit_Code;
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
      Text  : Unbounded_String;
   begin
      Support.One_Path (Env, Args, Vault_Usage.Read, Path, Done, Code);
      if Done then
         return Code;
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      Fetch (Env, Stack, To_String (Path), Text, Found);
      if not Found then
         return 1;
      end if;
      Say (Env, To_String (Text));
      return 0;
   end Run_Read;

   function Run_List (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
   begin
      if not Args.Is_Empty then
         return
           Support.Help_Or_Usage (Env, To_String (Args (1)), Vault_Usage.List);
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      declare
         Names    : constant Lists.Vector :=
           Support.Store_Resolve.Store (Stack).List;
         Out_Text : Unbounded_String;
      begin
         for Name of Names loop
            Append (Out_Text, Name);
            Append (Out_Text, LF);
         end loop;
         Say (Env, To_String (Out_Text));
         return 0;
      end;
   exception
      when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
         Complain (Env, Prog & ": list failed" & LF);
         return 1;
   end Run_List;

   function Run_Doc_Map
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Path  : Unbounded_String;
      Done  : Boolean;
      Code  : Exit_Code;
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
      Text  : Unbounded_String;
   begin
      Support.One_Path (Env, Args, Vault_Usage.Doc_Map, Path, Done, Code);
      if Done then
         return Code;
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      Fetch (Env, Stack, To_String (Path), Text, Found);
      if not Found then
         return 1;
      end if;
      declare
         Map      : constant Core.Patch.Document_Map :=
           Core.Patch.Map_Of (To_String (Text));
         Out_Text : Unbounded_String;
      begin
         for H of Map.Headings loop
            Append (Out_Text, "heading" & ASCII.HT & To_String (H) & LF);
         end loop;
         for B of Map.Blocks loop
            Append (Out_Text, "block" & ASCII.HT & To_String (B) & LF);
         end loop;
         for K of Map.Frontmatter_Keys loop
            Append (Out_Text, "frontmatter" & ASCII.HT & To_String (K) & LF);
         end loop;
         Say (Env, To_String (Out_Text));
         return 0;
      end;
   end Run_Doc_Map;

end Synapse.Commands.Vault_Read;
