with Synapse.Core.Optional_Text;

--  The files of a repository, read by path relative to its root. What the
--  graph's rules need from a repository is the text of a file, found by the
--  path `git ls-files` printed, and nothing else.

package Synapse.Ports.Repo_Reader is

   type Reader is limited interface;

   subtype Maybe_Content is Synapse.Core.Optional_Text.Option;

   --  The content of the file at Path, or none when it cannot be read: it is
   --  missing, or too large for the graph to read whole.
   function Read
     (R : in out Reader; Path : String) return Maybe_Content is abstract;

end Synapse.Ports.Repo_Reader;
