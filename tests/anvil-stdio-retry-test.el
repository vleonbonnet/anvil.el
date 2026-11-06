;;; anvil-stdio-retry-test.el --- emacsclient failures the stdio bridge retries -*- lexical-binding: t; -*-

;;; Commentary:

;; The bridge retries an emacsclient call that failed because no server
;; answered yet, as while Emacs restarts, and reports any other failure
;; at once.  These tests run the real anvil-stdio.sh against a fake
;; emacsclient that fails its first call with a given message, so they
;; need only bash and coreutils and run on MS-Windows (MSYS2) as well.

;;; Code:

(require 'ert)

(defconst anvil-stdio-retry-test--script
  (expand-file-name "../anvil-stdio.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The stdio bridge under test.")

(defun anvil-stdio-retry-test--run (first-error)
  "Send one request through the bridge to a fake emacsclient.
The fake fails its first call, printing FIRST-ERROR on stderr, and
answers the later ones.  Return a cons of the number of calls the
bridge made and its output."
  (let* ((bash (or (executable-find "bash") (ert-skip "bash unavailable")))
         (dir (make-temp-file "anvil-stdio-retry-" t))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "first-error" dir)
            (insert first-error))
          (with-temp-file (expand-file-name "emacsclient" dir)
            (insert "#!/usr/bin/env bash\n"
                    "dir=$(dirname \"$0\")\n"
                    "echo call >>\"$dir/calls\"\n"
                    "if [ \"$(wc -l <\"$dir/calls\")\" -eq 1 ]; then\n"
                    "  cat \"$dir/first-error\" >&2\n"
                    "  exit 1\n"
                    "fi\n"
                    "reply='{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'\n"
                    "printf '\"%s\"\\n' \"$(printf '%s' \"$reply\" | base64 | tr -d '\\n')\"\n"))
          (set-file-modes (expand-file-name "emacsclient" dir) #o755)
          (setenv "PATH" (concat dir path-separator (getenv "PATH")))
          ;; Call the fake directly, without a timeout supervisor.
          (setenv "ANVIL_EMACSCLIENT_TIMEOUT" "0")
          (setenv "ANVIL_EMACSCLIENT_RETRY_MAX" "3")
          (setenv "ANVIL_EMACSCLIENT_RETRY_DELAY_MS" "0")
          (with-temp-buffer
            (insert "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n")
            (call-process-region (point-min) (point-max) bash t '(t nil) nil
                                 anvil-stdio-retry-test--script "--server-id=test")
            (cons (with-temp-buffer
                    (insert-file-contents (expand-file-name "calls" dir))
                    (count-lines (point-min) (point-max)))
                  (buffer-string))))
      (delete-directory dir t))))

(defun anvil-stdio-retry-test--should-retry (first-error)
  "Check that the bridge retries a call that failed with FIRST-ERROR."
  (pcase-let ((`(,calls . ,output) (anvil-stdio-retry-test--run first-error)))
    (should (= calls 2))
    (should (string-match-p "\"result\"" output))))

(ert-deftest anvil-stdio-retry-test/no-socket ()
  "A missing local socket is retried."
  (anvil-stdio-retry-test--should-retry
   "emacsclient: can't find socket; have you started the server?\n"))

(ert-deftest anvil-stdio-retry-test/w32-connection-refused ()
  "A refused connection is retried, as emacsclient reports it on MS-Windows."
  (anvil-stdio-retry-test--should-retry
   (concat "emacsclient.exe: connect: No connection could be made because"
           " the target machine actively refused it.\r\n\n"
           "emacsclient.exe: No socket or alternate editor.  Please use:\n")))

(ert-deftest anvil-stdio-retry-test/w32-connect-error-localized ()
  "A connection error in another language is retried.
MS-Windows words the reason in the system's language."
  (anvil-stdio-retry-test--should-retry
   (concat "emacsclient.exe: connect: Es konnte keine Verbindung hergestellt"
           " werden, da der Zielcomputer die Verbindung verweigerte.\r\n")))

(ert-deftest anvil-stdio-retry-test/w32-no-server-file ()
  "A server file not written yet is retried, as on MS-Windows."
  (anvil-stdio-retry-test--should-retry
   "emacsclient.exe: error accessing server file \"c:/Users/u/.emacs.d/server/server\"\n"))

(ert-deftest anvil-stdio-retry-test/lisp-error-not-retried ()
  "An error from Emacs itself is reported at once."
  (pcase-let ((`(,calls . ,output)
               (anvil-stdio-retry-test--run
                "*ERROR*: Symbol's function definition is void: anvil-server-process-jsonrpc\n")))
    (should (= calls 1))
    (should (string-match-p "Bridge synthetic error" output))))

(provide 'anvil-stdio-retry-test)
;;; anvil-stdio-retry-test.el ends here
