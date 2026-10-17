package body Synapse.Core.Arith with SPARK_Mode is

   function Saturating_Add (A, B : Natural) return Natural is
   begin
      return (if A <= Natural'Last - B then A + B else Natural'Last);
   end Saturating_Add;

   function Checked_Add (A, B : Natural) return Natural is
   begin
      return A + B;
   end Checked_Add;

end Synapse.Core.Arith;
