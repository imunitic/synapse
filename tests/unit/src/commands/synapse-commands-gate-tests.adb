with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with AUnit.Assertions;

package body Synapse.Commands.Gate.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   function Cluster (Name : String; Words : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      N      : Natural  := 20;
      Start  : Positive := Words'First;
   begin
      for I in Words'First .. Words'Last + 1 loop
         if I > Words'Last or else Words (I) = ' ' then
            Ada.Strings.Unbounded.Append
              (Result,
               Name & HT & Words (Start .. I - 1) & HT &
               Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both) &
               LF);
            N     := N - 1;
            Start := I + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Cluster;

   --  Three differentiated clusters sharing a common tail, and one made of
   --  that tail alone.
   function Four_Clusters return String is
     (Cluster
        ("Billing", "invoice dunning description identifier bundle resource") &
      Cluster
        ("Shipping", "parcel carrier description identifier bundle resource") &
      Cluster
        ("Pricing", "tariff premium description identifier bundle resource") &
      Cluster ("Generic", "description identifier bundle resource"));

   procedure Put (Dir : Scratch; Name, Text : String) is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Name), Text);
   end Put;

   procedure A_Cluster_Of_Only_Common_Terms_Is_Flagged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "words.tsv", Four_Clusters);
      Assert
        (Run (Env (F), Args ("--vocab", Path (Dir, "words.tsv"))) = 0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "Generic" & HT) = 1
         and then Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 1
         and then Ada.Strings.Fixed.Index (F.Console.Out_Text, "flagged") > 0,
         "only the one: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Cluster_Of_Only_Common_Terms_Is_Flagged;

   procedure Every_Cluster_Is_Printed_With_All (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "words.tsv", Four_Clusters);
      Assert
        (Run (Env (F), Args ("--vocab", Path (Dir, "words.tsv"), "--all")) = 0,
         "success");
      Assert
        (Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 4,
         "four lines: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "Billing" & HT & "2" & HT & "ok") =
         1,
         "an ok one");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Cluster_Is_Printed_With_All;

   procedure Clean_Clusters_Print_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put
        (Dir, "words.tsv",
         Cluster ("Billing", "invoice dunning ledger") &
         Cluster ("Shipping", "parcel carrier manifest"));
      Assert
        (Run (Env (F), Args ("--vocab", Path (Dir, "words.tsv"))) = 0,
         "success");
      Assert (F.Console.Out_Text = "", "silence is clean");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Clusters_Print_Nothing;

   procedure A_Cluster_With_Nothing_Parseable_Is_Not_Blamed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "words.tsv", Four_Clusters);
      Put
        (Dir, "parse.tsv",
         "Generic" & HT & "0" & HT & "3" & LF & "Billing" & HT & "2" & HT &
         "3" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--vocab", Path (Dir, "words.tsv"), "--parseable",
               Path (Dir, "parse.tsv"), "--all")) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "Generic" & HT & "0" & HT & "unparseable") >
         0,
         "named as it is: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "flagged") = 0,
         "not flagged");
      F.Console.Clear;
      Assert
        (Run
           (Env (F),
            Args
              ("--vocab", Path (Dir, "words.tsv"), "--parseable",
               Path (Dir, "parse.tsv"))) =
         0,
         "without all");
      Assert
        (F.Console.Out_Text = "", "advice, and so only flags are printed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Cluster_With_Nothing_Parseable_Is_Not_Blamed;

   procedure Parseable_Rows_That_Say_Nothing_Are_Skipped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "words.tsv", Four_Clusters);
      Put
        (Dir, "parse.tsv",
         "Generic" & HT & "0" & HT & "0" & LF & "Generic" & HT & "x" & HT &
         "3" & LF & "Generic" & HT & "0" & LF & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--vocab", Path (Dir, "words.tsv"), "--parseable",
               Path (Dir, "parse.tsv"))) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "flagged") > 0,
         "still judged by its words");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Parseable_Rows_That_Say_Nothing_Are_Skipped;

   procedure Top_Bounds_The_Terms_The_Rule_Looks_At
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "words.tsv", Four_Clusters);
      Assert
        (Run
           (Env (F),
            Args ("--vocab", Path (Dir, "words.tsv"), "--all", "--top", "1")) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 4,
         "all four");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Top_Bounds_The_Terms_The_Rule_Looks_At;

   procedure A_Missing_Or_Empty_Vocabulary_Is_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "empty.tsv", "");
      Assert
        (Run (Env (F), Args ("--vocab", Path (Dir, "gone.tsv"))) = 1,
         "missing");
      Assert
        (Run (Env (F), Args ("--vocab", Path (Dir, "empty.tsv"))) = 1,
         "empty");
      Put (Dir, "words.tsv", Four_Clusters);
      Assert
        (Run
           (Env (F),
            Args
              ("--vocab", Path (Dir, "words.tsv"), "--parseable",
               Path (Dir, "gone"))) =
         1,
         "missing shares");
      Assert
        (F.Console.Err_Text =
         "synapse-gate: no such vocabulary file: " & Path (Dir, "gone.tsv") &
         LF & "synapse-gate: " & Path (Dir, "empty.tsv") &
         " is empty -- nothing was tagged, so cluster quality cannot be judged" &
         LF & "synapse-gate: no such parseable-share file: " &
         Path (Dir, "gone") & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Or_Empty_Vocabulary_Is_An_Error;

   procedure Gate_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "no vocabulary");
      Assert (Run (Env (F), Args ("--vocab")) = 2, "dangling");
      Assert
        (Run (Env (F), Args ("--vocab", "x", "--top", "0")) = 2,
         "top must be positive");
      Assert
        (Run (Env (F), Args ("--vocab", "x", "--top", "many")) = 2,
         "top must be a number");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse gate --vocab") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Gate_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Gate");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Cluster_Of_Only_Common_Terms_Is_Flagged'Access,
         "A cluster of only common terms is flagged");
      Register_Routine
        (T, Every_Cluster_Is_Printed_With_All'Access,
         "Every cluster is printed with all");
      Register_Routine
        (T, Clean_Clusters_Print_Nothing'Access,
         "Clean clusters print nothing");
      Register_Routine
        (T, A_Cluster_With_Nothing_Parseable_Is_Not_Blamed'Access,
         "A cluster with nothing parseable is not blamed");
      Register_Routine
        (T, Parseable_Rows_That_Say_Nothing_Are_Skipped'Access,
         "Parseable rows that say nothing are skipped");
      Register_Routine
        (T, Top_Bounds_The_Terms_The_Rule_Looks_At'Access,
         "Top bounds the terms the rule looks at");
      Register_Routine
        (T, A_Missing_Or_Empty_Vocabulary_Is_An_Error'Access,
         "A missing or empty vocabulary is an error");
      Register_Routine (T, Gate_Arguments'Access, "Gate arguments");
   end Register_Tests;

end Synapse.Commands.Gate.Tests;
