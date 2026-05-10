#!/usr/bin/env bash
: <<DOCXX
Add description
Author: morgan@morganism.dev
Date: Sat 18 Apr 2026 17:20:40 BST

This script is intended to be run when it resides on the local file system as well as remotely,
curl -fsSL https://raw.githubusercontent.com/morganism/init/refs/heads/master/bootstrap.sh | bash
so it needs to know if it is alone or not and take inventory of the system on which it is running
in order to ensure ensure all dependencies are satisfied and determine operational mode.

The operational mode should be determined by this script and based on current state at any given time.
This script must bei able run idempotently such that it can be killed and restarted safely and proceed 
deterministically as a finite state automaton.

** A [potentially] infinite loop that checks a message queue for instruction about what to do next, and
ALWAYS performs a seris of "core" tasks such as: CHECK_QUEUE (CONSUME), GET_TASK_FROM_QUEUE, EXECUTE_TASK, 
RESASSESS_PROGRESS, PUT_TASK_ON_QUEUE (PRODUCE), LOGGING, HOUSEKEEPING (ensure state data, check dependencies, 
organise queued tasks, determine current state, etc ... ) 

That is the ideal tool. Simplify.
	
DOCXX


echo "Hello world."
