with Synapse.Core.Decimal_Image;
package body Synapse.Core.Project_Index is

   LF : constant Character := Character'Val (10);

   --  An em dash, in bytes: the source encoding is not relied on.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Image (P : Params) return String is
      Space : constant String := " ";
      Name  : constant String := To_String (P.Namespace);
      Text  : Unbounded_String;
   begin
      Append (Text, "---" & LF);
      Append
        (Text, "title: """ & Name & Space & Dash & " Synapse index""" & LF);
      Append (Text, "node_type: synapse-index" & LF);
      Append (Text, "project: " & To_String (P.Project) & LF);
      Append (Text, "branch: " & To_String (P.Branch) & LF);
      Append (Text, "remote: """ & To_String (P.Remote) & """" & LF);
      Append (Text, "built_at: """ & To_String (P.Built_At) & """" & LF);
      Append (Text, "---" & LF & LF);
      Append (Text, "# " & Name & Space & Dash & " Synapse index" & LF & LF);

      --  No prose about the repository: how to read a namespace without
      --  opening a node that runs to megabytes.
      Append
        (Text,
         Decimal_Image.Image (P.Total_Files) & " tracked files, " &
         Decimal_Image.Image (Natural (P.Bullets.Length)) &
         " nodes. Nodes are " & "subsystems and concepts, not modules " &
         Dash & " each one's " &
         "frontmatter `sources` lists every file it covers, and `synapse " &
         "index lookup <path>` is the reverse index from any path back to " &
         "its owning node." & LF & LF);
      Append
        (Text,
         "Reading a node: use `synapse query body <node>` rather than " &
         "opening the file " & Dash & " `sources` runs to tens of thousands " &
         "of tokens on the hub nodes and the reverse index is far larger " &
         "still. `synapse query sources <node> --modules` gives the module " &
         "breakdown, `--count` just the number, and `synapse query stale` " &
         "verifies the whole namespace against the working tree." & LF & LF);
      for B of P.Bullets loop
         Append
           (Text,
            "- [[" & To_String (B.Link) & "]] " & Dash & Space &
            To_String (B.Summary) & " (" & Decimal_Image.Image (B.Files) &
            " files)" & LF);
      end loop;
      return To_String (Text);
   end Image;

end Synapse.Core.Project_Index;
