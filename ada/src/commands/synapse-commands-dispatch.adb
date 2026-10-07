with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Frontmatter;
with Synapse.Commands.Vault_Check;
with Synapse.Commands.Vault_Links;
with Synapse.Commands.Vault_Read;
with Synapse.Commands.Vault_Search;
with Synapse.Commands.Vault_Write;
with Synapse.Commands.Namespace;
with Synapse.Commands.Now;
with Synapse.Commands.Show_Context;
with Synapse.Commands.Usage;

package body Synapse.Commands.Dispatch is

   use Ada.Strings.Unbounded;

   type Name_Access is access constant String;

   type Entry_Type is record
      Name : Name_Access;
      Run  : Run_Access;
   end record;

   Namespace_Name         : aliased constant String := "namespace";
   Now_Name               : aliased constant String := "now";
   Context_Name           : aliased constant String := "context";
   Vault_Read_Name        : aliased constant String := "vault-read";
   Vault_List_Name        : aliased constant String := "vault-list";
   Vault_Check_Name       : aliased constant String := "vault-check";
   Vault_Search_Name      : aliased constant String := "vault-search";
   Vault_Search_Text_Name : aliased constant String := "vault-search-text";
   Vault_Doc_Map_Name     : aliased constant String := "vault-doc-map";
   Vault_Backlinks_Name   : aliased constant String := "vault-backlinks";
   Vault_Links_Name       : aliased constant String := "vault-links";
   Vault_Unresolved_Name  : aliased constant String := "vault-unresolved";
   Vault_Orphans_Name     : aliased constant String := "vault-orphans";
   Vault_Deadends_Name    : aliased constant String := "vault-deadends";
   Vault_Ambiguous_Name   : aliased constant String := "vault-ambiguous";
   Vault_Write_Name       : aliased constant String := "vault-write";
   Vault_Patch_Name       : aliased constant String := "vault-patch";
   Vault_Rename_Name      : aliased constant String := "vault-rename";
   Vault_Delete_Name      : aliased constant String := "vault-delete";
   Vault_Git_Pusher_Name  : aliased constant String := "vault-git-pusher";
   Frontmatter_Name       : aliased constant String := "frontmatter";

   Table : constant array (Positive range <>) of Entry_Type :=
     [(Namespace_Name'Access, Namespace.Run'Access),
     (Now_Name'Access, Now.Run'Access),
     (Context_Name'Access, Show_Context.Run'Access),
     (Vault_Read_Name'Access, Vault_Read.Run_Read'Access),
     (Vault_List_Name'Access, Vault_Read.Run_List'Access),
     (Vault_Check_Name'Access, Vault_Check.Run'Access),
     (Vault_Search_Name'Access, Vault_Search.Run_Search'Access),
     (Vault_Search_Text_Name'Access, Vault_Search.Run_Search_Text'Access),
     (Vault_Doc_Map_Name'Access, Vault_Read.Run_Doc_Map'Access),
     (Vault_Backlinks_Name'Access, Vault_Links.Run_Backlinks'Access),
     (Vault_Links_Name'Access, Vault_Links.Run_Links'Access),
     (Vault_Unresolved_Name'Access, Vault_Links.Run_Unresolved'Access),
     (Vault_Orphans_Name'Access, Vault_Links.Run_Orphans'Access),
     (Vault_Deadends_Name'Access, Vault_Links.Run_Deadends'Access),
     (Vault_Ambiguous_Name'Access, Vault_Links.Run_Ambiguous'Access),
     (Frontmatter_Name'Access, Frontmatter.Run'Access),
     (Vault_Write_Name'Access, Vault_Write.Run_Write'Access),
     (Vault_Patch_Name'Access, Vault_Write.Run_Patch'Access),
     (Vault_Rename_Name'Access, Vault_Write.Run_Rename'Access),
     (Vault_Delete_Name'Access, Vault_Write.Run_Delete'Access),
     (Vault_Git_Pusher_Name'Access, Vault_Write.Run_Git_Pusher'Access)];

   function Find (Name : String) return Run_Access is
   begin
      for Item of Table loop
         if Item.Name.all = Name then
            return Item.Run;
         end if;
      end loop;
      return null;
   end Find;

   function Count return Natural is (Table'Length);

   function Name_Of (Index : Positive) return String is
     (Table (Table'First + Index - 1).Name.all);

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         Complain (Env, Usage.Text);
         return 2;
      end if;
      declare
         Sub  : constant String := To_String (Args (1));
         Rest : Lists.Vector    := Args;
      begin
         if Cli_Args.Is_Help (Sub) then
            Complain (Env, Usage.Text);
            return 0;
         end if;
         declare
            Command : constant Run_Access := Find (Sub);
         begin
            if Command = null then
               Complain
                 (Env,
                  "synapse: unknown subcommand '" & Sub & "'" & ASCII.LF &
                  Usage.Text);
               return 2;
            end if;
            Rest.Delete_First;
            return Command (Env, Rest);
         end;
      end;
   end Run;

end Synapse.Commands.Dispatch;
