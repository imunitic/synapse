package body Synapse.Pipeline.Fake_Terminal is

   use Ada.Strings.Unbounded;

   overriding
   function Start
     (T       : in out Fake_Terminal;
      Request : Session_Process.Process_Request)
      return Terminal_Process.Launch is
   begin
      T.Requests.Append (Request);
      if Length (T.Refusal) > 0 then
         return (Started => False, Problem => T.Refusal);
      end if;
      return (Started => True, Id => 1);
   end Start;

   overriding
   function Look
     (T  : in out Fake_Terminal;
      Id : Terminal_Process.Handle) return Terminal_Process.Progress
   is
      pragma Unreferenced (Id);
   begin
      T.Looks := T.Looks + 1;
      if T.Stopped then
         return (Running => False, Exit_Code => 143);
      end if;
      if T.Looks > Natural (T.Ticks.Length) then
         return (Running => True);
      end if;
      declare
         Now  : constant Tick := T.Ticks (T.Looks);
         Path : constant String := To_String (Now.Path);
      begin
         if Path /= "" and then T.Files /= null then
            T.Files.Add_File
              (Path,
               (if T.Files.Files.Contains (Path)
                then T.Files.Files.Element (Path) else "")
               & To_String (Now.Text));
         end if;
         if Now.Ends then
            return (Running => False, Exit_Code => Now.Code);
         end if;
         return (Running => True);
      end;
   end Look;

   overriding
   procedure Stop
     (T  : in out Fake_Terminal;
      Id : Terminal_Process.Handle)
   is
      pragma Unreferenced (Id);
   begin
      T.Stopped := True;
   end Stop;

end Synapse.Pipeline.Fake_Terminal;
