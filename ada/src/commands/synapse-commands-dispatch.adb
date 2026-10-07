with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
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

   Namespace_Name : aliased constant String := "namespace";
   Now_Name       : aliased constant String := "now";
   Context_Name   : aliased constant String := "context";

   Table : constant array (Positive range <>) of Entry_Type :=
     [(Namespace_Name'Access, Namespace.Run'Access),
     (Now_Name'Access, Now.Run'Access),
     (Context_Name'Access, Show_Context.Run'Access)];

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
