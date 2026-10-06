with Ada.Strings.Unbounded;

with Synapse.Adapters.Tree_Sitter.Grammar;
with Synapse.Core.Grammar_Registry;
with Synapse.Ports.Library_Loader;
with Synapse.Ports.Process_Runner;

--  Getting a grammar from a registry entry to a loaded language: clone its
--  repository on first use, compile `src/parser.c` (and `src/scanner.c` when
--  there is one) into a shared library, and load it. The clone and the
--  compile are each done under a lock directory, so processes that need the
--  same grammar at once do the work once; a lock whose holder died is taken
--  over after Lock_Stale_After.
--
--  A failure is a result that says what happened and where, for the caller to
--  report once.

package Synapse.Adapters.Tree_Sitter.Preparation with
  SPARK_Mode => Off
is

   package Runner renames Synapse.Ports.Process_Runner;

   --  How many times a lock is tried, 0.2 seconds apart: it bounds waiting
   --  for a lock a crashed holder left, not the clone or the compile.
   Default_Lock_Tries : constant := 300;

   --  How long a lock may go untouched before it counts as abandoned. A
   --  shallow clone is a few megabytes, so nothing legitimate needs this
   --  long; it is well past the minute a waiter gives up after.
   Lock_Stale_After : constant Duration := 15.0 * 60.0;

   type Failure_Kind is
     (No_Compiler,
      --  No C compiler on the path could be started.
      Clone_Failed,
      --  The clone failed, or timed out waiting for another process's.
      Compile_Failed,
      --  A compiler was found and every one of them failed, the grammar has
      --  a scanner in a language other than C, or the compile lock timed out.
      Parser_Source_Missing
      --  The grammar's directory has no `src/parser.c`.
     );

   --  Why a grammar could not be prepared. Detail is for a person and may be
   --  long: it holds what each compiler or git said, which an exception
   --  message would cut off.
   type Failure is record
      Kind   : Failure_Kind;
      Detail : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  `<kind>: <detail>`.
   function Describe (F : Failure) return String;

   type Build_Result (Ok : Boolean := True) is record
      case Ok is
         when True =>
            null;

         when False =>
            Why : Failure;
      end case;
   end record;

   type Clone_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Dir : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            Why : Failure;
      end case;
   end record;

   --  The directory of Repo_Url's clone under Repos_Parent, cloned there first
   --  if it is not already. The clone is made in a staging directory and
   --  published with one rename, so a killed clone is never taken for a
   --  finished one.
   function Ensure_Cloned
     (Run          : in out Runner.Runner'Class;
      Repo_Url     : String;
      Repos_Parent : String;
      Max_Tries    : Positive := Default_Lock_Tries) return Clone_Result;

   --  Compiles the grammar in Repo_Dir into the shared library Out_Path with
   --  the first C compiler found that works, and does nothing when Out_Path
   --  is newer than every source: the scanner counts as well as the parser,
   --  since a pull may touch only it. Compilers tried, in this order: `zig
   --  cc`, `cc`, `gcc`, `clang`. Each one found gets a real attempt, since
   --  one that reports a version may still be unable to compile, and what
   --  each said is in the detail when all fail. No `-march=native`: the
   --  library may outlive the machine that built it.
   function Build
     (Run       : in out Runner.Runner'Class;
      Repo_Dir  : String;
      Out_Path  : String;
      Max_Tries : Positive := Default_Lock_Tries) return Build_Result;

   --  Where the library of Symbol goes: `<Grammars_Dir>/lib/<Symbol>.<ext>`,
   --  keyed by symbol and not by repository, since one repository can hold
   --  several grammars and two extensions can share one language.
   function Library_Path
     (Loader       : Synapse.Ports.Library_Loader.Loader'Class;
      Grammars_Dir : String;
      Symbol       : String) return String;

   type Resolved_Kind is (Loaded, Not_Prepared, Not_Loadable);

   type Resolved (Kind : Resolved_Kind := Not_Prepared) is record
      case Kind is
         when Loaded =>
            Item : Language;

         when Not_Prepared =>
            Why : Failure;

         when Not_Loadable =>
            Error : Grammar.Load_Error;
      end case;
   end record;

   --  Builds if needed and loads the grammar of the repository at Repo_Dir:
   --  the parser lives in Sub_Path under it when there is one, and the
   --  symbol is Sub_Symbol or else derived from Name (the repository's name).
   function Resolve_And_Load
     (Run          : in out Runner.Runner'Class;
      Loader       : in out Synapse.Ports.Library_Loader.Loader'Class;
      Repo_Dir     : String;
      Grammars_Dir : String;
      Name         : String;
      Sub_Path     : Core.Grammar_Registry.Maybe_Text;
      Sub_Symbol   : Core.Grammar_Registry.Maybe_Text;
      Max_Tries    : Positive := Default_Lock_Tries) return Resolved;

end Synapse.Adapters.Tree_Sitter.Preparation;
