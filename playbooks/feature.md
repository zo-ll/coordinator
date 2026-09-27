---
kind=feature
brief.require=GOAL,SCOPE,ACCEPTANCE,VERIFY
evidence.floor=tests
timebox=60m
lane=default
---
## worker
Start from the data shape: name the types and the one call a consumer makes
before writing the implementation. Add tests for the new behavior that fail
without your change. Stay inside SCOPE; anything else you notice goes in your
summary, not the diff.

## critic
Check every ACCEPTANCE line against the code and a run, not the summary.
Confirm the new tests exercise the behavior (break it and watch them fail if
that is cheap). Out-of-scope changes are a handback.
