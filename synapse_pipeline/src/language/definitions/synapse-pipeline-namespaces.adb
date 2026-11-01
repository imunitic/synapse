package body Synapse.Pipeline.Namespaces is

   use Ada.Strings.Unbounded;

   function Count (N : Namespace) return Natural is
     (Natural (N.Items.Length));

   function Contains (N : Namespace; Name : String) return Boolean is
     (N.Items.Contains (Name));

   function Element (N : Namespace; Name : String) return Loaded is
     (N.Items.Element (Name));

   function Has_Failed (N : Namespace; Name : String) return Boolean is
     (N.Failed.Contains (Name));

   function Failure (N : Namespace; Name : String)
      return Source_Errors.Source_Error
   is
     (N.Failed.Element (Name));

   procedure Fail
     (N     : in out Namespace; Name : String;
      Error : Source_Errors.Source_Error)
   is
   begin
      if N.Items.Contains (Name) then
         N.Items.Delete (Name);
      end if;
      N.Failed.Include (Name, Error);
   end Fail;

   function Names (N : Namespace) return Synapse.Core.Text_Lists.Vector is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      for C in N.Items.Iterate loop
         Result.Append (To_Unbounded_String (Maps.Key (C)));
      end loop;
      return Result;
   end Names;

   procedure Insert
     (N : in out Namespace; Path : String; Item : Syntax.Definition)
   is
   begin
      N.Items.Insert
        (To_String (Item.Name.Name),
         (Path => To_Unbounded_String (Path), Item => Item));
   end Insert;

end Synapse.Pipeline.Namespaces;
