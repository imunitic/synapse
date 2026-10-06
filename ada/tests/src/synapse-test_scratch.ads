with Ada.Strings.Unbounded;

--  A fresh directory under obj/, removed when the test is done, and git
--  commands to set up and inspect repositories in it.

package Synapse.Test_Scratch is

   type Scratch is limited record
      Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Make return Scratch;
   procedure Remove (S : Scratch);

   function Path (S : Scratch; Name : String := "") return String;

   --  Runs git in Dir with the given arguments; its standard output, trimmed.
   --  Raises Program_Error when git exits non-zero.
   function Git (Dir : String; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return String;

   --  The same, ignoring a failure.
   procedure Git
     (Dir : String; A1 : String; A2, A3, A4, A5, A6 : String := "");

   --  `git rev-list --count HEAD`, or 0 where there is no commit.
   function Commit_Count (Dir : String) return Natural;

   --  The subject of the latest commit.
   function Head_Subject (Dir : String) return String;

   --  A repository on `main` with a committer identity.
   procedure Init_Repo (Dir : String);

end Synapse.Test_Scratch;
