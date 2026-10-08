with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Process_Runner;

--  A scratch repository, vault, work directory and home, and the means of
--  running the built programs against them. One scratch tree per fixture,
--  under `/tmp` so that no git repository encloses it, removed when the
--  fixture goes out of scope.
--
--  The programs are run with the environment of this process, so a fixture
--  changes it, and puts it back when it is finalized: `HOME`,
--  `SYNAPSE_VAULT_DIR`, `GIT_CEILING_DIRECTORIES` and a `PATH` that starts
--  with the stand-in `git` and `tree-sitter`. The variables that name the
--  namespace, the checkout or the work directory are removed, so that what
--  a test sees is the identity git gives the checkout and not one inherited
--  from the shell that started the suite.
package Acceptance.Fixtures is

   subtype Result is Synapse.Ports.Process_Runner.Result;

   type Fixture is
     limited new Ada.Finalization.Limited_Controlled with private;

   overriding procedure Initialize (F : in out Fixture);

   overriding procedure Finalize (F : in out Fixture);

   ---------------------------------------------------------------------------
   --  Where things are
   ---------------------------------------------------------------------------

   function Root (F : Fixture) return String;
   function Repo (F : Fixture) return String;
   function Vault (F : Fixture) return String;
   function Work (F : Fixture) return String;
   function Home (F : Fixture) return String;

   --  The repository root of the checkout under test: where `bin/` and
   --  `packages/` are.
   function Checkout return String;

   ---------------------------------------------------------------------------
   --  Environment
   ---------------------------------------------------------------------------

   procedure Set_Env (F : in out Fixture; Name, Value : String);

   procedure Unset_Env (F : in out Fixture; Name : String);

   --  Removes every variable but `PATH`, for a program that has to work in an
   --  empty environment.
   procedure Keep_Only_Path (F : in out Fixture);

   --  A content root holding only the shipped `graph-node/v1` schema, which
   --  any test that writes a node needs; `SYNAPSE_CONTENT_ROOT` names it.
   procedure Use_Schema_Content_Root (F : in out Fixture);

   ---------------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------------

   --  A file at an absolute path, with its directories.
   procedure Write_File (Path, Text : String);

   function Read_File (Path : String) return String;

   function Exists (Path : String) return Boolean;

   procedure Delete_File (Path : String);

   procedure Delete_Tree (Path : String);

   procedure Make_Executable (Path : String);

   --  The `HOME` the suite was started with, before any fixture replaced it.
   function Real_Home return String;

   procedure Make_Dir (Path : String);

   --  The names of the files of Dir that end in Suffix, in no order.
   function Files_In
     (Dir : String; Suffix : String := "")
      return Synapse.Core.Text_Lists.Vector;

   --  The lines of a text, without their line feeds.
   function Lines (Text : String) return Synapse.Core.Text_Lists.Vector;

   function Has_Line (Text, Line : String) return Boolean;

   function Has_Line_Starting (Text, Prefix : String) return Boolean;

   --  Everything before the first `## Sources` line: what a regeneration
   --  has in hand, the prose with no directives in it.
   function Prose_Before_Sources (Text : String) return String;

   procedure Write_Repo_File (F : Fixture; Name, Text : String);

   procedure Write_Work_File (F : Fixture; Name, Text : String);

   --  A file directly under the scratch root, beside `repo` and `vault`.
   procedure Write_Root_File (F : Fixture; Name, Text : String);

   ---------------------------------------------------------------------------
   --  Running programs
   ---------------------------------------------------------------------------

   --  An argument list. An empty string is left out, so a test that needs
   --  one builds the vector itself and calls `Run`.
   function Args
     (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12 : String := "")
      return Synapse.Core.Text_Lists.Vector;

   function Run
     (F   : Fixture; Program : String; Argv : Synapse.Core.Text_Lists.Vector;
      Cwd : String; Stdin : String := ""; Piped : Boolean := False)
      return Result;

   --  `synapse`, run in the repository.
   function Run_Synapse
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result;

   --  `synapse-fake`: the same program with grammar compilation and loading
   --  replaced by a stand-in, so that a test needs no C compiler, no network
   --  and no grammar repository.
   function Run_Fake
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result;

   function Run_Hook
     (F                                        : Fixture; A1 : String;
      A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 : String := "") return Result;

   function Run_Synapse_Outside_Repo
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return Result;

   --  A program running while the test goes on: for what only a second
   --  process can show, such as a lock being waited for.
   type Background is limited private;

   procedure Start
     (B    : in out Background; Program : String;
      Argv :        Synapse.Core.Text_Lists.Vector; Cwd : String);

   --  Waits for the program to finish.
   function Await (B : in out Background) return Result;

   function Run_Synapse_List
     (F : Fixture; Argv : Synapse.Core.Text_Lists.Vector) return Result;

   function Run_Fake_List
     (F : Fixture; Argv : Synapse.Core.Text_Lists.Vector) return Result;

   function Run_Hook_Stdin
     (F : Fixture; Stdin : String; A1 : String; A2, A3, A4 : String := "")
      return Result;

   function Run_Fake_Stdin
     (F                  : Fixture; Stdin : String; A1 : String;
      A2, A3, A4, A5, A6 : String := "") return Result;

   --  The programs under test.
   function Synapse_Bin return String;
   function Synapse_Fake_Bin return String;
   function Hook_Bin return String;

   ---------------------------------------------------------------------------
   --  Git
   ---------------------------------------------------------------------------

   function Git
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6, A7, A8 : String := "")
      return Result;

   --  The trimmed standard output of a git command.
   function Git_Output
     (F : Fixture; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return String;

   --  `git init` on `main`, then a commit of everything in the repository.
   procedure Git_Commit (F : Fixture; Message : String);

   --  A repository with one tracked file and one commit. A remote is only
   --  configured, never contacted.
   procedure Make_Repo (F : Fixture; Remote : String := "");

   --  Everything in the repository, committed.
   procedure Commit_All (F : Fixture; Message : String);

   ---------------------------------------------------------------------------
   --  Namespaces
   ---------------------------------------------------------------------------

   --  The `{repo}@{branch}` key of the repository, from the program that
   --  derives it for real.
   function Repo_Name (F : Fixture) return String;

   function Ns_Repo (F : Fixture) return String;

   function Ns_Branch (F : Fixture) return String;

   --  `git remote get-url origin`, else the top of the repository.
   function Repo_Remote_Or_Path (F : Fixture) return String;

   --  `$HOME/.cache/synapse/work/{namespace}`.
   function Default_Work_Dir (F : Fixture) return String;

   --  The `Index.md` `/synapse-init` leaves for a namespace.
   procedure Write_Synapse_Index (F : Fixture; Namespace, Remote : String);

   --  A `_index.bin` in Work_Dir from `path<TAB>node` lines, with nothing
   --  unassigned, by the program that builds it for real.
   procedure Write_Index_Bin (F : Fixture; Work_Dir, Pairs : String);

   ---------------------------------------------------------------------------
   --  Looking at output
   ---------------------------------------------------------------------------

   function Contains (Text, Needle : String) return Boolean;

   function Starts_With (Text, Prefix : String) return Boolean;

   function Trim (Text : String) return String;

   --  Output and errors, for a message that says what a program printed.
   function Both (R : Result) return String;

   --  The long dash of the titles the tests give their nodes, as the UTF-8
   --  bytes a program receives.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   procedure Assert_Exit (R : Result; Want : Integer; What : String);

   procedure Assert_Contains (Text, Needle, What : String);

   procedure Assert_Lacks (Text, Needle, What : String);

   procedure Assert_Equal (Got, Want, What : String);

private

   use Ada.Strings.Unbounded;

   task type Runner_Task is
      entry Start
        (Program : String; Argv : Synapse.Core.Text_Lists.Vector;
         Cwd     : String);
      entry Finish (R : out Result);
   end Runner_Task;

   type Background is limited record
      Job : Runner_Task;
   end record;

   type Saved is record
      Name : Unbounded_String;
      Had  : Boolean;
      Old  : Unbounded_String;
   end record;

   package Saved_Lists is new Ada.Containers.Vectors (Positive, Saved);

   type Fixture is limited new Ada.Finalization.Limited_Controlled with record
      Root_Dir : Unbounded_String;
      Changed  : Saved_Lists.Vector;
   end record;

end Acceptance.Fixtures;
