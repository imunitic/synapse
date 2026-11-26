with Ada.Strings.Unbounded;

with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Registry_Store;

package body Synapse.Pipeline.Commands.Name is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Name_Help);

   --  Whether the work directory holds the execution Id.
   function Is_Known (Env : Environment; Id : String) return Boolean is
   begin
      if not Registry_Store.Is_Plain_Name (Id) then
         return False;
      end if;
      for Held of Env.Registry.Ids loop
         if To_String (Held) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Is_Known;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty or else Natural (Args.Length) > 2 then
         return Usage_Error (Env, Usage);
      end if;
      declare
         Id   : constant String := To_String (Args.First_Element);
         Text : constant String :=
           (if Natural (Args.Length) = 2 then To_String (Args.Last_Element)
            else "");
         Work  : Unbounded_String;
         Found : Boolean;
      begin
         if Natural (Args.Length) = 2
           and then not Registry_Store.Is_Run_Name (Text)
         then
            Complain
              (Env,
               "error: a name must be one line of 1 to 120 characters, not "
               & "only spaces" & LF);
            return Usage_Error (Env, Usage);
         end if;
         Clients.Work_Directory (Env, Work, Found);
         if not Found then
            return 1;
         end if;
         Env.Registry.Open (To_String (Work));
         if not Is_Known (Env, Id) then
            Complain (Env, "error: no execution " & Id & LF);
            return 1;
         end if;
         if not Env.Registry.Replace_Name (Id, Text) then
            Complain (Env, "error: cannot name " & Id & LF);
            return 1;
         end if;
         return 0;
      end;
   end Run;

end Synapse.Pipeline.Commands.Name;
