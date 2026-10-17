with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The report `synapse doctor` prints and the rule for what it exits with.
--
--  Every silent guard elsewhere is individually right (a hook that errors is
--  worse than one that quietly does nothing), but together they make a broken
--  install look like a working one with nothing to say. This is the one place
--  each guard has a counterpart that speaks. A check with no silent failure
--  elsewhere does not belong here.
--
--  Three levels. Fail is a broken install, Ok needs no explanation, and
--  Warn
--  is ordinary but worth seeing: no namespace for this branch, no tags cache
--  yet, which is normal on a fresh checkout and a symptom on one where the
--  graph should have been built. Only Fail affects the exit code.

package Synapse.Core.Doctor is

   use Ada.Strings.Unbounded;

   type Status is (Ok, Warn, Fail);

   --  `ok`, `warn` or `FAIL`: upper case, so the one important line stands
   --  out.
   function Label (S : Status) return String;

   type Check is record
      --  A short noun phrase, aligned in the report.
      Name   : Unbounded_String;
      State  : Status := Ok;
      --  What was found, or what is missing and what to do. Empty is fine
      --  for an `ok` whose name says everything.
      Detail : Unbounded_String;
   end record;

   package Check_Vectors is new Ada.Containers.Vectors (Positive, Check);

   --  1 when anything failed, else 0. A warning does not count: an absent
   --  namespace is normal for a branch not clustered yet, and a doctor that
   --  failed on it could not be used in a script.
   function Exit_Code (Checks : Check_Vectors.Vector) return Natural;

   type Counts is record
      Ok, Warn, Fail : Natural := 0;
   end record;

   function Count (Checks : Check_Vectors.Vector) return Counts;

   --  One line per check, the status first so a reader scans the left edge
   --  and the details aligned, then a blank line and the totals.
   function Report (Checks : Check_Vectors.Vector) return String;

end Synapse.Core.Doctor;
