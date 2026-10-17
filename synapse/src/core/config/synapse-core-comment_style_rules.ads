--  The docstring style rubric and the cheap first filter in front of it.
--
--  The rubric is plain English applied by inference against a docstring's
--  text, not machine-parsed: `synapse-comment-style-rules.conf` ships empty,
--  and a rule is written only when a person flags a problem the check missed.
--  Reading the file is the caller's; nothing here parses it into rules.

package Synapse.Core.Comment_Style_Rules is

   Conf_Name : constant String := "synapse-comment-style-rules.conf";

   --  The first of the tells of a docstring that narrates how code changed and
   --  not what is true now (`no longer`, `used to`, `any more`) found in Text,
   --  whatever its case, or empty when there is none. A plain substring match
   --  and deliberately not word aware: `used tools` contains `used to`. The
   --  rubric, judged by inference, tells a real hit from an accidental one.
   function Historian_Plague_Phrase (Text : String) return String;

end Synapse.Core.Comment_Style_Rules;
