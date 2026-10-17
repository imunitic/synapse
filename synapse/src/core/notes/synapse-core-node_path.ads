--  Whether a store's node name may address a file. Node names use `/` as the
--  separator on every platform.

package Synapse.Core.Node_Path with SPARK_Mode is

   --  Whether the segment of Node that starts at offset I (counted from the
   --  first character) is `..`.
   function Parent_Segment_At (Node : String; I : Natural) return Boolean
   is (I + 1 < Node'Length
       and then (I = 0 or else Node (Node'First + I - 1) = '/')
       and then Node (Node'First + I) = '.'
       and then Node (Node'First + I + 1) = '.'
       and then (I + 2 = Node'Length or else Node (Node'First + I + 2) = '/'))
   with Pre => Node'Last < Positive'Last and then I < Node'Length;

   --  False for a name that is absolute, has a `..` segment anywhere, or
   --  contains a backslash, any of which could leave the directory a store
   --  addresses names relative to. A single `.` segment and a name that
   --  starts with a dot are ordinary.
   function Is_Safe (Node : String) return Boolean
   with
     Pre  => Node'Last < Positive'Last,
     Post =>
       (if Is_Safe'Result
        then
          (Node'Length = 0 or else Node (Node'First) /= '/')
          and then (for all C of Node => C /= '\')
          and then (for all I in 0 .. Node'Length - 1
                    => not Parent_Segment_At (Node, I)));

end Synapse.Core.Node_Path;
