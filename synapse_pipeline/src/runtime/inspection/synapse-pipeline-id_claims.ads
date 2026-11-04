with Ada.Strings.Unbounded;

with Synapse.Pipeline.Registry_Store;

--  Taking an execution id. The directory made for an execution is the claim
--  on its id: making it fails when it is already there, whatever drew the id.

package Synapse.Pipeline.Id_Claims is

   --  How many ids are drawn before the registry is given up on.
   Largest_Tries : constant := 10;

   type Claim is record
      Id         : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether the registry holds the execution's directory. It does not
      --  when the directory could not be made, or when every id drawn was
      --  taken; the run goes on without a record.
      Registered : Boolean := False;
   end record;

   --  Draws an id and makes its directory, drawing another while the id is
   --  taken, up to Largest_Tries times.
   function Take
     (Store : in out Registry_Store.Store'Class;
      Draw  : not null access function return String) return Claim;

end Synapse.Pipeline.Id_Claims;
