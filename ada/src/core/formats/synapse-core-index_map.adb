with Ada.Containers.Indefinite_Ordered_Maps;

package body Synapse.Core.Index_Map is

   package Claims is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Text_Lists.Set, "<", Text_Lists.Sets."=");

   function Build
     (Pairs : Pair_Vectors.Vector; Unassigned : Text_Lists.Vector)
      return String
   is
      By_Path : Claims.Map;
      Entries : Index_Map_Format.Entry_Vectors.Vector;
   begin
      for P of Pairs loop
         declare
            Path  : constant String        := To_String (P.Path);
            Place : constant Claims.Cursor := By_Path.Find (Path);
         begin
            if Claims.Has_Element (Place) then
               By_Path.Reference (Place).Include (To_String (P.Node));
            else
               declare
                  Nodes : Text_Lists.Set;
               begin
                  Nodes.Include (To_String (P.Node));
                  By_Path.Insert (Path, Nodes);
               end;
            end if;
         end;
      end loop;

      for Place in By_Path.Iterate loop
         declare
            Item : Index_Map_Format.Entry_Type;
         begin
            Item.Path := To_Unbounded_String (Claims.Key (Place));
            for Name of Claims.Element (Place) loop
               Item.Nodes.Append (To_Unbounded_String (Name));
            end loop;
            Entries.Append (Item);
         end;
      end loop;
      return Index_Map_Format.Encode (Entries, Unassigned);
   end Build;

   function With_Unassigned
     (Current : Index_Map_Format.Decoded; Extra : String) return Maybe_Bytes
   is
      Unassigned : Text_Lists.Vector := Current.Unassigned;
   begin
      for Path of Unassigned loop
         if To_String (Path) = Extra then
            return (Found => False);
         end if;
      end loop;
      Unassigned.Append (To_Unbounded_String (Extra));
      return
        (Found => True,
         Value =>
           To_Unbounded_String
             (Index_Map_Format.Encode (Current.Entries, Unassigned)));
   end With_Unassigned;

end Synapse.Core.Index_Map;
