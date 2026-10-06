# haro embedded terminal — a readable, colored interactive shell.
#
# The container ships no per-user shell config, so without this the PTY is a
# bare, prompt-less, colorless bash ("works but looks plain"). Sourced via
# `bash --rcfile`, so it runs for every workspace terminal.

# Inherit anything the system / user rc already provides, then layer on top.
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"

# xterm.js is a 256-color (truecolor) terminal — advertise it so git, ls, eza,
# ripgrep, etc. actually emit color instead of falling back to plain output.
export TERM="${TERM:-xterm-256color}"
export CLICOLOR=1

# Color the everyday commands (GNU coreutils in the container).
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'

# Prompt: bold-green user, bold-blue cwd, and the git branch (amber) when inside
# a repo. Dependency-free — just parses `git branch`, no prompt framework.
__haro_branch() { git branch --show-current 2>/dev/null | sed 's/.\{1,\}/ (&)/'; }
PS1='\[\e[1;32m\]\u@haro\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\[\e[33m\]$(__haro_branch)\[\e[0m\]\$ '
