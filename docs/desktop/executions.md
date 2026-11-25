# Executions

An execution is one run of a pipeline. The Executions panel lists the runs, and each run has a page: where it is on its pipeline, what each step did, and what it changed. Open the panel with the play icon on the rail. To start a run, see [Definitions](definitions.md#run-a-pipeline).

![The Executions panel, with a completed run](img/executions.png)

## Find a run

The panel lists the runs, the newest first. Each row has the pipeline's name, whether the run was interactive or autonomous, its status, its id and the step it is on. A run that waits for your answer says "needs you". The list follows new runs by itself; the refresh button reads it again now. Click a run to open its page.

## Read a run's page

![The page of a completed run](img/execution-page.png)

The page shows, from the top:

- The status of the run and its pipeline. A run that failed says why.
- The diagram of the pipeline, with the run on it: each box says whether the step is running, done (with the outcome it ended with), failed, interrupted or not reached, and how many times it ran. The edges the run took are marked.
- Summary: when the run started and ended, the step it is on and how many steps it ran.
- Definitions it ran: the pipeline and the files it used, as they were when the run began. Click one to read it. The files may have changed since.
- Trace: each visit to a step, in order, with its outcome and the step that came next. "Activity" opens what the agent did in that visit: its messages and the commands it ran. "Changes" opens the files the visit changed in the Changes sidebar.
- Outcomes: one row per visit, with its outcome and the step that came next. Open a row to read what the step reported: its summary, the problems a review listed, and its data as a tree that you can fold and copy. The newest visit's row is open. A run recorded by an older version of synapse-pipeline shows "not recorded".
- Events: everything the run recorded, in order.

The page reads the run again while it goes on, so it stays current.

## Follow a running step

A run without a terminal shows a "Running:" card with the step that runs now. The card shows what the agent has done so far and follows it as it goes; scroll up to read back, and it stops following until you scroll down again. When the step ends, the card goes, and the step is in the Trace.

## Answer an interactive step

An interactive run runs in a terminal on its page, under the diagram. It has no tab on the Terminals page. Click in the terminal to type to the agent. "Hide terminal" folds it away, and "Show terminal" brings it back; the session goes on while it is hidden.

When an agent in an interactive step gets stuck, for example on a command it was not allowed to run, it asks in the terminal and waits instead of ending the run. The page then says "Waiting for you.", with what the agent asked, and the run says "needs you" in the panel and on the [Home page](home.md). Answer in the terminal, and the step carries on.

## Stop a run

"Stop run" at the top of the page ends a run that goes on. For an interactive run the app asks first, and its terminal closes with it. A run without a terminal can be stopped only if it was started from this app.

## Review what a run changed

Click "Changes" on a visit in the Trace, or open the Changes sidebar with the icon at the top right. The number on the icon is how many files changed.

![The Changes sidebar, showing the files a run changed and the diff of one of them](img/changes-sidebar.png)

The sidebar lists the files the run changed, by folder, with the lines added and removed. Click a folder to shut or open it. Click a file to show its diff. A new file is a row that you open to read its content. When a run changed files in more than one step, buttons above the list choose the step. While a step runs, the sidebar shows what it has changed so far; "Refresh" reads it again.

A run's page has only its changes: the Git and Activity tabs, and comments on lines, are there for a terminal session. See [Terminals](terminals.md#follow-what-the-agent-does).

On the command line, `synapse-pipeline` shows the same record of a run; see [synapse-pipeline](../synapse/synapse-pipeline.md).
