# The account-log walkthrough

A standalone test that writes a whole account log by driving the real app:
an empty vault, a key sealed with a password, a display name staged and
published, an installation endorsed and published.

It exists because the doc-test harness drives one instance through a list of
actions in YAML, and every one of those actions is printed into the published
report. Driving a six-screen flow that way turns the report into a transcript
of clicks. Here the driving is a program, the report carries one assertion, and
the pictures the tutorial shows are this test's output.

| file | role |
|---|---|
| `run-walkthrough.mjs` | the driver: speaks the [logos-qt-mcp](https://github.com/logos-co/logos-qt-mcp) inspector protocol, drives the QML, captures each step |
| `run-walkthrough.sh` | launches the app offscreen on an empty vault and an in-process store, then runs the driver |
| `run-walkthrough-show.sh` | the `#walkthrough` flake app: runs the above, then holds the finished window open for the doc-test |
| `port-proxy.mjs` | opens the doc-test's capture port onto the live window, once there is something to capture |

Nothing here reaches past the QML a person sees. Controls are found by
`objectName` and clicked, fields are filled by writing their `text`, and the
account library is only ever called the way a button calls it. Each step waits
on the app's own state, never on a timer, and the run fails if a checkpoint is
missed: the key never appears, an edit is priced wrong, the store refuses the
update. So this is an end-to-end check as much as a screenshot generator.

## Running it

```bash
doctests/walkthrough/run-walkthrough.sh
```

Builds the app from this checkout, drives the walkthrough and writes
`01-add-an-account.png` through `06-installation-endorsed.png` into
`doctests/images`. That directory is build output, not source: CI runs this on
every push in the `walkthrough screenshots` job and lays what it captured beside
the published report, which is where the tutorial's figures resolve.

`OUT_DIR` or a first argument puts them somewhere else.

## How the doc-test uses it

The doc-test runs `nix run .#walkthrough`, which is `run-walkthrough-show.sh`:
the walkthrough happens on a private inspector port, and only when the log is
published does the port the doc-test attaches to open, proxied onto that live
window. So the window the doc-test screenshots holds a log that has really been
written, and the whole flow fits inside a launch wait rather than a capture
budget.
