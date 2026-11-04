with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Registry_Store;

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

   procedure Recorded_Brief
     (Env   : Environment;
      Work  : String;
      Id    : String;
      Found : out Boolean;
      Brief : out JSON.Value)
   is
      function Member (Key : String; Item : JSON.Value) return JSON.Member is
        (Key => To_Unbounded_String (Key), Item => Item);

      --  The member Key of Item, or null when it has none.
      function Of_Item (Item : JSON.Value; Key : String) return JSON.Value is
        (if JSON.Kind_Of (Item) = JSON.JSON_Object
           and then JSON.Has_Member (Item, Key)
         then JSON.Member_Value (Item, Key) else JSON.Null_Value);

      function Text_Or_Empty (Item : JSON.Value) return JSON.Value is
        (if JSON.Kind_Of (Item) = JSON.JSON_String then Item
         else JSON.Make_String (""));

      Held : Registry_Store.Maybe_Content;
   begin
      Found := False;
      Brief := JSON.Null_Value;
      Env.Registry.Open (Work);
      for Known of Env.Registry.Ids loop
         if To_String (Known) = Id then
            Found := True;
         end if;
      end loop;
      if not Found then
         return;
      end if;
      Held := Env.Registry.Read_Summary (Id);
      declare
         Parsed : constant JSON.Parse_Result :=
           (if Held.Found then JSON.Parse (To_String (Held.Value))
            else (Ok => False, others => <>));
      begin
         if not Parsed.Ok
           or else JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object
         then
            Brief :=
              JSON.Make_Object
                ([Member ("execution_id", JSON.Make_String (Id)),
                  Member ("pipeline", JSON.Make_String ("")),
                  Member ("status", JSON.Make_String ("incomplete")),
                  Member ("current_step", JSON.Make_String (""))]);
            return;
         end if;
         declare
            Summary : constant JSON.Value := Parsed.Item;
            State   : constant JSON.Value := Of_Item (Summary, "state");
            Status  : constant String :=
              (if JSON.Kind_Of (Of_Item (Summary, "status")) =
                  JSON.JSON_String
               then JSON.As_String (Of_Item (Summary, "status"))
               else "incomplete");
         begin
            Brief :=
              JSON.Make_Object
                ([Member ("execution_id", JSON.Make_String (Id)),
                  Member
                    ("pipeline",
                     Text_Or_Empty (Of_Item (Summary, "pipeline"))),
                  Member
                    ("status",
                     JSON.Make_String
                       (if Status = "running" then "interrupted"
                        else Status)),
                  Member
                    ("current_step",
                     Text_Or_Empty (Of_Item (Summary, "current_step"))),
                  Member ("steps_run", Of_Item (State, "steps_run")),
                  Member ("failure", Of_Item (State, "failure"))]);
         end;
      end;
   end Recorded_Brief;

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
