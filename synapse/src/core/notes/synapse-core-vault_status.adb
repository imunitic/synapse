with Ada.Strings.Fixed;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Core.Vault_Query;

package body Synapse.Core.Vault_Status is

   package JSON renames Synapse.Core.JSON;
   package Query renames Synapse.Core.Vault_Query;

   use type JSON.Kind;
   use type JSON.Member_Array;

   LF : constant Character := Character'Val (10);

   function Key (What : Category) return String is
     (case What is
        when Discussing       => "discussing",
        when Ready_Uncompiled => "ready_uncompiled",
        when Open_Questions   => "open_questions",
        when In_Progress      => "in_progress",
        when Awaiting_Review  => "awaiting_review");

   function Heading (What : Category) return String is
     (case What is
        when Discussing       => "Discussing",
        when Ready_Uncompiled => "Ready, not yet compiled",
        when Open_Questions   => "Open questions",
        when In_Progress      => "In progress (unchecked items)",
        when Awaiting_Review  => "Awaiting review");

   -------------------------------------------------------------------------
   --  Reading a note's text
   -------------------------------------------------------------------------

   function Trimmed (Text : String) return String is
     (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Compiled_Task (Content : String) return String is
      Marker : constant String := "Compiled task:";
      Start  : constant Natural := Ada.Strings.Fixed.Index (Content, Marker);
   begin
      if Start = 0 then
         return "";
      end if;
      declare
         Open : constant Natural :=
           Ada.Strings.Fixed.Index (Content, "[[", Start + Marker'Length);
      begin
         if Open = 0 then
            return "";
         end if;
         declare
            Close : constant Natural :=
              Ada.Strings.Fixed.Index (Content, "]]", Open + 2);
         begin
            if Close = 0 then
               return "";
            end if;
            declare
               Target : constant String := Content (Open + 2 .. Close - 1);
               Cut    : Natural := Target'Last + 1;
            begin
               for I in Target'Range loop
                  if Target (I) in '|' | '#' then
                     Cut := I;
                     exit;
                  end if;
               end loop;
               return Trimmed (Target (Target'First .. Cut - 1));
            end;
         end;
      end;
   end Compiled_Task;

   function Unchecked_Count (Content : String) return Natural is
      Count : Natural := 0;
      Start : Positive := Content'First;
   begin
      if Content = "" then
         return 0;
      end if;
      for I in Content'First .. Content'Last + 1 loop
         if I > Content'Last or else Content (I) = LF then
            declare
               Line  : constant String := Content (Start .. I - 1);
               First : Natural := Line'First;
            begin
               while First <= Line'Last and then Line (First) in ' ' | ASCII.HT
               loop
                  First := First + 1;
               end loop;
               if Line'Last - First + 1 >= 5
                 and then Line (First .. First + 4) = "- [ ]"
               then
                  Count := Count + 1;
               end if;
            end;
            Start := I + 1;
         end if;
      end loop;
      return Count;
   end Unchecked_Count;

   -------------------------------------------------------------------------
   --  Querying
   -------------------------------------------------------------------------

   function Fields (A, B : String; C : String := "")
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String (A));
      Result.Append (To_Unbounded_String (B));
      if C /= "" then
         Result.Append (To_Unbounded_String (C));
      end if;
      return Result;
   end Fields;

   function Rule (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      return Parsed.Item;
   end Rule;

   function Text_Of (V : JSON.Value) return String is
     (if JSON.Kind_Of (V) = JSON.JSON_String then JSON.As_String (V) else "");

   function Value_At (Found : Query.Row; Index : Positive) return JSON.Value is
     (Found.Values (Index));

   function Item_Of (Found : Query.Row) return Item is
     (Path  => Found.Path,
      Title => To_Unbounded_String (Text_Of (Value_At (Found, 1))),
      Id    => To_Unbounded_String (Text_Of (Value_At (Found, 2))),
      others => <>);

   --  A design note of the folder, as the first part of every rule.
   Designs : constant String := "{""glob"":[""designs/*"",{""var"":""path""}]}";
   Tasks   : constant String := "{""glob"":[""tasks/*"",{""var"":""path""}]}";

   --  `\n` is a JSON escape: a pattern holds a line break.
   function Discussing_Rule return String is
     ("{""and"":[" & Designs & ",{""regexp"":[""## Status\nDiscussing"","
      & "{""var"":""content""}]}]}");

   function Uncompiled_Rule return String is
     ("{""and"":[" & Designs & ",{""regexp"":[""## Status\nReady"","
      & "{""var"":""content""}]},{""!"":[{""regexp"":[""Compiled task:"","
      & "{""var"":""content""}]}]}]}");

   function Questions_Rule return String is
     ("{""and"":[" & Designs & ",{""regexp"":[""## Status\nReady"","
      & "{""var"":""content""}]},{""regexp"":[""## Open Questions\n- "","
      & "{""var"":""content""}]}]}");

   function Open_Tasks_Rule return String is
     ("{""and"":[" & Tasks & ",{""in"":[{""var"":""frontmatter.status""},"
      & "[""TODO"",""IN-PROGRESS""]]}]}");

   function Review_Rule return String is
     ("{""and"":[" & Tasks & ",{""=="":[{""var"":""frontmatter.status""},"
      & """REVIEW""]}]}");

   --  The titles among Titles of tasks whose status is DONE.
   function Done_Titles
     (Source : in out Synapse.Ports.Store.Store'Class;
      Titles : Synapse.Core.Text_Lists.Vector)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      List   : Unbounded_String;
   begin
      if Titles.Is_Empty then
         return Result;
      end if;
      for Title of Titles loop
         if Length (List) > 0 then
            Append (List, ",");
         end if;
         Append (List, JSON.To_String (JSON.Make_String (To_String (Title))));
      end loop;
      declare
         Rows : constant Query.Row_Vectors.Vector :=
           Query.Query
             (Source,
              Rule
                ("{""and"":[" & Tasks & ",{""in"":[{""var"":"
                 & """frontmatter.title""},[" & To_String (List) & "]]}]}"),
              Fields ("frontmatter.title", "frontmatter.status"));
      begin
         for Found of Rows loop
            if Text_Of (Value_At (Found, 2)) = "DONE" then
               Result.Append (To_Unbounded_String (Text_Of (Value_At (Found, 1))));
            end if;
         end loop;
      end;
      return Result;
   end Done_Titles;

   function Build (Source : in out Synapse.Ports.Store.Store'Class)
      return Report
   is
      Result : Report;
   begin
      for Found of Query.Query
        (Source, Rule (Discussing_Rule),
         Fields ("frontmatter.title", "frontmatter.note_id"))
      loop
         Result (Discussing).Append (Item_Of (Found));
      end loop;

      for Found of Query.Query
        (Source, Rule (Uncompiled_Rule),
         Fields ("frontmatter.title", "frontmatter.note_id"))
      loop
         Result (Ready_Uncompiled).Append (Item_Of (Found));
      end loop;

      declare
         Rows     : constant Query.Row_Vectors.Vector :=
           Query.Query
             (Source, Rule (Questions_Rule),
              Fields ("frontmatter.title", "frontmatter.note_id", "content"));
         Compiled : Synapse.Core.Text_Lists.Vector;
      begin
         for Found of Rows loop
            declare
               Target : constant String :=
                 Compiled_Task (Text_Of (Value_At (Found, 3)));
            begin
               if Target /= "" and then not Compiled.Contains
                 (To_Unbounded_String (Target))
               then
                  Compiled.Append (To_Unbounded_String (Target));
               end if;
            end;
         end loop;
         declare
            Done : constant Synapse.Core.Text_Lists.Vector :=
              Done_Titles (Source, Compiled);
         begin
            for Found of Rows loop
               declare
                  Target : constant String :=
                    Compiled_Task (Text_Of (Value_At (Found, 3)));
                  Entry_Of : Item := Item_Of (Found);
               begin
                  Entry_Of.Compiled := To_Unbounded_String (Target);
                  if Target = ""
                    or else not Done.Contains (To_Unbounded_String (Target))
                  then
                     Result (Open_Questions).Append (Entry_Of);
                  end if;
               end;
            end loop;
         end;
      end;

      for Found of Query.Query
        (Source, Rule (Open_Tasks_Rule),
         Fields ("frontmatter.title", "frontmatter.task_id", "content"))
      loop
         declare
            Entry_Of : Item := Item_Of (Found);
         begin
            Entry_Of.Unchecked := Unchecked_Count (Text_Of (Value_At (Found, 3)));
            Result (In_Progress).Append (Entry_Of);
         end;
      end loop;

      for Found of Query.Query
        (Source, Rule (Review_Rule),
         Fields ("frontmatter.title", "frontmatter.task_id"))
      loop
         Result (Awaiting_Review).Append (Item_Of (Found));
      end loop;
      return Result;
   end Build;

   -------------------------------------------------------------------------
   --  Output
   -------------------------------------------------------------------------

   function Is_Clear (Found : Report) return Boolean is
     (for all What in Category => Found (What).Is_Empty);

   function Image (N : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left));

   function Line (What : Category; Entry_Of : Item) return String is
      Lead : constant String :=
        (if Length (Entry_Of.Id) > 0 then "[" & To_String (Entry_Of.Id) & "] "
         else "");
      Title : constant String := To_String (Entry_Of.Title);
   begin
      return
        "- " & Lead & Title
        & (case What is
             when Open_Questions =>
               " " & Character'Val (16#E2#) & Character'Val (16#80#)
               & Character'Val (16#94#) & " "
               & (if Length (Entry_Of.Compiled) > 0
                  then To_String (Entry_Of.Compiled) else "not compiled"),
             when In_Progress => " (" & Image (Entry_Of.Unchecked) & " unchecked)",
             when others => "")
        & LF;
   end Line;

   function To_Text (Found : Report) return String is
      Text : Unbounded_String;
   begin
      if Is_Clear (Found) then
         return "Vault is clear -- nothing outstanding." & LF;
      end if;
      for What in Category loop
         if not Found (What).Is_Empty then
            if Length (Text) > 0 then
               Append (Text, LF);
            end if;
            Append (Text, "## " & Heading (What) & LF);
            for Entry_Of of Found (What) loop
               Append (Text, Line (What, Entry_Of));
            end loop;
         end if;
      end loop;
      return To_String (Text);
   end To_Text;

   function Member (Name : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Name), Item => Item);

   function Text_Or_Null (Text : Unbounded_String) return JSON.Value is
     (if Length (Text) = 0 then JSON.Null_Value
      else JSON.Make_String (To_String (Text)));

   function To_JSON (Found : Report; Vault : String) return String is
      Categories : JSON.Value_Array (1 .. Category'Pos (Category'Last) + 1);
   begin
      for What in Category loop
         declare
            Items : JSON.Value_Array (1 .. Natural (Found (What).Length));
         begin
            for I in Items'Range loop
               declare
                  Entry_Of : constant Item := Found (What) (I);
                  Base     : constant JSON.Member_Array :=
                    [Member ("path", JSON.Make_String (To_String (Entry_Of.Path))),
                     Member ("id", Text_Or_Null (Entry_Of.Id)),
                     Member ("title", JSON.Make_String (To_String (Entry_Of.Title)))];
               begin
                  Items (I) :=
                    (case What is
                       when Open_Questions =>
                         JSON.Make_Object
                           (Base
                            & JSON.Member_Array'
                                [Member
                                   ("compiled_task",
                                    Text_Or_Null (Entry_Of.Compiled))]),
                       when In_Progress =>
                         JSON.Make_Object
                           (Base
                            & JSON.Member_Array'
                                [Member
                                   ("unchecked",
                                    JSON.Make_Integer
                                      (Long_Long_Integer
                                         (Entry_Of.Unchecked)))]),
                       when others => JSON.Make_Object (Base));
               end;
            end loop;
            Categories (Category'Pos (What) + 1) :=
              JSON.Make_Object
                ([Member ("key", JSON.Make_String (Key (What))),
                  Member ("title", JSON.Make_String (Heading (What))),
                  Member ("items", JSON.Make_Array (Items))]);
         end;
      end loop;
      return JSON.To_String
        (JSON.Make_Object
           ([Member ("format", JSON.Make_String ("synapse-status/v1")),
             Member ("vault", JSON.Make_String (Vault)),
             Member ("clear", JSON.Make_Boolean (Is_Clear (Found))),
             Member ("categories", JSON.Make_Array (Categories))]));
   end To_JSON;

end Synapse.Core.Vault_Status;
