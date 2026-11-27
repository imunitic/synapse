with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Interactive_Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Commands.Loading;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.Check is

   use Ada.Strings.Unbounded;

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Check_Help);

   --  What the pipeline would run with, one step after another.
   function Describe
     (Item : Resolved.Pipeline; Pipeline_File : String) return String
   is
      LF     : constant Character := Character'Val (10);
      Result : Unbounded_String;
   begin
      Append
        (Result,
         "pipeline " & To_String (Item.Name) & "  " & Pipeline_File & LF);
      for S of Item.Steps loop
         Append
           (Result,
            "  step " & To_String (S.Name) & "  harness "
            & Harnesses.Name_Of (S.Harness) & LF);
         for O of S.Origins loop
            Append
              (Result,
               "    "
               & (case O.Kind is
                    when Resolved.System_Origin => "system ",
                    when Resolved.Agent_Origin  => "agent ",
                    when Resolved.Prompt_Origin => "prompt ")
               & To_String (O.Name) & "  " & To_String (O.File) & LF);
         end loop;
      end loop;
      return To_String (Result);
   end Describe;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Ok          : Boolean;
      Item        : Resolved.Pipeline;
      File        : Unbounded_String;
      Interactive : Boolean := False;
      Name        : Unbounded_String;
      Named       : Boolean := False;
   begin
      for Arg of Args loop
         if To_String (Arg) = "--interactive" then
            if Interactive then
               return Usage_Error (Env, Usage);
            end if;
            Interactive := True;
         elsif not Named then
            Name := Arg;
            Named := True;
         else
            return Usage_Error (Env, Usage);
         end if;
      end loop;
      if not Named then
         return Usage_Error (Env, Usage);
      end if;
      Loading.Load
        (Env, To_String (Name), Ok, Item, File, Advise => True);
      if not Ok then
         return 1;
      end if;
      if Interactive then
         declare
            Problems : constant Synapse.Core.Text_Lists.Vector :=
              Interactive_Harnesses.Problems (Item);
         begin
            for Problem of Problems loop
               Complain
                 (Env, To_String (Problem) & Character'Val (10));
            end loop;
            if not Problems.Is_Empty then
               return 1;
            end if;
         end;
      end if;
      Say (Env, Describe (Item, To_String (File)));
      return 0;
   end Run;

end Synapse.Pipeline.Commands.Check;
