with AUnit.Assertions;

package body Synapse.Core.Enumerate.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Is_One (Path : String) is
   begin
      Assert (Is_Binary (Path), Path & " is binary");
   end Is_One;

   procedure Binary_Extensions_Are_Dropped_And_Text_Never_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Is_One ("assets/logo.png");
      Is_One ("doc/manual.pdf");
      Is_One ("lib/libfoo.so");
      Is_One ("target/app.jar");
      Is_One ("model/weights.pt");
      Is_One ("fonts/Inter.woff2");
      Is_One ("certs/ca.pem");
      Is_One ("data/rows.parquet");
      Is_One ("a.der");
   end Binary_Extensions_Are_Dropped_And_Text_Never_Is;

   procedure Text_Formats_Stay (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Binary ("assets/logo.svg"), "svg is text; svgz is not");
      Assert (Is_Binary ("assets/logo.svgz"), "the gzipped one goes");
      Assert (not Is_Binary ("src/main.ext"), "source");
      Assert (not Is_Binary ("README.md"), "prose");
      Assert (not Is_Binary ("Makefile"), "no extension");
      Assert (not Is_Binary ("conf/server.conf"), "configuration");
      Assert (not Is_Binary (""), "empty");
      Assert (not Is_Binary ("a."), "a trailing dot");
      Assert (not Is_Binary ("dir.png/readme"), "a dot in a directory name");
      Assert (not Is_Binary ("a.png gif"), "an extension is one word");
      Assert (not Is_Binary ("a.pn"), "not a prefix of one");
      Assert (not Is_Binary ("a.pngg"), "nor a longer word");
   end Text_Formats_Stay;

   procedure Case_Matters (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Binary ("logo.png"), "lower case");
      Assert (not Is_Binary ("LOGO.PNG"), "upper case");
      Assert (not Is_Binary ("logo.Png"), "mixed");
   end Case_Matters;

   procedure A_Dotfile_Has_No_Extension (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Binary (".pem"), "a hidden file");
      Assert (not Is_Binary ("conf/.pem"), "in a directory");
      Assert (Is_Binary ("conf/ca.pem"), "a named one is still dropped");
      Assert
        (Is_Binary ("conf/.hidden.pem"), "a hidden file with an extension");
   end A_Dotfile_Has_No_Extension;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Enumerate");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Binary_Extensions_Are_Dropped_And_Text_Never_Is'Access,
         "Binary extensions are dropped");
      Register_Routine (T, Text_Formats_Stay'Access, "Text formats stay");
      Register_Routine (T, Case_Matters'Access, "Case matters");
      Register_Routine
        (T, A_Dotfile_Has_No_Extension'Access, "A dotfile has no extension");
   end Register_Tests;

end Synapse.Core.Enumerate.Tests;
