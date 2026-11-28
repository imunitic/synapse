with AUnit.Assertions;

package body Synapse.Pipeline.Efforts.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Harnesses;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Claude_Offers_Its_Five_Efforts (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Offered (Claude, "low"), "low");
      Assert (Is_Offered (Claude, "medium"), "medium");
      Assert (Is_Offered (Claude, "high"), "high");
      Assert (Is_Offered (Claude, "xhigh"), "xhigh");
      Assert (Is_Offered (Claude, "max"), "max");
      Assert (Is_Offered (Claude, "High"), "High");
      Assert (Is_Offered (Claude, "XHIGH"), "XHIGH");
      Assert
        (Names (Claude) = "low, medium, high, xhigh, max", Names (Claude));
   end Claude_Offers_Its_Five_Efforts;

   procedure Claude_Refuses_Minimal (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Offered (Claude, "minimal"), "minimal");
      Assert (not Is_Offered (Claude, ""), "empty");
      Assert (not Is_Offered (Claude, "high "), "a trailing space");
   end Claude_Refuses_Minimal;

   procedure Codex_Offers_Its_Efforts (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Offered (Codex, "minimal"), "minimal");
      Assert (Is_Offered (Codex, "xhigh"), "xhigh");
      Assert (Is_Offered (Codex, "max"), "max");
      Assert (Is_Offered (Codex, "ultra"), "ultra");
      Assert (Is_Offered (Codex, "Ultra"), "Ultra");
      Assert
        (Names (Codex)
         = "none, minimal, low, medium, high, xhigh, max, ultra, persistent",
         Names (Codex));
   end Codex_Offers_Its_Efforts;

   procedure Codex_Refuses_An_Unknown_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Offered (Codex, "extreme"), "extreme");
      Assert (not Is_Offered (Codex, ""), "empty");
   end Codex_Refuses_An_Unknown_Name;

   procedure Opencode_Takes_Any_Variant_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Offered (Opencode, "high"), "high");
      Assert (Is_Offered (Opencode, "Thinking"), "Thinking");
      Assert (Is_Offered (Opencode, "extreme"), "extreme");
      Assert (Is_Offered (Opencode, "v1.2_fast-mode"), "dot, underscore, dash");
      Assert (Is_Offered (Opencode, (1 .. 64 => 'a')), "64 characters");
      Assert (Names (Opencode) = "", "no list");
   end Opencode_Takes_Any_Variant_Name;

   procedure Opencode_Refuses_A_Malformed_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Offered (Opencode, ""), "empty");
      Assert (not Is_Offered (Opencode, "-high"), "a leading dash");
      Assert (not Is_Offered (Opencode, "high#low"), "a #");
      Assert (not Is_Offered (Opencode, ".high"), "a leading dot");
      Assert (not Is_Offered (Opencode, "hi gh"), "a space");
      Assert (not Is_Offered (Opencode, (1 .. 65 => 'a')), "65 characters");
      Assert
        (not Is_Offered (Opencode, "h" & Character'Val (233)),
         "a Latin-1 letter");
   end Opencode_Refuses_A_Malformed_Name;

   procedure Normalized_Lowers_Claude_And_Codex (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Normalized (Claude, "High") = "high", "Claude");
      Assert (Normalized (Codex, "XHigh") = "xhigh", "Codex");
      Assert (Normalized (Opencode, "Thinking") = "Thinking", "OpenCode");
   end Normalized_Lowers_Claude_And_Codex;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Efforts");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Claude_Offers_Its_Five_Efforts'Access,
         "Claude offers its five efforts, in any case");
      Register_Routine
        (T, Claude_Refuses_Minimal'Access, "Claude refuses minimal");
      Register_Routine
        (T, Codex_Offers_Its_Efforts'Access,
         "Codex offers minimal, xhigh, max and ultra");
      Register_Routine
        (T, Codex_Refuses_An_Unknown_Name'Access,
         "Codex refuses an unknown name such as extreme");
      Register_Routine
        (T, Opencode_Takes_Any_Variant_Name'Access,
         "OpenCode takes any variant name");
      Register_Routine
        (T, Opencode_Refuses_A_Malformed_Name'Access,
         "OpenCode refuses an empty name, a leading dash and a #");
      Register_Routine
        (T, Normalized_Lowers_Claude_And_Codex'Access,
         "Normalized lowers Claude and Codex and keeps OpenCode as written");
   end Register_Tests;

end Synapse.Pipeline.Efforts.Tests;
