with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;

--  Which namespaces a clean may remove and which it may only report. Cleaning
--  is the one destructive operation on the vault, so this is the inference
--  alone, apart from the deletion, and testable without a vault or a
--  repository.
--
--  Three verdicts. Remove: it had an upstream and the upstream is gone, which
--  is a merged and deleted branch. Report: absent locally with no upstream to
--  confirm, which is a never pushed branch deleted by hand and a branch whose
--  configuration went with it, indistinguishable now, so a person decides.
--  Keep: anything else, work in progress that was never pushed included.
--
--  Whether the repository has a remote is asked of git, not derived from the
--  namespace's remote name, which falls back to the repository path and is
--  never empty: derived, the first run in a repository with no remote would
--  find every namespace deleted upstream and remove all of them. An upstream
--  is read from the branch's configured remote and merge ref and the
--  remote-tracking ref, since `@{upstream}` stops resolving once the ref is
--  pruned and so cannot tell a gone upstream from none.

package Synapse.Core.Graph_Clean is

   use Ada.Strings.Unbounded;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   type Reason is (No_Branch_Field,
      --  The branch is gone and the repository has no remote at all.
      Gone_No_Remote,
      --  The branch is absent locally and had no upstream configured.
      Gone_No_Upstream);

   type Verdict_Kind is (Keep, Remove, Report);

   type Verdict (Kind : Verdict_Kind := Keep) is record
      case Kind is
         when Keep =>
            null;

         when Remove =>
            Upstream_Remote : Unbounded_String;
            Upstream_Branch : Unbounded_String;

         when Report =>
            Why : Reason;
      end case;
   end record;

   type Facts is record
      --  From the namespace's own `branch:` field, never from its directory
      --  name, which does not translate back (`feature-1` may be
      --  `feature/1` or a branch of that name).
      Branch              : Maybe_Text;
      --  Whether the repository has any remote.
      Has_Remote          : Boolean := False;
      --  Whether `refs/heads/<branch>` exists.
      Local_Exists        : Boolean := False;
      --  `branch.<name>.remote`.
      Upstream_Remote     : Maybe_Text;
      --  `branch.<name>.merge` with `refs/heads/` stripped.
      Upstream_Branch     : Maybe_Text;
      --  Whether `refs/remotes/<remote>/<branch>` exists.
      Upstream_Ref_Exists : Boolean := False;
   end record;

   --  An upstream with either half unset or empty is none: a half written
   --  setting is not grounds to delete a namespace.
   function Classify (F : Facts) return Verdict;

   --  The text of a report, without a line feed.
   function Reason_Text (Why : Reason; Branch : String) return String;

end Synapse.Core.Graph_Clean;
