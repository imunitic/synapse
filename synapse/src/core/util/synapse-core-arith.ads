--  Saturating arithmetic. Carries SPARK_Mode and contracts so the build keeps
--  exercising both runtime contract checks and GNATprove.

package Synapse.Core.Arith with SPARK_Mode is

   function Saturating_Add (A, B : Natural) return Natural
   with
     Post =>
       Saturating_Add'Result
       = (if A <= Natural'Last - B then A + B else Natural'Last);

   function Checked_Add (A, B : Natural) return Natural
   with
     Pre  => A <= Natural'Last - B,
     Post => Checked_Add'Result = A + B;

end Synapse.Core.Arith;
