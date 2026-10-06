package body Synapse.Core.Graph_Clean is

   function Set_And_Not_Empty (Value : Maybe_Text) return Boolean is
     (Value.Present and then Length (Value.Text) > 0);

   function Classify (F : Facts) return Verdict is
   begin
      if not Set_And_Not_Empty (F.Branch) then
         return (Kind => Report, Why => No_Branch_Field);
      end if;
      if not F.Has_Remote then
         return
           (if F.Local_Exists then (Kind => Keep)
            else (Kind => Report, Why => Gone_No_Remote));
      end if;
      if Set_And_Not_Empty (F.Upstream_Remote)
        and then Set_And_Not_Empty (F.Upstream_Branch)
      then
         return
           (if F.Upstream_Ref_Exists then (Kind => Keep)
            else (Kind => Remove, Upstream_Remote => F.Upstream_Remote.Text,
               Upstream_Branch => F.Upstream_Branch.Text));
      end if;
      return
        (if F.Local_Exists then (Kind => Keep)
         else (Kind => Report, Why => Gone_No_Upstream));
   end Classify;

   function Reason_Text (Why : Reason; Branch : String) return String is
     (case Why is
        when No_Branch_Field =>
          "no branch field -- cannot tell which branch it describes",
        when Gone_No_Remote =>
          "branch " & Branch & " is gone and the repo has no remote",
        when Gone_No_Upstream =>
          "branch " & Branch &
          " is absent locally and had no upstream configured");

end Synapse.Core.Graph_Clean;
