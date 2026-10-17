with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Extractor;

--  An extractor that answers from a script and records what it was asked:
--  for tests that need the tags of a file and not a grammar.

package Synapse.Adapters.Fake_Extractor is

   package Port renames Synapse.Ports.Extractor;

   type Fake is limited new Port.Locating_Extractor with private;

   --  What to answer for Path.
   procedure Script (F : in out Fake; Path : String; Answer : Port.Outcome);

   --  Make asking about Path raise Program_Error, as an extractor that
   --  breaks does.
   procedure Script_Failure (F : in out Fake; Path : String);

   --  What to answer for a path with no script. Tags with none at first.
   procedure Set_Default (F : in out Fake; Answer : Port.Outcome);

   --  How many times Extract was called: a batch is one call, and a test of
   --  batching asserts it.
   function Calls (F : Fake) return Natural;

   --  Every path asked about, in call order.
   function Seen (F : Fake) return Core.Text_Lists.Vector;

   overriding function Extract
     (F : in out Fake; Root : String; Paths : Core.Text_Lists.Vector)
      return Port.Outcome_Vectors.Vector;

   --  What was scripted, each tag at a span that starts at its line and is as
   --  wide as its name.
   overriding function Extract_Located
     (F : in out Fake; Root : String; Paths : Core.Text_Lists.Vector)
      return Port.Located_Outcome_Vectors.Vector;

private

   use type Port.Outcome;

   package Scripts is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Port.Outcome, Ada.Strings.Hash, "=");

   --  Extract may be called by several tasks at once.
   protected type Mutex is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Mutex;

   type Fake is limited new Port.Locating_Extractor with record
      Lock     : Mutex;
      Scripted : Scripts.Map;
      Failing  : Core.Text_Lists.Set;
      Default  : Port.Outcome := (Kind => Port.With_Tags, others => <>);
      Count    : Natural      := 0;
      Asked    : Core.Text_Lists.Vector;
   end record;

end Synapse.Adapters.Fake_Extractor;
