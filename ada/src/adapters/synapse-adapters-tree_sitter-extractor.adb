with Synapse.Core.Tag_Payload;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tree_Sitter.Resolution;
with Synapse.Core.Node_Types;

package body Synapse.Adapters.Tree_Sitter.Extractor is

   use Ada.Strings.Unbounded;
   use type Port.Outcome_Kind;

   package Registry_Types renames Synapse.Core.Grammar_Registry;
   package Resolve renames Synapse.Adapters.Tree_Sitter.Resolution;

   use type Registry_Types.Query_Source;
   use type Tagger.Create_Status;

   procedure Free is new Ada.Unchecked_Deallocation
     (Tagger.Tagger, Tagger_Access);

   Largest_Source : constant := 64 * 1_024 * 1_024;
   Largest_Query  : constant := 1_024 * 1_024;
   Largest_Types  : constant := 16 * 1_024 * 1_024;

   procedure Report_To_Standard_Error (Message : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
   end Report_To_Standard_Error;

   procedure Configure
     (E : in out Tagging_Extractor; Registry : Core.Grammar_Registry.Registry;
      Grammars_Dir :        String; Rules : Core.Kind_Synonyms.Rule_List;
      Max_Tries    :        Positive := Preparation.Default_Lock_Tries;
      Override_Dir :    Core.Grammar_Registry.Maybe_Text := (Found => False);
      Report       :        Reporter := Report_To_Standard_Error'Access)
   is
   begin
      E.Registry     := Registry;
      E.Grammars_Dir := To_Unbounded_String (Grammars_Dir);
      E.Rules        := Rules;
      E.Max_Tries    := Max_Tries;
      E.Override_Dir := Override_Dir;
      E.Report       := Report;
   end Configure;

   function Resolved_Extensions (E : Tagging_Extractor) return Natural is
     (Natural (E.Taggers.Length));

   ---------------------------------------------------------------------------
   --  Reading query sources
   ---------------------------------------------------------------------------

   --  A file's text, or not found when it is absent or cannot be read.
   function Read_Optional
     (Path : String; Limit : Natural; Found : out Boolean) return String
   is
   begin
      Found := False;
      declare
         Text : constant String := File_Bytes.Read (Path, Limit);
      begin
         Found := True;
         return Text;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
        | File_Bytes.Too_Large =>
         return "";
   end Read_Optional;

   --  The grammar's `locals.scm` for filtering local references: the override
   --  directory's `<ext>.locals.scm` when there is one, else the
   --  repository's `queries/locals.scm`.
   function Locals_Of
     (E : Tagging_Extractor; Repo_Dir : String; Extension : String)
      return Registry_Types.Maybe_Text
   is
      Found : Boolean;
   begin
      if E.Override_Dir.Found then
         declare
            Text : constant String :=
              Read_Optional
                (To_String (E.Override_Dir.Value) & "/" & Extension &
                 ".locals.scm",
                 Largest_Query, Found);
         begin
            if Found then
               return (Found => True, Value => To_Unbounded_String (Text));
            end if;
         end;
      end if;
      declare
         Text : constant String :=
           Read_Optional
             (Repo_Dir & "/queries/locals.scm", Largest_Query, Found);
      begin
         return
           (if Found then (Found => True, Value => To_Unbounded_String (Text))
            else (Found => False));
      end;
   end Locals_Of;

   ---------------------------------------------------------------------------
   --  Making a tagger
   ---------------------------------------------------------------------------

   Not_Usable_Tail : constant String := " -- those files are skipped";

   procedure Say_Unusable
     (E : Tagging_Extractor; Extension : String; Why : String)
   is
   begin
      E.Report
        ("synapse-tags: grammar for ." & Extension & " is not usable (" & Why &
         ")" & Not_Usable_Tail);
   end Say_Unusable;

   --  Creates a tagger from a query text, or says why it could not be and
   --  returns none.
   function Created
     (E : Tagging_Extractor; Extension : String; Resolved : Resolve.Resolution;
      Query   : String; Source : Registry_Types.Query_Source;
      Guesses : Core.Node_Types.Guess_Vectors.Vector;
      Locals  : Registry_Types.Maybe_Text) return Tagger_Access
   is
      Made   : Tagger_Access := new Tagger.Tagger;
      Status : Tagger.Create_Status;
   begin
      Tagger.Create
        (Made.all, Resolved.Lang, Query, Source, E.Rules,
         To_String (Resolved.Scope), Guesses, Locals, Status);
      if Status = Tagger.Created then
         return Made;
      end if;
      Free (Made);
      Say_Unusable
        (E, Extension, "the query: " & Tagger.Create_Status'Image (Status));
      return null;
   end Created;

   function Make_Tagger
     (E : Tagging_Extractor; Extension : String; Resolved : Resolve.Resolution)
      return Tagger_Access
   is
      Repo_Dir : constant String := To_String (Resolved.Repo_Dir);
      Locals   : constant Registry_Types.Maybe_Text :=
        Locals_Of (E, Repo_Dir, Extension);
      No_Guess : Core.Node_Types.Guess_Vectors.Vector;
      Found    : Boolean;
   begin
      --  A person's own query wins over every other source.
      if E.Override_Dir.Found then
         declare
            Text : constant String :=
              Read_Optional
                (To_String (E.Override_Dir.Value) & "/" & Extension & ".scm",
                 Largest_Query, Found);
         begin
            if Found then
               return
                 Created
                   (E, Extension, Resolved, Text, Registry_Types.Override,
                    No_Guess, Locals);
            end if;
         end;
      end if;

      --  A query written from the grammar's own node types. The parser may be
      --  in a sub-directory; the queries stay at the repository root.
      if Resolved.Source = Registry_Types.Generated then
         declare
            Sub   : constant Registry_Types.Maybe_Text :=
              Registry_Types.Path_For (E.Registry, Extension);
            Root  : constant String                    :=
              (if Sub.Found then Repo_Dir & "/" & To_String (Sub.Value)
               else Repo_Dir);
            Types : constant String                    :=
              Read_Optional
                (Root & "/src/node-types.json", Largest_Types, Found);
         begin
            if not Found then
               Say_Unusable (E, Extension, "no src/node-types.json");
               return null;
            end if;
            declare
               Guesses : constant Core.Node_Types.Guess_Vectors.Vector :=
                 Core.Node_Types.Classify
                   (Types, E.Rules, To_String (Resolved.Scope));
            begin
               return
                 Created
                   (E, Extension, Resolved,
                    Core.Node_Types.Build_Query (Guesses),
                    Registry_Types.Generated, Guesses, Locals);
            end;
         exception
            when Core.Node_Types.Malformed =>
               Say_Unusable (E, Extension, "src/node-types.json is not JSON");
               return null;
         end;
      end if;

      --  The repository's own query file. A locals query already is the
      --  locals file, so only a tags query takes a separate one.
      declare
         Name  : constant String :=
           (if Resolved.Source = Registry_Types.Locals then "locals.scm"
            else "tags.scm");
         Query : constant String :=
           Read_Optional (Repo_Dir & "/queries/" & Name, Largest_Query, Found);
      begin
         if not Found then
            Say_Unusable (E, Extension, "no queries/" & Name);
            return null;
         end if;
         return
           Created
             (E, Extension, Resolved, Query, Resolved.Source, No_Guess,
              (if Resolved.Source = Registry_Types.Tags then Locals
               else (Found => False)));
      end;
   end Make_Tagger;

   --  Resolved once per extension, the negative answer too: a repository with
   --  many files of an unsupported kind is not resolved and complained about
   --  once for each.
   function Tagger_For
     (E : in out Tagging_Extractor; Extension : String) return Tagger_Access
   is
      Resolved : Resolve.Resolution;
   begin
      if E.Taggers.Contains (Extension) then
         return E.Taggers (Extension);
      end if;
      Resolved :=
        Resolve.Resolve
          (E.Run.all, E.Loader.all, E.Registry, To_String (E.Grammars_Dir),
           Extension, E.Max_Tries);
      declare
         Made : Tagger_Access := null;
      begin
         case Resolved.Which is
            when Resolve.Not_Registered =>
               E.Report
                 ("synapse-tags: no grammar registered for ." & Extension &
                  Not_Usable_Tail);

            when Resolve.Not_Usable =>
               E.Report
                 ("synapse-tags: grammar for ." & Extension &
                  " is marked unsupported" & Not_Usable_Tail);

            when Resolve.Failed =>
               Say_Unusable (E, Extension, To_String (Resolved.Detail));

            when Resolve.Resolved =>
               Made := Make_Tagger (E, Extension, Resolved);
         end case;
         E.Taggers.Insert (Extension, Made);
         return Made;
      end;
   end Tagger_For;

   ---------------------------------------------------------------------------
   --  Tagging files
   ---------------------------------------------------------------------------

   function Is_Absolute (Path : String) return Boolean is
     (Path'Length > 0
      and then
      (Path (Path'First) = '/'
       or else
       (Path'Length >= 3 and then Path (Path'First + 1) = ':'
        and then Path (Path'First + 2) in '/' | '\')));

   overriding function Extract_Located
     (E     : in out Tagging_Extractor; Root : String;
      Paths :        Core.Text_Lists.Vector)
      return Port.Located_Outcome_Vectors.Vector
   is
      Result : Port.Located_Outcome_Vectors.Vector;
   begin
      for Item of Paths loop
         declare
            Path      : constant String      := To_String (Item);
            Extension : constant String := Registry_Types.Extension_Of (Path);
            Outcome   : Port.Located_Outcome := (Kind => Port.Unsupported);
         begin
            if Extension /= "" then
               declare
                  Grammar_Tagger : constant Tagger_Access :=
                    Tagger_For (E, Extension);
               begin
                  if Grammar_Tagger /= null then
                     declare
                        Full    : constant String :=
                          (if Is_Absolute (Path) then Path
                           else Root & "/" & Path);
                        Found   : Boolean;
                        Content : constant String :=
                          Read_Optional (Full, Largest_Source, Found);
                     begin
                        if Found then
                           declare
                              Got : constant Tagger.Located_Results.Result :=
                                Tagger.Tag_File_Located
                                  (Grammar_Tagger.all, Content);
                           begin
                              --  A file that parses to nothing is still
                              --  tagged, with none: marking it unsupported
                              --  would try a readable file again for ever.
                              if Tagger.Located_Results.Is_Success (Got) then
                                 Outcome :=
                                   (Kind => Port.With_Tags,
                                    Tags =>
                                      Tagger.Located_Results.Value (Got));
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
            Result.Append (Outcome);
         end;
      end loop;
      return Result;
   end Extract_Located;

   overriding function Extract
     (E     : in out Tagging_Extractor; Root : String;
      Paths :        Core.Text_Lists.Vector) return Port.Outcome_Vectors.Vector
   is
      Located : constant Port.Located_Outcome_Vectors.Vector :=
        Extract_Located (E, Root, Paths);
      Result  : Port.Outcome_Vectors.Vector;
   begin
      for Item of Located loop
         if Item.Kind = Port.Unsupported then
            Result.Append (Port.Outcome'(Kind => Port.Unsupported));
         else
            declare
               Plain : Core.Tag_Payload.Tag_Vectors.Vector;
            begin
               for Spanned of Item.Tags loop
                  Plain.Append (Spanned.Item);
               end loop;
               Result.Append
                 (Port.Outcome'(Kind => Port.With_Tags, Tags => Plain));
            end;
         end if;
      end loop;
      return Result;
   end Extract;

   overriding procedure Finalize (E : in out Tagging_Extractor) is
   begin
      for Cursor in E.Taggers.Iterate loop
         declare
            Item : Tagger_Access := Caches.Element (Cursor);
         begin
            Free (Item);
         end;
      end loop;
      E.Taggers.Clear;
   end Finalize;

end Synapse.Adapters.Tree_Sitter.Extractor;
