with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.Options;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Repo_Reader;

--  The namespace a file declares, found by a rule, and what the rules are.
--
--  A file's declared namespace is what its own ecosystem says: a declaration
--  line in the file, or the name a build manifest declares. The directory that
--  holds it is what the file system says. When the two disagree across most of
--  a directory, a later search for the directory's own name comes back empty,
--  because the code calls itself something else.
--
--  A rule and not a grammar query: a tags query does not capture an in-file
--  namespace declaration in every ecosystem, some have no such node, and in
--  some the closest capture names a nested unit and not the library a file
--  belongs to, which lives in a build manifest beside it. Every rule is either
--  in the file (a declaration line) or in the nearest ancestor build file (a
--  declared module or package name).
--
--  A prefix and a terminator and not a regular expression: every case is "find
--  the line that starts with X and take what is up to Y", a handful of
--  searches that need no engine.
--
--  No rule ships. The registry is read from a configuration file keyed by
--  extension: absent means not discovered yet, and a rule is written only
--  after an agent has checked it against a real file of the repository, so a
--  new ecosystem is a change to a configuration file and never to code.

package Synapse.Core.Namespace is

   use Ada.Strings.Unbounded;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   type Kind is (In_File, Build_File);

   --  An additional identity on the same nearest-ancestor file as the rule's
   --  own prefix: some ecosystems give one file two valid names, an internal
   --  one that its code calls itself and a published one that a dependent's
   --  declaration uses, different strings for the same file.
   type Alias is record
      Prefix     : Unbounded_String;
      Terminator : Maybe_Text;
   end record;

   package Alias_Vectors is new Ada.Containers.Vectors (Positive, Alias);

   --  One extension's rule. File is set for a build file: the name to look for
   --  in the ancestor directories. No terminator means to the end of the line,
   --  trimmed.
   type Rule is record
      Which      : Kind;
      File       : Maybe_Text;
      Prefix     : Unbounded_String;
      Terminator : Maybe_Text;
      Aliases    : Alias_Vectors.Vector;
   end record;

   package Rule_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Rule);

   --  The rules, keyed by bare extension.
   type Registry is record
      Rules : Rule_Maps.Map;
   end record;

   Malformed : exception;

   --  The registry a JSON object of extension to rule describes. A rule is
   --  `{"kind": "in-file" | "build-file", "prefix": ..., "terminator": ...,
   --  "file": ..., "aliases": [...]}`. What is not a rule is left out, so the
   --  rest still apply: a kind that is neither, an empty prefix, a build file
   --  with no file name. An empty terminator means none, and an alias with no
   --  prefix is skipped. Anything but an object is an empty registry. Raises
   --  Malformed when the text is not JSON.
   function Parse (Text : String) return Registry;

   --  Whether there is no rule, which lets a caller skip the whole pass
   --  instead of walking every file to learn it.
   function Is_Empty (R : Registry) return Boolean is (R.Rules.Is_Empty);

   package Maybe_Rule_Options is new Synapse.Core.Options (Rule);

   subtype Maybe_Rule is Maybe_Rule_Options.Option;

   --  The rule of the extension a path ends in: after the last dot of its base
   --  name, none for a name that starts with a dot and has no other.
   function Rule_For_Path (R : Registry; Path : String) return Maybe_Rule;

   --  The value of the first line of Content that starts with Prefix, from
   --  there to Terminator or the end of the line, trimmed. None when no line
   --  matches or the value is blank. Line by line and not a search of the
   --  whole text, so a prefix inside a comment or a string is not matched; one
   --  "inside a block comment" is kept across lines, enough to skip a
   --  declaration that is commented out, and not a comment parser. A line
   --  that has the prefix and no terminator is skipped, not cut.
   function Extract_Field
     (Content : String; Prefix : String; Terminator : Maybe_Text)
      return Maybe_Text;

   --  The directory of a repository-relative path: everything before the last
   --  `/`, or "" at the root. Only `/` splits, since these paths come from
   --  `git ls-files` and always use it.
   function Dir_Of (Path : String) return String;

   --  The file name: everything after the last `/`, or the whole path.
   function Base_Of (Path : String) return String;

   package Dir_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   --  The value recorded for Dir or, failing that, for the nearest ancestor,
   --  one segment at a time up to the root. By_Dir maps the directory of a
   --  build file to what it declares.
   function Nearest_Namespace
     (By_Dir : Dir_Maps.Map; Dir : String) return Maybe_Text;

   --  What a build file declares, per directory, kept for each rule so that
   --  many files under one library read its build file once. A rule is
   --  identified by its file name, prefix and terminator together: two rules
   --  that name one build file with different prefixes extract different
   --  values from it, and the file name alone would hand the second rule the
   --  first one's answer.
   type Build_Cache is private;

   --  One extraction of Path under a prefix and a terminator: the file itself
   --  for an in-file rule, the nearest ancestor build file for a build-file
   --  rule. One cache serves every rule and alias.
   function Extract
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Path       :    String; Which : Kind; File : Maybe_Text; Prefix : String;
      Terminator : Maybe_Text; Cache : in out Build_Cache) return Maybe_Text;

   --  One file's declared identity: a namespace, or one of the additional
   --  identities its rule's aliases declare.
   type Row is record
      Path      : Unbounded_String;
      Namespace : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Row);

   --  Every path of Kept with its declared namespaces: a row per identity that
   --  resolved to a value, more than one when the rule has aliases. Kept per
   --  file and not grouped, the signal the import-edge resolution needs: which
   --  library a candidate definition's file belongs to under any name a
   --  dependent might call it. Path ascending and namespace ascending within a
   --  path, so two runs over an unchanged repository are identical. An empty
   --  registry returns at once without reading a file.
   function Compute_Per_File
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Rules  :        Registry) return Row_Vectors.Vector;

private

   package Cache_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Dir_Maps.Map, "<", Dir_Maps."=");

   type Build_Cache is record
      Maps : Cache_Maps.Map;
   end record;

end Synapse.Core.Namespace;
