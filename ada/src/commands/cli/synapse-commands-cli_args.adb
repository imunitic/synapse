with Synapse.Core.Command_Map;

package body Synapse.Commands.Cli_Args is

   procedure Take_Value
     (Args  :     Lists.Vector; Index : in out Positive;
      Value : out Ada.Strings.Unbounded.Unbounded_String; Found : out Boolean)
   is
   begin
      Value := Ada.Strings.Unbounded.Null_Unbounded_String;
      Found := False;
      if Index >= Positive (Args.Length) then
         return;
      end if;
      declare
         Next : constant Ada.Strings.Unbounded.Unbounded_String :=
           Args (Index + 1);
         Text : constant String := Ada.Strings.Unbounded.To_String (Next);
      begin
         Index := Index + 1;
         if Text'Length >= 2
           and then Text (Text'First .. Text'First + 1) = "--"
         then
            return;
         end if;
         Value := Next;
         Found := True;
      end;
   end Take_Value;

   procedure Print_Map_For (Env : Environment; Sub : String) is
      Map : constant String := Core.Command_Map.Render_For (Sub);
   begin
      if Map'Length /= 0 then
         Complain
           (Env, ASCII.LF & "Synapse commands by question:" & ASCII.LF & Map);
      end if;
   end Print_Map_For;

end Synapse.Commands.Cli_Args;
