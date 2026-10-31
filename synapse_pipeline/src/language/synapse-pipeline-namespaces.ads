with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Syntax;

--  The definitions there are, by name. One namespace for all three kinds, so a
--  name belongs to exactly one definition whatever its kind.
--
--  A name can instead have failed: its file did not load, or more than one
--  file claims it. Such a name holds no definition, and what went wrong is
--  kept, so that whatever refers to it can say why it cannot be used.

package Synapse.Pipeline.Namespaces is

   --  A definition and the file it was read from.
   type Loaded is record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Item : Syntax.Definition;
   end record;

   type Namespace is private;

   Empty : constant Namespace;

   function Count (N : Namespace) return Natural;

   function Contains (N : Namespace; Name : String) return Boolean;

   function Element (N : Namespace; Name : String) return Loaded
   with Pre => Contains (N, Name);

   --  Whether Name failed to load, and why.
   function Has_Failed (N : Namespace; Name : String) return Boolean;

   function Failure (N : Namespace; Name : String)
      return Source_Errors.Source_Error
   with Pre => Has_Failed (N, Name);

   --  Every name that holds a definition, in alphabetical order.
   function Names (N : Namespace) return Synapse.Core.Text_Lists.Vector;

   --  Gives Name no definition, because of Error, and drops the one it had.
   procedure Fail
     (N     : in out Namespace; Name : String;
      Error : Source_Errors.Source_Error)
   with Post => Has_Failed (N, Name) and then not Contains (N, Name);

   --  Adds a definition under its own name.
   procedure Insert
     (N : in out Namespace; Path : String; Item : Syntax.Definition)
   with
     Pre  =>
       not Contains (N, Ada.Strings.Unbounded.To_String (Item.Name.Name))
       and then
         not Has_Failed (N, Ada.Strings.Unbounded.To_String (Item.Name.Name)),
     Post =>
       Contains (N, Ada.Strings.Unbounded.To_String (Item.Name.Name));

private

   package Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, Loaded);

   package Failures is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Source_Errors.Source_Error, "<", Source_Errors."=");

   type Namespace is record
      Items  : Maps.Map;
      Failed : Failures.Map;
   end record;

   Empty : constant Namespace :=
     (Items => Maps.Empty_Map, Failed => Failures.Empty_Map);

end Synapse.Pipeline.Namespaces;
