with Ada.Strings.Unbounded;

with Synapse.Core.Frontmatter.Edit;
with Synapse.Core.Unicode.Transforms;

package body Synapse.Core.Wikilinks is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Is_Blank (C : Character) return Boolean
   is (C in ' ' | Character'Val (9) | Character'Val (13) | LF);

   function Trimmed (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then Is_Blank (S (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Blank (S (Last)) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trimmed;

   --  The position of Pattern in S at or after From, or 0.
   function Find (S, Pattern : String; From : Positive) return Natural is
   begin
      if S'Length < Pattern'Length then
         return 0;
      end if;
      for I in From .. S'Last - Pattern'Length + 1 loop
         if S (I .. I + Pattern'Length - 1) = Pattern then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   function Bar_In (Inner : String) return Natural is
   begin
      for I in Inner'Range loop
         if Inner (I) = '|' then
            return I;
         end if;
      end loop;
      return 0;
   end Bar_In;

   --  The part of Inner before a `|`, trimmed: a link's raw target.
   function Target_Of (Inner : String) return String is
      Bar : constant Natural := Bar_In (Inner);
   begin
      return
        Trimmed (if Bar = 0 then Inner else Inner (Inner'First .. Bar - 1));
   end Target_Of;

   function Extract (Body_Text : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      Pos    : Positive := Body_Text'First;
   begin
      loop
         exit when Body_Text'Length = 0;
         declare
            Start : constant Natural := Find (Body_Text, "[[", Pos);
         begin
            exit when Start = 0;
            declare
               Close : constant Natural :=
                 (if Start + 2 > Body_Text'Last then 0
                  else Find (Body_Text, "]]", Start + 2));
            begin
               exit when Close = 0;
               declare
                  Target : constant String :=
                    Target_Of (Body_Text (Start + 2 .. Close - 1));
               begin
                  if Target'Length > 0 then
                     Result.Append (To_Unbounded_String (Target));
                  end if;
               end;
               Pos := Close + 2;
               exit when Pos > Body_Text'Last;
            end;
         end;
      end loop;
      return Result;
   end Extract;

   --  The text of Target from its first `#`, or "".
   function Anchor_Of (Target : String) return String is
   begin
      for I in Target'Range loop
         if Target (I) = '#' then
            return Target (I .. Target'Last);
         end if;
      end loop;
      return "";
   end Anchor_Of;

   function Normalize_Target (Target : String) return String is
      Start : Natural := Target'First;
   begin
      for I in reverse Target'Range loop
         if Target (I) = '/' then
            Start := I + 1;
            exit;
         end if;
      end loop;
      declare
         Last : Natural := Target'Last;
      begin
         for I in Start .. Target'Last loop
            if Target (I) = '#' then
               Last := I - 1;
               exit;
            end if;
         end loop;
         if Last - Start + 1 >= 3 and then Target (Last - 2 .. Last) = ".md"
         then
            Last := Last - 3;
         end if;
         return Target (Start .. Last);
      end;
   end Normalize_Target;

   function Names_Same_Note (A, B : String) return Boolean is
   begin
      if A'Length = 0 then
         return False;
      end if;
      return
        Unicode.Transforms.Normalize_Key (Normalize_Target (A))
        = Unicode.Transforms.Normalize_Key (Normalize_Target (B));
   end Names_Same_Note;

   --  Calls Visit for every link of Body_Text, in order, with the text before
   --  it (from where the last link ended), the link's inner text and whether
   --  it was complete; the rest is appended by the caller.
   generic
      with
        procedure Link (Inner : String; Result : in out Unbounded_String);
   function Rewrite (Body_Text : String) return String;

   function Rewrite (Body_Text : String) return String is
      Result : Unbounded_String;
      Pos    : Positive := Body_Text'First;
   begin
      while Pos <= Body_Text'Last loop
         declare
            Start : constant Natural := Find (Body_Text, "[[", Pos);
         begin
            if Start = 0 then
               exit;
            end if;
            Append (Result, Body_Text (Pos .. Start - 1));
            declare
               Close : constant Natural :=
                 (if Start + 2 > Body_Text'Last then 0
                  else Find (Body_Text, "]]", Start + 2));
            begin
               if Close = 0 then
                  Append (Result, Body_Text (Start .. Body_Text'Last));
                  return To_String (Result);
               end if;
               Link (Body_Text (Start + 2 .. Close - 1), Result);
               Pos := Close + 2;
            end;
         end;
      end loop;
      if Pos <= Body_Text'Last then
         Append (Result, Body_Text (Pos .. Body_Text'Last));
      end if;
      return To_String (Result);
   end Rewrite;

   function Rename_Target
     (Body_Text, Old_Target, New_Target : String) return String
   is
      procedure Link (Inner : String; Result : in out Unbounded_String) is
         Bar    : constant Natural := Bar_In (Inner);
         Target : constant String := Target_Of (Inner);
      begin
         if Names_Same_Note (Target, Old_Target) then
            Append (Result, "[[" & New_Target & Anchor_Of (Target));
            if Bar > 0 then
               Append (Result, Inner (Bar .. Inner'Last));
            end if;
            Append (Result, "]]");
         else
            Append (Result, "[[" & Inner & "]]");
         end if;
      end Link;

      function Run is new Rewrite (Link);
   begin
      return Run (Body_Text);
   end Rename_Target;

   function Unlink_Target (Body_Text, Old_Target : String) return String is
      procedure Link (Inner : String; Result : in out Unbounded_String) is
         Bar    : constant Natural := Bar_In (Inner);
         Target : constant String := Target_Of (Inner);
      begin
         if Names_Same_Note (Target, Old_Target) then
            if Bar > 0 then
               Append (Result, Trimmed (Inner (Bar + 1 .. Inner'Last)));
            else
               Append (Result, Normalize_Target (Target));
            end if;
         else
            Append (Result, "[[" & Inner & "]]");
         end if;
      end Link;

      function Run is new Rewrite (Link);
   begin
      return Run (Body_Text);
   end Unlink_Target;

   function Title_Of (Path : String) return String is
      Start : Natural := Path'First;
      Last  : Natural := Path'Last;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Start := I + 1;
            exit;
         end if;
      end loop;
      if Last - Start + 1 >= 3 and then Path (Last - 2 .. Last) = ".md" then
         Last := Last - 3;
      end if;
      return Path (Start .. Last);
   end Title_Of;

   function Rename_Heading
     (Note, Old_Title, New_Title : String) return String
   is
      Pos : Positive := Note'First;
   begin
      while Pos <= Note'Last loop
         declare
            Stop : Natural := Note'Last + 1;
         begin
            for I in Pos .. Note'Last loop
               if Note (I) = LF then
                  Stop := I;
                  exit;
               end if;
            end loop;
            if Stop - Pos >= 2 and then Note (Pos .. Pos + 1) = "# "
              and then Note (Pos + 2 .. Stop - 1) = Old_Title
            then
               return Note (Note'First .. Pos - 1) & "# " & New_Title
                 & Note (Stop .. Note'Last);
            end if;
            Pos := Stop + 1;
         end;
      end loop;
      return Note;
   end Rename_Heading;

   function With_Title (Note, New_Title : String) return String is
   begin
      return Frontmatter.Edit.Set_Scalar (Note, "title", New_Title);
   exception
      when Frontmatter.Edit.No_Frontmatter =>
         return Note;
   end With_Title;

   function Sync_Title_And_Heading
     (Note, Old_Title, New_Title : String) return String
   is (Rename_Heading (With_Title (Note, New_Title), Old_Title, New_Title));

end Synapse.Core.Wikilinks;
