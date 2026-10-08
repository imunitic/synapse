with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions;

with Acceptance.Fixtures;
with Synapse.Core.Hashing;

package body Acceptance.Diagrams_Reference_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  The real `generate-diagrams.sh`, copied into a throwaway "docs" layout
   --  under the fixture root, so that nothing here touches the real
   --  diagrams.
   function Generator_Copy (F : Fixture) return String is
      Path : constant String := Root (F) & "/docs/generate-diagrams.sh";
   begin
      Make_Dir (Root (F) & "/docs/diagrams");
      Write_File
        (Path, Read_File (Checkout & "/docs/synapse/generate-diagrams.sh"));
      Make_Executable (Path);
      return Path;
   end Generator_Copy;

   procedure Write_Mmd (F : Fixture; Name, Label : String) is
   begin
      Write_File
        (Root (F) & "/docs/diagrams/" & Name & ".mmd",
         "flowchart TB" & LF & "    A[""" & Label & """] --> B[""done""]" &
         LF);
   end Write_Mmd;

   --  Records the current hash of `<name>.mmd`, as a successful render does.
   procedure Stamp (F : Fixture; Name : String) is
      Rendered : constant String := Root (F) & "/docs/diagrams/.rendered";
      Existing : constant String :=
        (if Exists (Rendered) then Read_File (Rendered) else "");
   begin
      Write_File
        (Rendered,
         Existing & Name & ASCII.HT &
         Synapse.Core.Hashing.Sha256_Hex
           (Read_File (Root (F) & "/docs/diagrams/" & Name & ".mmd")) &
         LF);
   end Stamp;

   procedure Write_Png (F : Fixture; Name : String) is
   begin
      Write_File (Root (F) & "/docs/diagrams/" & Name & ".png", "");
   end Write_Png;

   function Run_Gen
     (F : Fixture; Gen : String; Flag : String := "") return Result is
     (Run (F, "bash", Args (Gen, Flag), Root (F)));

   procedure A_Source_With_No_Png_Is_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
   begin
      Write_Mmd (F, "one", "hello");
      declare
         R : constant Result := Run_Gen (F, Gen, "--check");
      begin
         Assert_Exit (R, 1, "--check");
         Assert_Contains (Both (R), "one (no .png)", "names the diagram");
      end;
   end A_Source_With_No_Png_Is_Reported;

   procedure A_Png_Whose_Source_Changed_Is_Stale (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
   begin
      Write_Mmd (F, "one", "hello");
      Write_Png (F, "one");
      Stamp (F, "one");
      Assert_Exit (Run_Gen (F, Gen, "--check"), 0, "as rendered");

      Write_Mmd (F, "one", "hello, revised");
      declare
         R : constant Result := Run_Gen (F, Gen, "--check");
      begin
         Assert_Exit (R, 1, "after the edit");
         Assert_Contains
           (Both (R), "source changed since it was rendered", "says why");
      end;
   end A_Png_Whose_Source_Changed_Is_Stale;

   procedure Passes_When_Every_Png_Matches (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
   begin
      Write_Mmd (F, "one", "a");
      Write_Png (F, "one");
      Stamp (F, "one");
      Write_Mmd (F, "two", "b");
      Write_Png (F, "two");
      Stamp (F, "two");
      declare
         R : constant Result := Run_Gen (F, Gen, "--check");
      begin
         Assert_Exit (R, 0, "--check");
         Assert_Equal (To_String (R.Output), "", "silent");
      end;
   end Passes_When_Every_Png_Matches;

   procedure One_Stale_Diagram_Does_Not_Mask_The_Others
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
   begin
      Write_Mmd (F, "one", "a");
      Write_Png (F, "one");
      Stamp (F, "one");
      Write_Mmd (F, "two", "b");
      Write_Png (F, "two");
      Stamp (F, "two");
      Write_Mmd (F, "three", "c");  --  never rendered
      Write_Mmd (F, "one", "a2");   --  edited after rendering
      declare
         R : constant Result := Run_Gen (F, Gen, "--check");
      begin
         Assert_Exit (R, 1, "--check");
         Assert_Contains (Both (R), "one", "names the edited diagram");
         Assert_Contains (Both (R), "three", "names the unrendered diagram");
         Assert_Contains (Both (R), "2 diagram(s) out of date", "counts");
      end;
   end One_Stale_Diagram_Does_Not_Mask_The_Others;

   procedure No_Sources_Is_An_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
      R   : constant Result := Run_Gen (F, Gen, "--check");
   begin
      Assert_Exit (R, 1, "--check");
      Assert_Contains (Both (R), "no .mmd sources", "says so");
   end No_Sources_Is_An_Error;

   procedure Unknown_Flag_Exits_2_And_Help_Exits_0
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F   : Fixture;
      Gen : constant String := Generator_Copy (F);
   begin
      Write_Mmd (F, "one", "a");
      Assert_Exit (Run_Gen (F, Gen, "--bogus"), 2, "--bogus");
      declare
         R : constant Result := Run_Gen (F, Gen, "--help");
      begin
         Assert_Exit (R, 0, "--help");
         Assert_Contains (Both (R), "Usage:", "usage");
      end;
   end Unknown_Flag_Exits_2_And_Help_Exits_0;

   --  Rendering needs mermaid-cli's Chromium and npm's cache, which live in
   --  the real home and not in the fixture's.
   function Can_Render return Boolean is
     (Real_Home /= "" and then Exists (Real_Home & "/.cache/puppeteer"));

   procedure Use_Real_Caches (F : in out Fixture) is
   begin
      Set_Env (F, "PUPPETEER_CACHE_DIR", Real_Home & "/.cache/puppeteer");
      Set_Env (F, "npm_config_cache", Real_Home & "/.npm");
   end Use_Real_Caches;

   procedure Render_Produces_A_Png_And_Records_The_Hash
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      if not Can_Render then
         Ada.Text_IO.Put_Line ("  skipped: no Chromium cache for mermaid-cli");
         return;
      end if;
      declare
         F   : Fixture;
         Gen : constant String := Generator_Copy (F);
      begin
         Use_Real_Caches (F);
         Write_Mmd (F, "one", "hello");
         Assert_Exit (Run_Gen (F, Gen), 0, "render");
         Assert
           (Exists (Root (F) & "/docs/diagrams/one.png"), "the png exists");
         Assert
           (Read_File (Root (F) & "/docs/diagrams/one.png")'Length > 0,
            "the png has content");
         Assert_Exit
           (Run_Gen (F, Gen, "--check"), 0, "--check after rendering");
      end;
   end Render_Produces_A_Png_And_Records_The_Hash;

   procedure Render_Leaves_Other_Stamps_Alone (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      if not Can_Render then
         Ada.Text_IO.Put_Line ("  skipped: no Chromium cache for mermaid-cli");
         return;
      end if;
      declare
         F   : Fixture;
         Gen : constant String := Generator_Copy (F);
      begin
         Use_Real_Caches (F);
         Write_Mmd (F, "keep", "untouched");
         Write_Png (F, "keep");
         Stamp (F, "keep");
         Write_Mmd (F, "new", "fresh");
         Assert_Exit (Run_Gen (F, Gen), 0, "render");
         declare
            Rendered : constant String :=
              Read_File (Root (F) & "/docs/diagrams/.rendered");
         begin
            Assert
              (Has_Line_Starting (Rendered, "keep" & ASCII.HT),
               "keep is stamped");
            Assert
              (Has_Line_Starting (Rendered, "new" & ASCII.HT),
               "new is stamped");
         end;
      end;
   end Render_Leaves_Other_Stamps_Alone;

   procedure The_Repos_Own_Diagrams_Are_Current (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
      R : constant Result :=
        Run
          (F, "bash",
           Args (Checkout & "/docs/synapse/generate-diagrams.sh", "--check"),
           Checkout);
   begin
      Assert_Exit (R, 0, "generate-diagrams --check");
   end The_Repos_Own_Diagrams_Are_Current;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the rendered diagrams");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Source_With_No_Png_Is_Reported'Access,
         "check: a source with no png is reported");
      Register_Routine
        (T, A_Png_Whose_Source_Changed_Is_Stale'Access,
         "check: a png whose source has changed is stale");
      Register_Routine
        (T, Passes_When_Every_Png_Matches'Access,
         "check: passes when every png matches its recorded hash");
      Register_Routine
        (T, One_Stale_Diagram_Does_Not_Mask_The_Others'Access,
         "check: one stale diagram does not mask the others");
      Register_Routine
        (T, No_Sources_Is_An_Error'Access, "no .mmd sources is an error");
      Register_Routine
        (T, Unknown_Flag_Exits_2_And_Help_Exits_0'Access,
         "an unknown flag exits 2, and --help exits 0");
      Register_Routine
        (T, Render_Produces_A_Png_And_Records_The_Hash'Access,
         "render: produces a png and records the source hash");
      Register_Routine
        (T, Render_Leaves_Other_Stamps_Alone'Access,
         "render: leaves other diagrams' stamps alone");
      Register_Routine
        (T, The_Repos_Own_Diagrams_Are_Current'Access,
         "the repository's own diagrams are current");
   end Register_Tests;

end Acceptance.Diagrams_Reference_Tests;
