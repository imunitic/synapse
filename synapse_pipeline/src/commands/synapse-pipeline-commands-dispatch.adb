with Ada.Strings.Unbounded;

with Synapse.Pipeline.Commands.Check;
with Synapse.Pipeline.Commands.Info;
with Synapse.Pipeline.Commands.List;
with Synapse.Pipeline.Commands.Next;
with Synapse.Pipeline.Commands.Run;
with Synapse.Pipeline.Commands.Show;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.Dispatch is

   use Ada.Strings.Unbounded;

   function Help_For (Name : String) return String is
     (if Name = "check" then Usage.Check_Help
      elsif Name = "show" then Usage.Show_Help
      elsif Name = "next" then Usage.Next_Help
      elsif Name = "list" then Usage.List_Help
      elsif Name = "info" then Usage.Info_Help
      else Usage.Run_Help);

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Usage.Text);
      end if;
      declare
         Name : constant String := To_String (Args.First_Element);
      begin
         if Name in "check" | "show" | "next" | "list" | "info" | "run" then
            declare
               Rest : Lists.Vector := Args;
            begin
               Rest.Delete_First;
               if not Rest.Is_Empty
                 and then To_String (Rest.First_Element) in "--help" | "-h"
               then
                  Say (Env, Help_For (Name));
                  return 0;
               end if;
               return (if Name = "check" then Check.Run (Env, Rest)
                       elsif Name = "show"
                       then Synapse.Pipeline.Commands.Show.Run (Env, Rest)
                       elsif Name = "next"
                       then Synapse.Pipeline.Commands.Next.Run (Env, Rest)
                       elsif Name = "list"
                       then Synapse.Pipeline.Commands.List.Run (Env, Rest)
                       elsif Name = "info"
                       then Synapse.Pipeline.Commands.Info.Run (Env, Rest)
                       else Synapse.Pipeline.Commands.Run.Run (Env, Rest));
            end;
         elsif Name = "--help" or else Name = "-h" or else Name = "help" then
            Say (Env, Usage.Text);
            return 0;
         end if;
         Complain (Env, "synapse-pipeline: unknown subcommand '" & Name &
                        "'" & Usage.LF);
         return Usage_Error (Env, Usage.Text);
      end;
   end Run;

end Synapse.Pipeline.Commands.Dispatch;
