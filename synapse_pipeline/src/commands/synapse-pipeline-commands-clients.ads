with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

--  What `list` and `info` have in common as clients of a running pipeline:
--  where the runs are, and what an answer means.

package Synapse.Pipeline.Commands.Clients is

   --  The directory runs keep their endpoints in, from the configuration. When
   --  there is none, or the configuration is wrong, Found is False and the
   --  reason has been put on standard error.
   procedure Work_Directory
     (Env       : Environment;
      Directory : out Ada.Strings.Unbounded.Unbounded_String;
      Found     : out Boolean);

   --  The result in an answer that said it was ok. Otherwise Ok is False and
   --  Message says why: the answer was not one, or it said it was not ok.
   procedure Read_Answer
     (Text    : String;
      Ok      : out Boolean;
      Result  : out Synapse.Core.JSON.Value;
      Message : out Ada.Strings.Unbounded.Unbounded_String);

end Synapse.Pipeline.Commands.Clients;
