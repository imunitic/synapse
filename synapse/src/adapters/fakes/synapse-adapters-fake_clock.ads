with Ada.Strings.Unbounded;

with Synapse.Ports.Clock;

--  A clock that always says the same thing, for tests.

package Synapse.Adapters.Fake_Clock is

   type Fake_Clock is limited new Synapse.Ports.Clock.Clock with record
      Now : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding
   function Timestamp (C : Fake_Clock) return String
   is (Ada.Strings.Unbounded.To_String (C.Now));

end Synapse.Adapters.Fake_Clock;
