with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Text_Lists;

package body Synapse.Pipeline.Registry_Contract is

   use AUnit.Assertions;
   use type Registry_Store.Create_Result;

   LF : constant Character := Character'Val (10);

   function Text_Of (Item : Registry_Store.Maybe_Content) return String is
     (if Item.Found
      then Ada.Strings.Unbounded.To_String (Item.Value)
      else "<none>");

   function Has_Id
     (S : Registry_Store.Store'Class; Id : String) return Boolean is
   begin
      for Held of S.Ids loop
         if Ada.Strings.Unbounded.To_String (Held) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Has_Id;

   --  Whether the store turns the path of a definition away.
   function Refuses
     (S : in out Registry_Store.Store'Class; Id, Path : String) return Boolean
   is (not S.Write_Definition (Id, Path, "x"));

   procedure Check
     (S      : in out Registry_Store.Store'Class;
      Prefix : String)
   is
      A : constant String := Prefix & "-a";
      B : constant String := Prefix & "-b";
   begin
      Assert (S.Create (A) = Registry_Store.Created, "a new id is created");
      Assert
        (S.Create (A) = Registry_Store.Already_Exists,
         "a taken id is reported as taken");
      Assert (Has_Id (S, A), "the execution is listed");
      Assert (not Has_Id (S, B), "an execution not made is not listed");

      Assert
        (not S.Read_Summary (A).Found and then not S.Last_Write (A).Found,
         "a fresh execution has no summary");
      Assert (not S.Read_Events (A).Found, "and no events");
      Assert (S.Transcript_Names (A).Is_Empty, "and no transcripts");

      Assert (S.Replace_Summary (A, "one"), "a summary is written");
      Assert (Text_Of (S.Read_Summary (A)) = "one", "and read back");
      Assert (S.Last_Write (A).Found, "its write time is known");
      Assert (S.Replace_Summary (A, "two"), "a summary is replaced");
      Assert
        (Text_Of (S.Read_Summary (A)) = "two",
         "the new summary is all there is: " & Text_Of (S.Read_Summary (A)));

      Assert (S.Append_Event (A, "e1"), "an event is appended");
      Assert (S.Append_Event (A, "e2"), "and another");
      Assert
        (Text_Of (S.Read_Events (A)) = "e1" & LF & "e2" & LF,
         "the events are in order, each ended by a line break");

      Assert
        (S.Write_Transcript (A, "Review-1.jsonl", "r1"),
         "a transcript is written");
      Assert (S.Write_Transcript (A, "Develop-1.jsonl", "d1"), "and another");
      Assert
        (S.Write_Transcript (A, "Review-1.jsonl", "r1 again"),
         "a transcript of the same name is replaced");
      declare
         Names : constant Synapse.Core.Text_Lists.Vector :=
           S.Transcript_Names (A);
      begin
         Assert
           (Natural (Names.Length) = 2
            and then Ada.Strings.Unbounded.To_String (Names.First_Element) =
                     "Develop-1.jsonl"
            and then Ada.Strings.Unbounded.To_String (Names.Last_Element) =
                     "Review-1.jsonl",
            "the transcripts are listed in alphabetical order");
      end;

      Assert
        (not S.Read_Description (A).Found,
         "a fresh execution has no description");
      Assert (S.Write_Description (A, "d1"), "a description is written");
      Assert (S.Write_Description (A, "d2"), "a description is replaced");
      Assert
        (Text_Of (S.Read_Description (A)) = "d2",
         "the new description is all there is: "
         & Text_Of (S.Read_Description (A)));

      Assert
        (not S.Read_Definition (A, "synapse-pipeline/P.synapse").Found,
         "a fresh execution has no definitions");
      Assert
        (S.Write_Definition (A, "synapse-pipeline/P.synapse", "p1"),
         "a definition is written");
      Assert
        (S.Write_Definition (A, "synapse-pipeline/skills/s/SKILL.md", "k"),
         "one in a directory of its own is written");
      Assert
        (S.Write_Definition (A, "synapse-pipeline/P.synapse", "p2"),
         "a definition is replaced");
      Assert
        (Text_Of (S.Read_Definition (A, "synapse-pipeline/P.synapse")) = "p2"
         and then Text_Of
                    (S.Read_Definition
                       (A, "synapse-pipeline/skills/s/SKILL.md")) = "k",
         "each definition is read back by its path");
      Assert
        (not S.Read_Definition (A, "synapse-pipeline/Q.synapse").Found,
         "and one that was not written is not there");
      Assert
        (Refuses (S, A, "../x") and then Refuses (S, A, "/x")
         and then Refuses (S, A, "a//b") and then Refuses (S, A, ".hidden")
         and then Refuses (S, A, "a/../b") and then Refuses (S, A, "a\b")
         and then Refuses (S, A, "c:x") and then Refuses (S, A, "")
         and then Refuses (S, A, "a/"),
         "a path that could leave the directory is refused");
      Assert
        (not S.Read_Definition (A, "../execution.json").Found,
         "and cannot be read either");

      Assert
        (not S.Replace_Summary (B, "x") and then not S.Append_Event (B, "x")
         and then not S.Write_Transcript (B, "t", "x")
         and then not S.Write_Description (B, "x")
         and then not S.Write_Definition (B, "synapse-pipeline/P", "x"),
         "nothing is written for an execution that was not made");
      Assert
        (not S.Read_Summary (B).Found and then not S.Read_Events (B).Found
         and then S.Transcript_Names (B).Is_Empty
         and then not S.Read_Description (B).Found
         and then not S.Read_Definition (B, "synapse-pipeline/P.synapse").Found,
         "and nothing is read for it");

      Assert (S.Remove (A), "an execution is removed");
      Assert (not Has_Id (S, A), "and is no longer listed");
      Assert (not S.Read_Summary (A).Found, "with nothing left to read");
      Assert
        (not S.Read_Description (A).Found
         and then not S.Read_Definition (A, "synapse-pipeline/P.synapse").Found,
         "of what it ran as well");
      Assert (S.Remove (A), "removing it again is not a failure");
      Assert
        (S.Create (A) = Registry_Store.Created,
         "an id that was removed can be made again");
      Assert (S.Remove (A), "and removed");
   end Check;

end Synapse.Pipeline.Registry_Contract;
