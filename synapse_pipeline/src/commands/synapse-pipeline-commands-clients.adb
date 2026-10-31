with Synapse.Pipeline.Configs;

package body Synapse.Pipeline.Commands.Clients is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   procedure Work_Directory
     (Env       : Environment;
      Directory : out Unbounded_String;
      Found     : out Boolean)
   is
      Settled : constant Configs.Config_Results.Result :=
        Configs.Resolve (Env.Vars.all, Env.Files.Current_Directory);
   begin
      Directory := Null_Unbounded_String;
      Found := False;
      if not Configs.Config_Results.Is_Success (Settled) then
         Complain
           (Env,
            "error: " & To_String (Configs.Config_Results.Error (Settled))
            & LF);
         return;
      end if;
      declare
         Settings : constant Configs.Config :=
           Configs.Config_Results.Value (Settled);
         Place    : constant Configs.Environment_Maps.Cursor :=
           Settings.Environment.Find (Configs.Work_Dir_Key);
      begin
         if not Configs.Environment_Maps.Has_Element (Place) then
            Complain
              (Env,
               "error: there is no work directory; set "
               & Configs.Work_Dir_Key & LF);
            return;
         end if;
         Directory :=
           To_Unbounded_String (Configs.Environment_Maps.Element (Place));
         Found := True;
      end;
   end Work_Directory;

   procedure Read_Answer
     (Text    : String;
      Ok      : out Boolean;
      Result  : out JSON.Value;
      Message : out Unbounded_String)
   is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Ok := False;
      Result := JSON.Null_Value;
      if not Parsed.Ok
        or else JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object
        or else not JSON.Has_Member (Parsed.Item, "ok")
        or else JSON.Kind_Of (JSON.Member_Value (Parsed.Item, "ok")) /=
                JSON.JSON_Boolean
      then
         Message :=
           To_Unbounded_String ("what answered is not a pipeline run");
      elsif JSON.As_Boolean (JSON.Member_Value (Parsed.Item, "ok"))
        and then JSON.Has_Member (Parsed.Item, "result")
      then
         Ok := True;
         Result := JSON.Member_Value (Parsed.Item, "result");
      elsif JSON.Has_Member (Parsed.Item, "error")
        and then JSON.Kind_Of (JSON.Member_Value (Parsed.Item, "error")) =
                 JSON.JSON_String
      then
         Message :=
           To_Unbounded_String
             (JSON.As_String (JSON.Member_Value (Parsed.Item, "error")));
      else
         Message := To_Unbounded_String ("the answer is not ok");
      end if;
   end Read_Answer;

end Synapse.Pipeline.Commands.Clients;
