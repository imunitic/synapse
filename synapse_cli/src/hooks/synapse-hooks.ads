with Synapse.Commands;

--  The four Claude Code hooks, in a program of their own that links no
--  grammar: a hook runs on every edit and every turn, and one that needs a
--  compiler or a parser to start is one that cannot be trusted to be quiet.
--
--  Every missing precondition is silence and the exit code is always 0: no
--  vault, no namespace, a remote that does not match, no index. A hook that
--  fails interrupts a turn about something the user can seldom act on.
package Synapse.Hooks is

   subtype Environment is Synapse.Commands.Environment;

   procedure Say (Env : Environment; Text : String) renames
     Synapse.Commands.Say;

   procedure Complain (Env : Environment; Text : String) renames
     Synapse.Commands.Complain;

end Synapse.Hooks;
