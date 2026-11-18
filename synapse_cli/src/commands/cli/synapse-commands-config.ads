--  `synapse config`: the settings of `synapse.conf`, shown and changed.
--
--    config list [--format json|text]   every setting with its value, where
--                                        the value comes from and what it is
--                                        when nothing sets it
--    config set <KEY> <value>           write a setting into the file that
--                                        holds it, or the file a new one goes
--                                        in, changing no other byte
--    config unset <KEY>                 remove a setting from that file
--
--  The JSON of `list` is `synapse-config/v1`. A value is checked before it is
--  written; a setting that a variable of the same name also sets is written
--  all the same, with a note that the variable wins.

package Synapse.Commands.Config is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Config;
