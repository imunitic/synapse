with Ada.Strings.Fixed;

with Synapse.Core.Hashing;

package body Synapse.Core.Node_Format is

   LF : constant Character := Character'Val (10);

   function Module_Of (Path : String; Chains : Text_Lists.Vector) return String
   is
      use Ada.Strings.Fixed;
   begin
      for Chain of Chains loop
         if Length (Chain) > 0 then
            declare
               At_Chain : constant Natural :=
                 Index (Path, "/" & To_String (Chain) & "/");
            begin
               if At_Chain > 0 then
                  return Path (Path'First .. At_Chain - 1);
               end if;
            end;
         end if;
      end loop;

      declare
         At_Src : constant Natural := Index (Path, "/src/");
      begin
         if At_Src > 0 then
            declare
               Rest_First : constant Positive := At_Src + 5;
               Slash      : constant Natural  :=
                 (if Rest_First > Path'Last then 0
                  else Index (Path (Rest_First .. Path'Last), "/"));
            begin
               return
                 (if Slash > 0 then Path (Path'First .. Slash - 1)
                  else Path (Path'First .. At_Src - 1));
            end;
         end if;
      end;

      declare
         Slash : constant Natural := Index (Path, "/");
      begin
         if Slash > 0 then
            return Path (Path'First .. Slash - 1);
         end if;
      end;
      return Repo_Root_Module;
   end Module_Of;

   function Sources_Digest
     (Sources : Graph_Model.Source_Vectors.Vector) return String
   is
      package Sorting is new Text_Lists.Vectors.Generic_Sorting;

      Lines : Text_Lists.Vector;
      Text  : Unbounded_String;
   begin
      for Source of Sources loop
         Lines.Append
           (To_Unbounded_String
              (To_String (Source.Path) & ":" &
               Graph_Model.Hash_To_Hex (Source.Which)));
      end loop;
      Sorting.Sort (Lines);
      for I in 1 .. Natural (Lines.Length) loop
         if I > 1 then
            Append (Text, LF);
         end if;
         Append (Text, Lines (I));
      end loop;
      return Hashing.Sha256_Hex (To_String (Text));
   end Sources_Digest;

   function Split (Text : String) return Split_Result is
      use Ada.Strings.Fixed;

      Start : constant Natural := Index (Text, Generated_Start);
   begin
      if Start = 0 then
         return (Head => To_Unbounded_String (Text), others => <>);
      end if;
      declare
         After_Start : constant Positive := Start + Generated_Start'Length;
         Stop        : constant Natural  :=
           (if After_Start > Text'Last then 0
            else Index (Text (After_Start .. Text'Last), Generated_End));
      begin
         if Stop = 0 then
            return (Head => To_Unbounded_String (Text), others => <>);
         end if;
         return
           (Head => To_Unbounded_String (Text (Text'First .. After_Start - 1)),
            Tail   => To_Unbounded_String (Text (Stop .. Text'Last)),
            Fenced => True);
      end;
   end Split;

end Synapse.Core.Node_Format;
