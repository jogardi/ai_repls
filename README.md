# AI REPLs

This project provides a set of bash functions I use to enhance the capabilities of AI agents, like the Cursor agent. 

I think the best feature is the py_run function which makes the cursor chat feel like an psuedocode repl.
Just type psudecode in the chat. I didn't use mcp because I wanted to stream the output from the repl.

Right now the 2 parts are the tmux part and the advice part.

The tmux part helps the agent manage `tmux` sessions. Tmux is great for 
helping the AI manage long running commands and repls.

Some examples of how the AI can use this:
- manage multiple long running experiments in parallel. Check on those experiments periodicially with `tmux capture-pane`
- have an ssh session
- have a python repl
- have a python repl within an ssh session
- make plots in a python repl which show up in the matplotlib UI. 
- Have the agent iterate quickly on an idea in the python repl. Tell it save plots to image files. Have it write a report in markdown. Have the agent link to the image file in markdown. Have the agent convert markdown to pdf with pandoc and then you have a research paper with nice plots

Since it's tmux you can use `tmux attach -t` to work closely
with your agent. 

The advice part lets your agent get advice from multiple reasoning 
models in parallel.

# Setup
in your ~/.bashrc add `source <path to this repo>/tmux_run_funcs.sh`

Copy the rules files to cursor or whatever agentic tool you use.

The tmux functions depend on having tmux installed.
The ask_advice function depends on having github.com/simonw/llm setup with
the gemini plugin.

## Functions 

-   `ask_advice`: Agent can get help from both Gemini and O3 at once 
-   `tmux_run`: Run shell commands in a `tmux` pane and get the output synchronously.
-   `start_tmux_repl`: Start a `tmux` session with a Python REPL.
-   `py_run`: Execute Python code within a Python REPL in a `tmux` session.
