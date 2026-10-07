--  Which of a repository's tracked files belong in the graph. A file the
--  tool can tell is binary by its extension is dropped when the files are
--  listed, so `_unassigned` means "text nobody placed" and not "an image".
--  What is generated, and what a project does not want in its graph, is for
--  the project's own ignore patterns: they name what is true of that
--  repository.
--
--  Case matters: `logo.png` is binary and `LOGO.PNG` is not, so that a file
--  does not appear or disappear from a listing by a change of spelling, which
--  would change which nodes claim it.

package Synapse.Core.Enumerate is

   --  Whether the extension after the last dot of the file name is one that is
   --  binary by nature. A name that starts with a dot and has no other, like
   --  `.pem`, is a hidden file and has no extension. Only `/` separates
   --  directories.
   function Is_Binary (Path : String) return Boolean;

   --  A generated file named by its basename (a lockfile) or by a suffix of
   --  it (a minified bundle, a source map).
   function Is_Noise (Path : String) return Boolean;

   --  Everything the shipped filters drop.
   function Is_Excluded (Path : String) return Boolean is
     (Is_Binary (Path) or else Is_Noise (Path));

end Synapse.Core.Enumerate;
