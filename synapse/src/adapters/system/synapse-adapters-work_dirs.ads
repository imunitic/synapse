with Synapse.Ports.Variables;

--  Where Synapse keeps its working files. One root serves every program: the
--  code graph keeps a folder in it for each namespace, and `synapse-pipeline`
--  keeps the records of its runs in `pipelines/`. Where a variable comes from
--  is passed in, so none of this touches the real environment unless the
--  caller hands it the system's.

package Synapse.Adapters.Work_Dirs is

   subtype Variables is Synapse.Ports.Variables.Variables'Class;

   --  The setting that names the root.
   Setting : constant String := "SYNAPSE_WORK_DIR";

   --  What the root is when nothing sets it, relative to the home directory.
   Default_Under_Home : constant String := ".cache/synapse/work";

   --  The root: the SYNAPSE_WORK_DIR variable or setting of the configuration
   --  files when it has a value, else `.cache/synapse/work` in the home
   --  directory, which is HOME and on Windows is made from USERPROFILE by the
   --  variables. Empty when neither can be had.
   function Root (V : Variables) return String;

   --  The folder of a namespace, `<repo>@<branch>`, in the root; empty without
   --  a root.
   function Of_Namespace (V : Variables; Namespace : String) return String;

end Synapse.Adapters.Work_Dirs;
