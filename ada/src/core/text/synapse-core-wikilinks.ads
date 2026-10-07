with Synapse.Core.Text_Lists;

--  Double-bracket links between notes, as text: finding them, saying which
--  note one names, and rewriting them when that note is renamed or deleted.
--  Nothing here reads a file or resolves a link to one.
--
--  A link is `[[Target]]`, `[[Target#Heading]]` or `[[Target|Display]]`.
--  Prose is arbitrary text, not a format this owns: an opening pair with no
--  closing pair is left as it is, and ends the scan.

package Synapse.Core.Wikilinks is

   --  The target of every link in Body_Text, in order: the text before a `|`
   --  alias, without surrounding blanks and line breaks. An empty target is
   --  skipped; a `#` anchor stays part of the target.
   function Extract (Body_Text : String) return Text_Lists.Vector;

   --  The title a target names: without a leading path (up to the last `/`),
   --  a `#` anchor and a trailing `.md`.
   function Normalize_Target (Target : String) return String;

   --  Whether two targets name the same note: the same normalized title after
   --  Unicode NFC and simple case folding. An empty target names nothing.
   function Names_Same_Note (A, B : String) return Boolean;

   --  Body_Text with every link to Old_Target made a link to New_Target, a
   --  `#` anchor and a `|` alias carried through unchanged. Everything else is
   --  copied as it is.
   function Rename_Target
     (Body_Text, Old_Target, New_Target : String) return String;

   --  Body_Text with every link to Old_Target made plain text, so the
   --  sentence around it stays readable: the alias when there is one, else
   --  the bare title as it was typed, without path, anchor or `.md` (they
   --  named a place in a note that is gone, and quoting them would misquote).
   function Unlink_Target (Body_Text, Old_Target : String) return String;

   --  The file name of Path without its directory and a trailing `.md`.
   function Title_Of (Path : String) return String;

   --  A moved note's own title kept in step with its file name: its
   --  frontmatter `title` set to New_Title (a note without frontmatter is left
   --  as it is) and its first line that is exactly `# Old_Title` changed to
   --  `# New_Title`. A heading that has already diverged is left alone.
   function Sync_Title_And_Heading
     (Note, Old_Title, New_Title : String) return String;

end Synapse.Core.Wikilinks;
