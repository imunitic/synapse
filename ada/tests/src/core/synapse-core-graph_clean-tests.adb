with AUnit.Assertions;

package body Synapse.Core.Graph_Clean.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Set_To (Text : String) return Maybe_Text is
     (Found => True, Value => To_Unbounded_String (Text));

   None : constant Maybe_Text := (Found => False);

   function Is_Report (V : Verdict; Why : Reason) return Boolean is
     (V.Kind = Report and then V.Why = Why);

   procedure A_Configured_Upstream_That_Is_Gone_Is_Removed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Verdict :=
        Classify
          ((Branch              => Set_To ("feature/x"), Has_Remote => True,
            Local_Exists        => False, Upstream_Remote => Set_To ("origin"),
            Upstream_Branch     => Set_To ("feature/x"),
            Upstream_Ref_Exists => False));
   begin
      Assert (V.Kind = Remove, "removed");
      Assert
        (To_String (V.Upstream_Remote) = "origin"
         and then To_String (V.Upstream_Branch) = "feature/x",
         "with the upstream it had");
   end A_Configured_Upstream_That_Is_Gone_Is_Removed;

   procedure An_Upstream_Still_On_The_Remote_Is_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classify
           ((Branch          => Set_To ("main"), Has_Remote => True,
             Local_Exists    => False, Upstream_Remote => Set_To ("origin"),
             Upstream_Branch => Set_To ("main"), Upstream_Ref_Exists => True))
           .Kind =
         Keep,
         "alive on the remote, even with no local branch");
   end An_Upstream_Still_On_The_Remote_Is_Kept;

   procedure Never_Pushed_Is_Kept_When_Here_And_Reported_When_Gone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classify
           ((Branch       => Set_To ("wip"), Has_Remote => True,
             Local_Exists => True, others => <>))
           .Kind =
         Keep,
         "active work");
      Assert
        (Is_Report
           (Classify
              ((Branch       => Set_To ("wip"), Has_Remote => True,
                Local_Exists => False, others => <>)),
            Gone_No_Upstream),
         "gone: a person decides");
   end Never_Pushed_Is_Kept_When_Here_And_Reported_When_Gone;

   procedure A_Repository_With_No_Remote_Falls_Back_To_Local_Existence
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classify
           ((Branch => Set_To ("main"), Local_Exists => True, others => <>))
           .Kind =
         Keep,
         "here");
      Assert
        (Is_Report
           (Classify ((Branch => Set_To ("old"), others => <>)),
            Gone_No_Remote),
         "gone");
   end A_Repository_With_No_Remote_Falls_Back_To_Local_Existence;

   procedure A_Namespace_With_No_Branch_Field_Cannot_Be_Judged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_Report
           (Classify
              ((Branch          => None, Has_Remote => True,
                Upstream_Remote => Set_To ("origin"),
                Upstream_Branch => Set_To ("x"), others => <>)),
            No_Branch_Field),
         "absent");
      Assert
        (Is_Report
           (Classify ((Branch => Set_To (""), others => <>)), No_Branch_Field),
         "empty");
   end A_Namespace_With_No_Branch_Field_Cannot_Be_Judged;

   procedure A_Half_Configured_Upstream_Is_Treated_As_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_Report
           (Classify
              ((Branch          => Set_To ("x"), Has_Remote => True,
                Upstream_Remote => Set_To ("origin"), others => <>)),
            Gone_No_Upstream),
         "a remote and no merge ref");
      Assert
        (Is_Report
           (Classify
              ((Branch          => Set_To ("x"), Has_Remote => True,
                Upstream_Remote => Set_To (""),
                Upstream_Branch => Set_To ("x"), others => <>)),
            Gone_No_Upstream),
         "an empty remote");
      Assert
        (Is_Report
           (Classify
              ((Branch          => Set_To ("x"), Has_Remote => True,
                Upstream_Remote => Set_To ("origin"),
                Upstream_Branch => Set_To (""), others => <>)),
            Gone_No_Upstream),
         "an empty merge ref");
   end A_Half_Configured_Upstream_Is_Treated_As_None;

   --  Removal deletes notes in a permanent vault, so what it needs is stated
   --  as a property of every combination of facts and not as examples.
   procedure A_Namespace_Is_Removed_Only_On_A_Complete_Gone_Upstream
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Texts   : constant array (1 .. 3) of Maybe_Text :=
        [None, Set_To (""), Set_To ("v")];
      Removed : Natural                               := 0;
   begin
      for Branch of Texts loop
         for Has_Remote in Boolean loop
            for Local in Boolean loop
               for Remote of Texts loop
                  for Merge of Texts loop
                     for Ref in Boolean loop
                        declare
                           F        : constant Facts   :=
                             (Branch, Has_Remote, Local, Remote, Merge, Ref);
                           V        : constant Verdict := Classify (F);
                           Complete : constant Boolean :=
                             Branch.Found and then Length (Branch.Value) > 0
                             and then Has_Remote and then Remote.Found
                             and then Length (Remote.Value) > 0
                             and then Merge.Found
                             and then Length (Merge.Value) > 0;
                        begin
                           Assert
                             ((V.Kind = Remove) = (Complete and not Ref),
                              "removed exactly when complete and gone");
                           if V.Kind = Remove then
                              Removed := Removed + 1;
                           end if;
                           if Complete and Ref then
                              Assert (V.Kind = Keep, "alive is kept");
                           end if;
                        end;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
      Assert (Removed = 2, "one for each local state of the one case");
   end A_Namespace_Is_Removed_Only_On_A_Complete_Gone_Upstream;

   procedure The_Reason_Texts_Name_The_Branch (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Reason_Text (No_Branch_Field, "") =
         "no branch field -- cannot tell which branch it describes",
         "no branch field");
      Assert
        (Reason_Text (Gone_No_Remote, "old") =
         "branch old is gone and the repo has no remote",
         "no remote");
      Assert
        (Reason_Text (Gone_No_Upstream, "wip") =
         "branch wip is absent locally and had no upstream configured",
         "no upstream");
   end The_Reason_Texts_Name_The_Branch;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Graph_Clean");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Configured_Upstream_That_Is_Gone_Is_Removed'Access,
         "A configured upstream that is gone is removed");
      Register_Routine
        (T, An_Upstream_Still_On_The_Remote_Is_Kept'Access,
         "An upstream still on the remote is kept");
      Register_Routine
        (T, Never_Pushed_Is_Kept_When_Here_And_Reported_When_Gone'Access,
         "Never pushed is kept when here and reported when gone");
      Register_Routine
        (T, A_Repository_With_No_Remote_Falls_Back_To_Local_Existence'Access,
         "A repository with no remote falls back to local existence");
      Register_Routine
        (T, A_Namespace_With_No_Branch_Field_Cannot_Be_Judged'Access,
         "A namespace with no branch field cannot be judged");
      Register_Routine
        (T, A_Half_Configured_Upstream_Is_Treated_As_None'Access,
         "A half configured upstream is treated as none");
      Register_Routine
        (T, A_Namespace_Is_Removed_Only_On_A_Complete_Gone_Upstream'Access,
         "A namespace is removed only on a complete, gone upstream");
      Register_Routine
        (T, The_Reason_Texts_Name_The_Branch'Access,
         "The reason texts name the branch");
   end Register_Tests;

end Synapse.Core.Graph_Clean.Tests;
