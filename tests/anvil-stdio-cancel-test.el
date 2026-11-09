;;; anvil-stdio-cancel-test.el --- The stdio bridge and cancelled requests -*- lexical-binding: t; -*-

;;; Commentary:

;; A client that gives up waiting for an answer sends
;; notifications/cancelled, and Claude Code, which gives up after 30 s,
;; drops the connection when the answer comes anyway ("Received a
;; response for an unknown message ID").  It then has none of the
;; server's tools, and does not reconnect.  The bridge answers one
;; request at a time, so these tests send a request, its cancellation
;; and a later request at once: the bridge must drop the cancelled
;; answer, announce a list it dropped as changed so that the client
;; lists again, and answer the later request.  They run the real
;; anvil-stdio.sh against tests/anvil-stdio-fake-emacsclient.sh, so
;; they need only bash and coreutils and run on MS-Windows (MSYS2) as
;; well.  The last test checks which programs a request starts.

;;; Code:

(require 'ert)
(require 'json)
(require 'subr-x)

(defconst anvil-stdio-cancel-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of these tests.")

(defconst anvil-stdio-cancel-test--script
  (expand-file-name "../anvil-stdio.sh" anvil-stdio-cancel-test--dir)
  "The stdio bridge under test.")

(defun anvil-stdio-cancel-test--programs (bash dir)
  "Return an alist of the programs the tests use, as BASH finds them.
DIR is a scratch directory.  The names are bash's own (POSIX names
under MSYS2), so that scripts it runs can start them."
  (let ((probe (expand-file-name "probe.sh" dir)))
    (with-temp-file probe
      (insert "for p in bash base64 sleep timeout rm; do\n"
              "  printf '%s %s\\n' \"$p\" \"$(command -v \"$p\")\"\n"
              "done\n"))
    (with-temp-buffer
      (call-process bash nil t nil probe)
      (delq nil
            (mapcar (lambda (line)
                      (let ((fields (split-string line " " t)))
                        (and (cadr fields) (cons (car fields) (cadr fields)))))
                    (split-string (buffer-string) "\n" t))))))

(defun anvil-stdio-cancel-test--write-script (file bash &rest lines)
  "Write LINES to FILE as an executable script run by BASH."
  (with-temp-file file
    (insert "#!" bash "\n" (string-join lines "\n") "\n"))
  (set-file-modes file #o755))

(defmacro anvil-stdio-cancel-test--with-fake (spec &rest body)
  "Run BODY with a fake emacsclient in a scratch directory.
SPEC is (DIR ENV BASH): DIR is bound to the directory, holding the
fake as `emacsclient', ENV to the environment entries the bridge
needs (the fake's programs, TMPDIR, no timeout supervisor, DIR first
on PATH), and BASH to the bash running the bridge."
  (declare (indent 1))
  (let ((dir (nth 0 spec)) (env (nth 1 spec)) (bash (nth 2 spec)))
    `(let* ((,bash (or (executable-find "bash") (ert-skip "bash unavailable")))
            (,dir (make-temp-file "anvil-stdio-cancel-" t)))
       (unwind-protect
           (let* ((programs (anvil-stdio-cancel-test--programs ,bash ,dir))
                  (,env (list (concat "FAKE_BASE64=" (or (cdr (assoc "base64" programs))
                                                         (ert-skip "base64 unavailable")))
                              (concat "FAKE_SLEEP=" (or (cdr (assoc "sleep" programs))
                                                        (ert-skip "sleep unavailable")))
                              (concat "TMPDIR=" ,dir)
                              "ANVIL_EMACSCLIENT_TIMEOUT=0"
                              (concat "PATH=" ,dir path-separator (getenv "PATH")))))
             (with-temp-buffer
               (insert-file-contents (expand-file-name "anvil-stdio-fake-emacsclient.sh"
                                                       anvil-stdio-cancel-test--dir))
               (goto-char (point-min))
               (delete-region (point) (line-end-position))
               (insert "#!" (cdr (assoc "bash" programs)))
               (write-region nil nil (expand-file-name "emacsclient" ,dir) nil 'silent))
             (set-file-modes (expand-file-name "emacsclient" ,dir) #o755)
             ,@body)
         (delete-directory ,dir t)))))

(defun anvil-stdio-cancel-test--input (&rest messages)
  "Return MESSAGES, JSON-RPC texts, as the lines a client writes."
  (mapconcat (lambda (message) (concat message "\n")) messages ""))

(defun anvil-stdio-cancel-test--cancel (id)
  "Return the notification cancelling request ID, as Claude Code words it."
  (format "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":%s,\"reason\":\"McpError: MCP error -32001: Request timed out\"}}"
          id))

(defun anvil-stdio-cancel-test--request (id method)
  "Return the request ID calling METHOD, as Claude Code words it."
  (format "{\"method\":%S,\"jsonrpc\":\"2.0\",\"id\":%s}" method id))

(defun anvil-stdio-cancel-test--parse (output)
  "Return the messages in OUTPUT, the bridge's lines, parsed."
  (mapcar #'json-read-from-string (split-string output "\n" t)))

(defun anvil-stdio-cancel-test--answer (messages id)
  "Return the answer to request ID among MESSAGES, or nil."
  (seq-find (lambda (message) (equal (alist-get 'id message) id)) messages))

(defun anvil-stdio-cancel-test--methods (messages)
  "Return the methods of the notifications among MESSAGES."
  (delq nil (mapcar (lambda (message) (alist-get 'method message)) messages)))

(defun anvil-stdio-cancel-test--run (env bash input)
  "Run the bridge in ENV with BASH on INPUT, all of it waiting; return its messages."
  (let ((process-environment (append env process-environment)))
    (with-temp-buffer
      (insert input)
      (call-process-region (point-min) (point-max) bash t '(t nil) nil
                           anvil-stdio-cancel-test--script "--server-id=test")
      (anvil-stdio-cancel-test--parse (buffer-string)))))

(ert-deftest anvil-stdio-cancel-test/tools-list-relisted ()
  "A tools/list answer the client cancelled is dropped and the tools announced changed."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let ((messages (anvil-stdio-cancel-test--run
                     env bash
                     (anvil-stdio-cancel-test--input
                      (anvil-stdio-cancel-test--request 1 "tools/list")
                      (anvil-stdio-cancel-test--cancel 1)
                      (anvil-stdio-cancel-test--request 2 "ping")))))
      (should-not (anvil-stdio-cancel-test--answer messages 1))
      (should (anvil-stdio-cancel-test--answer messages 2))
      (should (equal (anvil-stdio-cancel-test--methods messages)
                     '("notifications/tools/list_changed"))))))

(ert-deftest anvil-stdio-cancel-test/resources-list-relisted ()
  "A resources/list answer the client cancelled is dropped and the resources announced changed."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let ((messages (anvil-stdio-cancel-test--run
                     env bash
                     (anvil-stdio-cancel-test--input
                      (anvil-stdio-cancel-test--request 1 "resources/list")
                      (anvil-stdio-cancel-test--cancel 1)
                      (anvil-stdio-cancel-test--request 2 "ping")))))
      (should-not (anvil-stdio-cancel-test--answer messages 1))
      (should (anvil-stdio-cancel-test--answer messages 2))
      (should (equal (anvil-stdio-cancel-test--methods messages)
                     '("notifications/resources/list_changed"))))))

(ert-deftest anvil-stdio-cancel-test/call-dropped ()
  "Any other answer the client cancelled is dropped, an error the bridge makes too."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let ((messages (anvil-stdio-cancel-test--run
                     env bash
                     (anvil-stdio-cancel-test--input
                      (anvil-stdio-cancel-test--request 1 "tools/call")
                      (anvil-stdio-cancel-test--cancel 1)
                      (anvil-stdio-cancel-test--request "\"r-2\"" "fail")
                      (anvil-stdio-cancel-test--cancel "\"r-2\"")
                      (anvil-stdio-cancel-test--request 3 "ping")))))
      (should (equal (mapcar (lambda (message) (alist-get 'id message)) messages)
                     '(3))))))

(ert-deftest anvil-stdio-cancel-test/uncancelled-answered ()
  "Answers the client still waits for are all sent, in order."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let ((messages (anvil-stdio-cancel-test--run
                     env bash
                     (anvil-stdio-cancel-test--input
                      (anvil-stdio-cancel-test--request 1 "tools/list")
                      (anvil-stdio-cancel-test--cancel 7)
                      (anvil-stdio-cancel-test--request 2 "fail")
                      (anvil-stdio-cancel-test--request 3 "ping")))))
      (should (equal (mapcar (lambda (message) (alist-get 'id message)) messages)
                     '(1 2 3)))
      (should (alist-get 'tools (alist-get 'result (car messages))))
      (should (string-match-p "Bridge synthetic error"
                              (alist-get 'message (alist-get 'error (cadr messages))))))))

(ert-deftest anvil-stdio-cancel-test/pipe-left-open ()
  "Over a pipe the client keeps open, the cancellation is seen and the next request answered.
`read -t 0' tells whether a pipe holds input: it must neither miss
the waiting cancellation nor wait for input that is not there."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let* ((process-environment (append (list "FAKE_FIRST_DELAY=1") env process-environment))
           (output (generate-new-buffer " *anvil-stdio-cancel-out*"))
           (errors (generate-new-buffer " *anvil-stdio-cancel-err*"))
           (process (make-process :name "anvil-stdio-cancel" :buffer output
                                  :stderr errors :connection-type 'pipe :noquery t
                                  :command (list bash anvil-stdio-cancel-test--script
                                                 "--server-id=test")))
           (deadline (+ (float-time) 30))
           (messages nil))
      (unwind-protect
          (progn
            (process-send-string
             process
             (anvil-stdio-cancel-test--input
              (anvil-stdio-cancel-test--request 1 "tools/list")
              (anvil-stdio-cancel-test--cancel 1)
              (anvil-stdio-cancel-test--request 2 "ping")))
            ;; The input stays open: the answer to 2 must not wait for more.
            (while (and (< (float-time) deadline)
                        (not (anvil-stdio-cancel-test--answer messages 2)))
              (accept-process-output process 0.1)
              (setq messages (anvil-stdio-cancel-test--parse
                              (with-current-buffer output (buffer-string)))))
            (should (process-live-p process))
            (should (anvil-stdio-cancel-test--answer messages 2))
            (should-not (anvil-stdio-cancel-test--answer messages 1))
            (should (equal (anvil-stdio-cancel-test--methods messages)
                           '("notifications/tools/list_changed")))
            (process-send-eof process)
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1))
            (should-not (process-live-p process)))
        (when (process-live-p process)
          (delete-process process))
        (kill-buffer output)
        (kill-buffer errors)))))

(ert-deftest anvil-stdio-cancel-test/programs-per-request ()
  "A request starts base64, timeout, emacsclient and base64 again, and no other program.
Starting a program costs about 0.1 s under MSYS2, and the bridge's
command substitutions and pipelines once started a dozen per request.
The bridge runs with a PATH holding only logging wrappers for the
programs it may start, and the fake emacsclient."
  (anvil-stdio-cancel-test--with-fake (dir env bash)
    (let* ((programs (anvil-stdio-cancel-test--programs bash dir))
           (posix-bash (cdr (assoc "bash" programs)))
           (calls (expand-file-name "calls" dir)))
      (unless (cdr (assoc "timeout" programs))
        (ert-skip "timeout unavailable"))
      (dolist (name '("base64" "timeout" "rm"))
        (anvil-stdio-cancel-test--write-script
         (expand-file-name name dir) posix-bash
         (format "printf '%%s\\n' %s >>\"${0%%/*}/calls\"" name)
         (format "exec %s \"$@\"" (cdr (assoc name programs)))))
      (let* ((env (append (list (concat "PATH=" dir) "ANVIL_EMACSCLIENT_TIMEOUT=30")
                          (seq-remove (lambda (entry)
                                        (string-match-p "\\`\\(PATH\\|ANVIL_EMACSCLIENT_TIMEOUT\\)=" entry))
                                      env)))
             (messages (anvil-stdio-cancel-test--run
                        env bash
                        (anvil-stdio-cancel-test--input
                         (anvil-stdio-cancel-test--request 1 "tools/list")
                         "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                         (anvil-stdio-cancel-test--request 2 "ping")))))
        (should (anvil-stdio-cancel-test--answer messages 1))
        (should (anvil-stdio-cancel-test--answer messages 2))
        (should (equal (with-temp-buffer
                         (insert-file-contents calls)
                         (split-string (buffer-string) "\n" t))
                       (append '("base64")
                               (apply #'append
                                      (make-list 3 '("base64" "timeout" "emacsclient" "base64")))
                               '("rm"))))))))

(provide 'anvil-stdio-cancel-test)
;;; anvil-stdio-cancel-test.el ends here
