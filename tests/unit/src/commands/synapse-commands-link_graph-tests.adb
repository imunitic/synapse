with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with AUnit.Assertions;

package body Synapse.Commands.Link_Graph.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   procedure Put (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Name), Text);
   end Put;

   function Ref (Name, Role, Kind, Site, Expr : String) return String is
     (Name & HT & Role & HT & Kind & HT & Site & HT & Expr & LF);

   --  Two nodes: Beta calls what Alpha defines, twice over.
   procedure Fixture_Files (Dir : Scratch) is
   begin
      Put (Dir, "lists/001.title", "Alpha" & LF);
      Put (Dir, "lists/001.txt", "alpha/a.ext" & LF);
      Put (Dir, "lists/002.title", "Beta" & LF);
      Put (Dir, "lists/002.txt", "beta/b.ext" & LF);
      Put
        (Dir, "_refs.tsv",
         Ref ("startEngine", "def", "function", "alpha/a.ext:1", "start") &
         Ref ("startEngine", "ref", "call", "beta/b.ext:4", "start ()") &
         Ref ("stopEngine", "def", "function", "alpha/a.ext:2", "stop") &
         Ref ("stopEngine", "ref", "call", "beta/b.ext:5", "stop ()"));
   end Fixture_Files;

   procedure Link_Graph_Writes_The_Edges_Between_Nodes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Fixture_Files (Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "_refs.tsv"), "--lists",
               Path (Dir, "lists"), "--out", Path (Dir, "out"))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Synapse.Adapters.File_Bytes.Read
           (Path (Dir, "out/links.tsv"), 10_000) =
         "Beta" & HT & "Alpha" & HT & "2" & HT & "startEngine stopEngine" & LF,
         "one edge, two shared symbols");
      Assert
        (F.Console.Err_Text =
         "synapse-link-graph: 2 nodes, 1 edges (0 via import-edge resolution), 1 nodes with at least one -> " &
         Path (Dir, "out/links.tsv") & LF,
         "the report: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Writes_The_Edges_Between_Nodes;

   procedure Link_Graph_Takes_Its_Inputs_From_The_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Fixture_Files (Dir);
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work_refs"), "");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "w"));
      Ada.Directories.Create_Path (Path (Dir, "w"));
      Ada.Directories.Copy_File
        (Path (Dir, "_refs.tsv"), Path (Dir, "w/_refs.tsv"));
      Assert
        (Run (Env (F), Args ("--lists", Path (Dir, "lists"))) = 0, "success");
      Assert
        (Ada.Directories.Exists (Path (Dir, "w/links.tsv")),
         "written to the work directory");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Takes_Its_Inputs_From_The_Work_Directory;

   procedure Link_Graph_Keeps_The_Strongest_Edges (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Fixture_Files (Dir);
      Put (Dir, "lists/003.title", "Gamma" & LF);
      Put (Dir, "lists/003.txt", "gamma/c.ext" & LF);
      Put
        (Dir, "_refs.tsv",
         Ref ("a", "def", "function", "alpha/a.ext:1", "a") &
         Ref ("b", "def", "function", "alpha/a.ext:2", "b") &
         Ref ("a", "ref", "call", "beta/b.ext:1", "a ()") &
         Ref ("b", "ref", "call", "beta/b.ext:2", "b ()") &
         Ref ("a", "ref", "call", "gamma/c.ext:1", "a ()"));
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "_refs.tsv"), "--lists",
               Path (Dir, "lists"), "--out", Path (Dir, "o1"), "--top", "1")) =
         0,
         "top one");
      Assert
        (Ada.Strings.Fixed.Count
           (Synapse.Adapters.File_Bytes.Read
              (Path (Dir, "o1/links.tsv"), 10_000),
            "Beta" & HT) =
         1,
         "one for Beta");
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "_refs.tsv"), "--lists",
               Path (Dir, "lists"), "--out", Path (Dir, "o0"), "--top", "0")) =
         0,
         "no cap");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Keeps_The_Strongest_Edges;

   procedure Link_Graph_Resolves_Ambiguous_Names_By_Import
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Put (Dir, "lists/001.title", "Alpha" & LF);
      Put (Dir, "lists/001.txt", "alpha/a.ext" & LF);
      Put (Dir, "lists/002.title", "Beta" & LF);
      Put (Dir, "lists/002.txt", "beta/b.ext" & LF);
      Put (Dir, "lists/003.title", "Other" & LF);
      Put (Dir, "lists/003.txt", "other/o.ext" & LF);
      Put
        (Dir, "_refs.tsv",
         Ref ("render", "def", "function", "alpha/a.ext:1", "r") &
         Ref ("render", "def", "function", "other/o.ext:1", "r") &
         Ref ("render", "ref", "call", "beta/b.ext:3", "render ()"));
      Put (Dir, "deps.tsv", "beta/b.ext" & HT & "lib.alpha" & LF);
      Put
        (Dir, "ns.tsv",
         "alpha/a.ext" & HT & "lib.alpha" & LF & "other/o.ext" & HT &
         "lib.other" & LF);
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "_refs.tsv"), "--lists",
               Path (Dir, "lists"), "--out", Path (Dir, "out"), "--deps",
               Path (Dir, "deps.tsv"), "--namespaces", Path (Dir, "ns.tsv"))) =
         0,
         "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "1 via import-edge resolution") >
         0,
         "the one the dependency names: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (Synapse.Adapters.File_Bytes.Read
              (Path (Dir, "out/links.tsv"), 10_000),
            "Beta" & HT & "Alpha") =
         1,
         "to Alpha and not to Other");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Resolves_Ambiguous_Names_By_Import;

   procedure Link_Graph_Says_What_Is_Missing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert
        (Run
           (Env (F),
            Args
              ("--lists", Path (Dir, "none"), "--refs", "r", "--out", "o")) =
         1,
         "no lists");
      Fixture_Files (Dir);
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "gone.tsv"), "--lists",
               Path (Dir, "lists"), "--out", Path (Dir, "o"))) =
         1,
         "no refs");
      Ada.Directories.Create_Path (Path (Dir, "empty"));
      Assert
        (Run
           (Env (F),
            Args
              ("--refs", Path (Dir, "_refs.tsv"), "--lists",
               Path (Dir, "empty"), "--out", Path (Dir, "o"))) =
         1,
         "no nodes");
      Assert
        (F.Console.Err_Text =
         "synapse-link-graph: no such lists dir: " & Path (Dir, "none") & LF &
         "synapse-link-graph: no reference index at " &
         Path (Dir, "gone.tsv") & " -- run `synapse build-refs`" & LF &
         "synapse-link-graph: no NN.txt/NN.title pairs in " &
         Path (Dir, "empty") & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Says_What_Is_Missing;

   procedure Link_Graph_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "no lists");
      Assert (Run (Env (F), Args ("--lists")) = 2, "dangling");
      Assert
        (Run (Env (F), Args ("--lists", "x", "--top", "many")) = 2,
         "top must be a number");
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse link-graph --refs") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Link_Graph_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Link_Graph");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Link_Graph_Writes_The_Edges_Between_Nodes'Access,
         "Link graph writes the edges between nodes");
      Register_Routine
        (T, Link_Graph_Takes_Its_Inputs_From_The_Work_Directory'Access,
         "Link graph takes its inputs from the work directory");
      Register_Routine
        (T, Link_Graph_Keeps_The_Strongest_Edges'Access,
         "Link graph keeps the strongest edges");
      Register_Routine
        (T, Link_Graph_Resolves_Ambiguous_Names_By_Import'Access,
         "Link graph resolves ambiguous names by import");
      Register_Routine
        (T, Link_Graph_Says_What_Is_Missing'Access,
         "Link graph says what is missing");
      Register_Routine
        (T, Link_Graph_Arguments'Access, "Link graph arguments");
   end Register_Tests;

end Synapse.Commands.Link_Graph.Tests;
