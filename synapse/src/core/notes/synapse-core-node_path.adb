package body Synapse.Core.Node_Path with SPARK_Mode is

   function Is_Safe (Node : String) return Boolean is
   begin
      if Node'Length > 0 and then Node (Node'First) = '/' then
         return False;
      end if;
      for I in 0 .. Node'Length - 1 loop
         pragma
           Loop_Invariant
             (for all K in 0 .. I - 1 => not Parent_Segment_At (Node, K));
         pragma
           Loop_Invariant
             (for all K in 0 .. I - 1 => Node (Node'First + K) /= '\');
         if Node (Node'First + I) = '\'
           or else Parent_Segment_At (Node, I)
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Safe;

end Synapse.Core.Node_Path;
