--  The patch a session leaves in a run's record: what `git diff` printed of
--  the changes the session made in its working tree, as one text. A file that
--  already existed is kept whole. The content of a file that is new is kept
--  only up to a limit for each file, since a generated or vendored file can
--  be larger than all the rest; past it the file is kept as its header and a
--  hunk of the right number of lines that says the content was not kept:
--
--    diff --git a/big.dat b/big.dat
--    new file mode 100644
--    --- /dev/null
--    +++ b/big.dat
--    @@ -0,0 +1,40000 @@
--    \ Content not kept

package Synapse.Pipeline.Patches is

   --  The most of a new file that is kept when no limit is set: 1 MB.
   Default_Largest : constant := 1_000_000;

   --  What the hunk of a new file says in place of its lines.
   Not_Kept : constant String := "Content not kept";

   --  Patch with the lines of every new file that takes more than Largest
   --  bytes in it left out as above. A patch that holds no such file is
   --  returned as it is.
   function Capped (Patch : String; Largest : Natural) return String;

end Synapse.Pipeline.Patches;
