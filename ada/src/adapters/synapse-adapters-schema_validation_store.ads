with Synapse.Core.Text_Lists;
with Synapse.Ports.Clock;
with Synapse.Ports.Store;
with Synapse.Ports.Variables;

--  The validation boundary for notes that declare a schema. A note without a
--  `schema:` field passes through unchanged. One that declares a schema
--  reaches the inner store only if it validates against it; reading, listing
--  and searching are the inner store's own.

package Synapse.Adapters.Schema_Validation_Store is

   package Port renames Synapse.Ports.Store;

   --  The status of a write refused for not validating.
   Rejected : constant := 422;

   type Validation_Store is limited new Port.Store with private;

   --  Vars says where the schemas (`SYNAPSE_CONTENT_ROOT`) and the
   --  vocabulary files are; Clock stamps `updated`.
   function Create
     (Inner : not null access Port.Store'Class;
      Vars  : not null access Ports.Variables.Variables'Class;
      Clock : not null access Ports.Clock.Clock'Class)
      return Validation_Store;

   overriding
   function Read
     (S : in out Validation_Store; Node : String) return Port.Maybe_Text;

   --  The checks run in this order, and the first to fail refuses the write
   --  with status 422 and its message as the body:
   --  1. the identifier of the schema is safe, and a schema once declared is
   --     not dropped;
   --  2. on anything but a create, `updated` is stamped with the clock;
   --  3. the schema loads and is itself valid;
   --  4. the note validates (on a create or migration, a note id or task id
   --     held by another note is a violation, when the schema checks it);
   --  5. no lint of severity `error` finds fault, a `warn` one being printed
   --     to standard error instead.
   --  A rejected write never reaches the inner store.
   overriding
   function Write
     (S : in out Validation_Store; Node, Content : String)
      return Port.Write_Result;

   overriding
   function List (S : in out Validation_Store) return Core.Text_Lists.Vector;

   overriding
   function Search
     (S : in out Validation_Store; Query : String)
      return Port.Hit_Vectors.Vector;

private

   type Validation_Store is limited new Port.Store with record
      Inner : not null access Port.Store'Class;
      Vars  : not null access Ports.Variables.Variables'Class;
      Clock : not null access Ports.Clock.Clock'Class;
   end record;

end Synapse.Adapters.Schema_Validation_Store;
