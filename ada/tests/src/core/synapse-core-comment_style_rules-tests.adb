with AUnit.Assertions;

package body Synapse.Core.Comment_Style_Rules.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Each_Configured_Tell_Is_Caught_Whatever_Its_Case
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Historian_Plague_Phrase ("This no longer does X.") = "no longer",
         "no longer");
      Assert
        (Historian_Plague_Phrase ("USED TO be simpler.") = "used to",
         "used to");
      Assert
        (Historian_Plague_Phrase ("Not needed any more.") = "any more",
         "any more");
   end Each_Configured_Tell_Is_Caught_Whatever_Its_Case;

   procedure Present_Tense_Prose_Is_Not_Flagged (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Historian_Plague_Phrase
           ("Computes the checksum over the byte range.") =
         "",
         "clean");
      Assert (Historian_Plague_Phrase ("") = "", "empty");
      Assert (Historian_Plague_Phrase ("no") = "", "shorter than any tell");
   end Present_Tense_Prose_Is_Not_Flagged;

   procedure It_Is_A_Plain_Substring_Match (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Historian_Plague_Phrase ("The bonus edict used tools.") = "used to",
         "`used to` is a substring of `used tools`: the accepted cost " &
         "of a cheap first filter");
   end It_Is_A_Plain_Substring_Match;

   procedure The_First_Tell_In_The_List_Wins_When_Several_Hit
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Historian_Plague_Phrase ("It used to be, and no longer is.") =
         "no longer",
         "the list's order and not the text's");
   end The_First_Tell_In_The_List_Wins_When_Several_Hit;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Comment_Style_Rules");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Each_Configured_Tell_Is_Caught_Whatever_Its_Case'Access,
         "Each configured tell is caught, whatever its case");
      Register_Routine
        (T, Present_Tense_Prose_Is_Not_Flagged'Access,
         "Present tense prose is not flagged");
      Register_Routine
        (T, It_Is_A_Plain_Substring_Match'Access,
         "It is a plain substring match");
      Register_Routine
        (T, The_First_Tell_In_The_List_Wins_When_Several_Hit'Access,
         "The first tell in the list wins when several hit");
   end Register_Tests;

end Synapse.Core.Comment_Style_Rules.Tests;
