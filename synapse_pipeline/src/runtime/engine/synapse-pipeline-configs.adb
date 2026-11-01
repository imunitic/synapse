with Synapse.Adapters.Conf_Files;
with Synapse.Pipeline.Durations;

package body Synapse.Pipeline.Configs is

   use Ada.Strings.Unbounded;
   function Setting
     (V : Synapse.Ports.Variables.Variables'Class; Name : String) return String
   is
      Found : constant Synapse.Ports.Variables.Maybe_Value := V.Get (Name);
   begin
      return (if Found.Found then To_String (Found.Value) else "");
   end Setting;

   --  A positive whole number written in decimal, or 0.
   function Positive_Of (Text : String) return Natural is
      Value : Natural := 0;
   begin
      if Text'Length = 0 or else Text'Length > 9 then
         return 0;
      end if;
      for C of Text loop
         if C not in '0' .. '9' then
            return 0;
         end if;
         Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Value;
   end Positive_Of;

   function Resolve
     (V : Synapse.Ports.Variables.Variables'Class; Working_Directory : String)
      return Config_Results.Result
   is
      Result : Config;

      function Fail (Message : String) return Config_Results.Result is
        (Config_Results.Failure (To_Unbounded_String (Message)));

      --  Gives sessions the setting Key has, from the variable or else the
      --  configuration files.
      procedure Capture (Key : String) is
         Found : constant Synapse.Adapters.Conf_Files.Maybe_Path :=
           Synapse.Adapters.Conf_Files.Resolve (V, Key);
      begin
         if Found.Found and then Length (Found.Value) > 0 then
            Result.Environment.Include (Key, To_String (Found.Value));
         end if;
      end Capture;
   begin
      Result.Working_Directory := To_Unbounded_String (Working_Directory);

      declare
         Default : constant Harnesses.Default_Results.Result :=
           Harnesses.Default (V);
      begin
         if not Harnesses.Default_Results.Is_Success (Default) then
            return Config_Results.Failure
              (Harnesses.Default_Results.Error (Default));
         end if;
         Result.Default_Harness := Harnesses.Default_Results.Value (Default);
      end;

      declare
         Text : constant String := Setting (V, Timeout_Variable);
      begin
         if Text /= "" then
            if Durations.Seconds (Text) = 0 then
               return Fail
                 (Timeout_Variable & " is '" & Text
                  & "', which is not a duration such as 30m");
            end if;
            Result.Default_Timeout_Seconds := Durations.Seconds (Text);
         end if;
      end;

      declare
         Text : constant String := Setting (V, Ceiling_Variable);
      begin
         if Text /= "" then
            if Positive_Of (Text) = 0 then
               return Fail
                 (Ceiling_Variable & " is '" & Text
                  & "', which is not a whole number above zero");
            end if;
            Result.Step_Ceiling := Positive_Of (Text);
         end if;
      end;

      declare
         Text   : constant String := Setting (V, Runner_Variable);
         Script : constant String := Setting (V, Script_Variable);
      begin
         if Text = "" or else Text = "process" then
            Result.Runner := Process_Runner;
         elsif Text = "scripted" then
            Result.Runner := Scripted_Runner;
            if Script = "" then
               return Fail
                 (Runner_Variable & " is scripted, but " & Script_Variable
                  & " names no file");
            end if;
         else
            return Fail
              (Runner_Variable & " is '" & Text
               & "', which is not 'process' or 'scripted'");
         end if;
         Result.Script := To_Unbounded_String (Script);
      end;

      Capture (Vault_Dir_Key);
      Capture (Work_Dir_Key);
      Capture (Content_Root_Key);
      return Config_Results.Success (Result);
   end Resolve;

end Synapse.Pipeline.Configs;
