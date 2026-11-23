;;; anvil-stdio-retry-test.el --- emacsclient failures the stdio bridge retries -*- lexical-binding: t; -*-

;;; Commentary:

;; The bridge retries an emacsclient call that failed because no server
;; answered yet, as while Emacs restarts.  An error from Emacs itself is
;; retried for a while only for a request that reads, the handshake and
;; the lists, and reported at once for any other.  These tests run the
;; real anvil-stdio.sh against a fake emacsclient that fails its first
;; calls with a given message, so they need only bash and coreutils and
;; run on MS-Windows (MSYS2) as well.

;;; Code:

(require 'ert)

(defconst anvil-stdio-retry-test--script
  (expand-file-name "../anvil-stdio.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The stdio bridge under test.")

(defconst anvil-stdio-retry-test--lisp-error
  "*ERROR*: Symbol's function definition is void: anvil-server-process-jsonrpc\n"
  "What emacsclient prints when Anvil is not loaded in Emacs.")

(cl-defun anvil-stdio-retry-test--run (error &key (failures 1) (status 1)
                                             (request "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")
                                             (retries 3) log (set-log t))
  "Send REQUEST through the bridge to a fake emacsclient.
The fake fails its first FAILURES calls with STATUS, printing ERROR on
stderr, and answers the later ones.  The bridge retries an Emacs error
RETRIES times.  LOG, when non-nil, is a function called with the
contents of the failure log, or nil when there is none; SET-LOG nil
leaves ANVIL_FAILURE_LOG unset then.  Return a cons of the number of
calls the bridge made and its output."
  (let* ((bash (or (executable-find "bash") (ert-skip "bash unavailable")))
         (dir (make-temp-file "anvil-stdio-retry-" t))
         (log-file (expand-file-name "log/failures.log" dir))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "first-error" dir)
            (insert error))
          (with-temp-file (expand-file-name "emacsclient" dir)
            (insert "#!/usr/bin/env bash\n"
                    "dir=$(dirname \"$0\")\n"
                    "echo call >>\"$dir/calls\"\n"
                    (format "if [ \"$(wc -l <\"$dir/calls\")\" -le %d ]; then\n" failures)
                    "  cat \"$dir/first-error\" >&2\n"
                    (format "  exit %d\n" status)
                    "fi\n"
                    "reply='{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'\n"
                    "printf '\"%s\"\\n' \"$(printf '%s' \"$reply\" | base64 | tr -d '\\n')\"\n"))
          (set-file-modes (expand-file-name "emacsclient" dir) #o755)
          (setenv "PATH" (concat dir path-separator (getenv "PATH")))
          ;; Call the fake directly, without a timeout supervisor.
          (setenv "ANVIL_EMACSCLIENT_TIMEOUT" "0")
          (setenv "ANVIL_EMACSCLIENT_RETRY_MAX" "3")
          (setenv "ANVIL_EMACSCLIENT_RETRY_DELAY_MS" "0")
          (setenv "ANVIL_REQUEST_RETRY_MAX" (number-to-string retries))
          (setenv "ANVIL_REQUEST_RETRY_DELAY_MS" "0")
          (setenv "ANVIL_FAILURE_LOG" (and log set-log log-file))
          (with-temp-buffer
            (insert request "\n")
            (call-process-region (point-min) (point-max) bash t '(t nil) nil
                                 anvil-stdio-retry-test--script "--server-id=test")
            (when log
              (funcall log (and (file-exists-p log-file)
                                (with-temp-buffer
                                  (insert-file-contents log-file)
                                  (buffer-string)))))
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

(defun anvil-stdio-retry-test--should-not-retry (&rest args)
  "Check that the bridge reports at once a call made with ARGS.
ARGS are those of `anvil-stdio-retry-test--run', after the error."
  (pcase-let ((`(,calls . ,output)
               (apply #'anvil-stdio-retry-test--run anvil-stdio-retry-test--lisp-error args)))
    (should (= calls 1))
    (should (string-match-p "Bridge synthetic error" output))))

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

(ert-deftest anvil-stdio-retry-test/lisp-error-list-retried ()
  "An error from Emacs on a request that reads is retried."
  (anvil-stdio-retry-test--should-retry anvil-stdio-retry-test--lisp-error))

(ert-deftest anvil-stdio-retry-test/lisp-error-discover-retried ()
  "An error from Emacs on the 2026-07-28 handshake is retried.
A client pinned to that revision gives up on a failed server/discover."
  (pcase-let ((`(,calls . ,output)
               (anvil-stdio-retry-test--run
                anvil-stdio-retry-test--lisp-error :failures 2
                :request "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{}}}")))
    (should (= calls 3))
    (should (string-match-p "\"result\"" output))))

(ert-deftest anvil-stdio-retry-test/lisp-error-retries-end ()
  "An error from Emacs that lasts is reported after the retries."
  (pcase-let ((`(,calls . ,output)
               (anvil-stdio-retry-test--run anvil-stdio-retry-test--lisp-error
                                            :failures 100 :retries 2)))
    (should (= calls 3))
    (should (string-match-p "Bridge synthetic error" output))))

(ert-deftest anvil-stdio-retry-test/lisp-error-tool-call-not-retried ()
  "An error from Emacs on a tool call is reported at once.
The call may have run in part, so running it again could repeat it."
  (anvil-stdio-retry-test--should-not-retry
   :request "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emacs-eval\"}}"))

(ert-deftest anvil-stdio-retry-test/method-after-params-not-retried ()
  "A method that comes after a nested object is not trusted.
A tool call's arguments could otherwise pass for a list request."
  (anvil-stdio-retry-test--should-not-retry
   :request "{\"jsonrpc\":\"2.0\",\"id\":1,\"params\":{\"method\":\"tools/list\"},\"method\":\"tools/call\"}"))

(ert-deftest anvil-stdio-retry-test/other-status-not-retried ()
  "A failure other than an Emacs error, such as a timeout, is reported at once."
  (anvil-stdio-retry-test--should-not-retry :status 124))

(ert-deftest anvil-stdio-retry-test/failure-log ()
  "Each failed call is recorded on a line of ANVIL_FAILURE_LOG."
  (let (log)
    (anvil-stdio-retry-test--run anvil-stdio-retry-test--lisp-error
                                 :failures 2 :log (lambda (text) (setq log text)))
    (should (= (length (split-string log "\n" t)) 2))
    (should (string-match-p
             "server=test method=tools/list id=1 attempt=0 rc=1 stderr=\\*ERROR\\*: Symbol's function definition is void"
             log))
    (should (string-match-p "attempt=1 rc=1" log))))

(ert-deftest anvil-stdio-retry-test/no-failure-log-by-default ()
  "Without ANVIL_FAILURE_LOG, nothing is recorded."
  (let ((log 'unread))
    (anvil-stdio-retry-test--run anvil-stdio-retry-test--lisp-error
                                 :log (lambda (text) (setq log text)) :set-log nil)
    (should (null log))))

(provide 'anvil-stdio-retry-test)
;;; anvil-stdio-retry-test.el ends here
