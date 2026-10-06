with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  Verification: whether a node still describes the tree it claims.
--
--  Two questions. `stale` asks whether a node's sources still hash to what
--  was recorded: a yes or no about the file set. `grounding` asks whether the
--  specific lines a sentence rests on are still those lines, telling a moved
--  range ("point it again") from a changed one ("read it again").
--
--  Everything here is a function of bytes: the caller reads files and runs
--  git, so these decisions are tested without a repository.

package Synapse.Core.Verify is

   use Ada.Strings.Unbounded;

   --  Why a node is stale, or that it is not. The distinctions are load
   --  bearing: a missing digest needs a rebuild (the node pre-dates the
   --  field), changed content needs a regeneration (the files moved on), and
   --  collapsing them would make the first look like the second forever.
   type Staleness_Kind is
     (Clean, Node_File_Missing, No_Digest, No_Sources,
      --  Recorded files no longer on disk. Hashing would fail the whole batch
      --  on one of them, so they are found and named first.
      Sources_Gone,
      Hashing_Failed, Content_Changed);

   type Staleness (Kind : Staleness_Kind := Clean) is record
      case Kind is
         when Sources_Gone =>
            Gone : Text_Lists.Vector;

         when others =>
            null;
      end case;
   end record;

   --  The text of a finding. Empty for Clean: every reporting subcommand
   --  relies on empty output meaning exactly that.
   function Reason (S : Staleness) return String;

   --  What a node's recorded state and its files' current hashes add up to.
   --  Hashes is parallel to Paths (each 40 hexadecimal digits); Missing names
   --  the paths that had none. The checks run in an order in which each answer
   --  is meaningful: no node file, no stored digest (absent or empty), no
   --  sources, files gone, a hash count that does not match (or a hash that is
   --  not one), and then the digest itself.
   function Check
     (Present : Boolean; Has_Digest : Boolean; Stored_Digest : String;
      Paths   : Text_Lists.Vector; Missing : Text_Lists.Vector;
      Hashes  : Text_Lists.Vector) return Staleness;

   --  One `grounded_in` entry: the lines a claim rests on, and their digest.
   type Grounding is record
      Path   : Unbounded_String;
      --  As recorded, `first-last`, 1-based and inclusive.
      Lines  : Unbounded_String;
      --  SHA-256 over those lines as `sed -n 'first,lastp'` prints them. The
      --  key is `digest:` and not `hash:`: `sources:` entries use `hash:`.
      Digest : Unbounded_String;
   end record;

   package Grounding_Vectors is new Ada.Containers.Vectors
     (Positive, Grounding);

   --  A 1-based inclusive line range.
   type Line_Range is record
      First, Last : Positive;
   end record;

   type Maybe_Range (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Line_Range;

         when False =>
            null;
      end case;
   end record;

   --  The range a grounding records: none when it is not `first-last`, has a
   --  zero line, or ends before it begins.
   function Range_Of (G : Grounding) return Maybe_Range;

   --  The `grounded_in:` block of a node's frontmatter. Separate from the
   --  sources on purpose: both are `- path:` lists in one frontmatter, and
   --  mixing them reports changed content for every grounded node.
   function Groundings (Text : String) return Grounding_Vectors.Vector;

   --  Where a recorded range's content is now, if anywhere: a window of the
   --  same number of lines slid through Content until its SHA-256 equals
   --  Digest. One pass over the text, and only worth running after the direct
   --  check failed. The window is two cursors, each moved one line at a time,
   --  and not a fresh scan to every candidate, which would make the pass
   --  quadratic in the lines.
   function Find_Moved
     (Content : String; Span : Natural; Digest : String) return Maybe_Range;

end Synapse.Core.Verify;
