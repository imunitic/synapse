with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Synapse.Adapters.Fake_Store is

   use Ada.Strings.Unbounded;

   procedure Take_Failure (S : in out Fake_Store) is
   begin
      if S.Fail_Next then
         S.Fail_Next := False;
         raise Port.Store_Failure with "injected failure";
      end if;
   end Take_Failure;

   overriding
   function Read (S : in out Fake_Store; Node : String) return Port.Maybe_Text
   is
   begin
      S.Reads := S.Reads + 1;
      Take_Failure (S);
      if S.Nodes.Contains (Node) then
         return (Found => True,
                 Text  => To_Unbounded_String (S.Nodes.Element (Node)));
      end if;
      return (Found => False);
   end Read;

   overriding
   function Write
     (S : in out Fake_Store; Node, Content : String) return Port.Write_Result
   is
   begin
      Take_Failure (S);
      S.Nodes.Include (Node, Content);
      S.Writes := S.Writes + 1;
      return (others => <>);
   end Write;

   overriding
   function List (S : in out Fake_Store) return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
   begin
      S.Lists := S.Lists + 1;
      Take_Failure (S);
      for C in S.Nodes.Iterate loop
         Result.Append (To_Unbounded_String (Node_Maps.Key (C)));
      end loop;
      return Result;
   end List;

   overriding
   function Search
     (S : in out Fake_Store; Query : String) return Port.Hit_Vectors.Vector
   is
      Result : Port.Hit_Vectors.Vector;
   begin
      Take_Failure (S);
      for C in S.Nodes.Iterate loop
         if Ada.Strings.Fixed.Index (Node_Maps.Element (C), Query) > 0 then
            Result.Append
              (Port.Hit'(Node    => To_Unbounded_String (Node_Maps.Key (C)),
                         Score   => 1.0,
                         Context =>
                           To_Unbounded_String (Node_Maps.Element (C))));
         end if;
      end loop;
      return Result;
   end Search;

end Synapse.Adapters.Fake_Store;
