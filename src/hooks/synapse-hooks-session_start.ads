with Synapse.Hooks.Common;

--  `session-start`: SessionStart. Injects the vault's `Index.md`, so a session
--  begins with the map in context, and the Synapse pointer: this repository's
--  namespace, checked against the remote it recorded, or a line saying there
--  is none, and a catalogue of the other namespaces, so a session that moves
--  to another repository knows its graph exists. A branch with no namespace of
--  its own is usually a short-lived one off a trunk that has one: the line
--  then names the namespaces recorded against this remote and how to read
--  them with `--namespace`.
--
--  Building the text is a path lookup, never a model call or a round trip.
--  The one network call is the vault pull, which `Run` starts detached. The
--  hook only reads the vault; only `staleness` writes.
--
--  A remote that does not match is reported and never repaired: it may be a
--  different repository with the same name, or this one with a remote changed
--  on purpose. Both remedies belong to the person who made the change.
package Synapse.Hooks.Session_Start is

   procedure Run (Env : Environment);

   --  The text to inject for the repository at Cwd, or none when there is
   --  nothing to say.
   function Build (Env : Environment; Cwd : String) return Common.Maybe_Text;

end Synapse.Hooks.Session_Start;
