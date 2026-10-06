# CI acceptance and runtime selection

The smoke, full ERT, release-audit, and installer workflows select Emacs
31.1. Windows jobs download the official GNU `emacs-31.1.zip` archive through
the shared `.github/actions/setup-emacs-windows` composite action and verify
the runtime reports exactly `31.1`. Their operating-system coverage and
installer behavior are unchanged; this selection does not raise the package's
declared compatibility floor.

Bisect subprocesses default to the running Emacs executable, resolved from
its invocation directory. `anvil-bisect-emacs-program` remains customizable.
Completion requires a terminal SHA header: both `# first bad commit:` and
Git 2.55's `# first 'bad' commit:` are supported. Possible-first candidates
from skipped commits are not conclusive.

For local validation, select the same Emacs for the parent process and
offload workers through PATH. Use a temporary root outside configured
index exclusions, such as `.cache`. For example, from this checkout:

```sh
TMPDIR=/tmp emacs -Q --batch -L . -L tests \
  -l tests/anvil-bisect-test.el -f ert-run-tests-batch-and-exit
```

All context handlers continue encoding results at registration. The release
audit declaration records this existing boundary; a JSON-RPC retrieval test
checks the actual MCP text response. The metrics token-entry helper is
internal and is named accordingly, rather than being classified as an MCP
tool. Source-audit regression tests explicitly inspect readable `.el` files.
