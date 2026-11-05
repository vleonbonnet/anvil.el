;;; anvil-server-deferred-test.el --- ERT for deferred tool answers -*- lexical-binding: t; -*-

;;; Commentary:

;; A tool whose answer comes later returns `anvil-server-defer' rather
;; than wait in Emacs.  The dispatcher answers "anvil-deferred:JOB:SECONDS",
;; `anvil-server-deferred-poll' returns "-" until the answer is there,
;; then the JSON-RPC response, made by dispatching the request again with
;; the answer.  The stdio bridge holds the request meanwhile, polling,
;; while it answers others: the end-to-end test runs the bridge against
;; a server in this batch Emacs.

;;; Code:

(require 'ert)
(require 'json)
(require 'server)
(require 'anvil)
(require 'anvil-server)

(defconst anvil-server-deferred-test--server "deferred-test"
  "Server id of the tools of these tests.")

(defvar anvil-server-deferred-test--answer nil
  "The answer of the deferring tool, nil while it has none.")

(defvar anvil-server-deferred-test--cancelled nil
  "Non-nil once the deferring tool's cancel function ran.")

(defvar anvil-server-deferred-test--meta nil
  "The `_meta' the deferring tool saw.")

(defun anvil-server-deferred-test--later (word)
  "Answer WORD once `anvil-server-deferred-test--answer' is set.

MCP Parameters:
  word - a word the answer begins with"
  (setq anvil-server-deferred-test--meta anvil-server-request-meta)
  (if (not (anvil-server-can-defer-p))
      (concat word ": now")
    (anvil-server-defer (lambda ()
                          (pcase anvil-server-deferred-test--answer
                            ('nil nil)
                            ('fail (error "The answer failed"))
                            (answer (concat word ": " answer))))
                        :seconds 30
                        :cancel (lambda () (setq anvil-server-deferred-test--cancelled t)))))

(defun anvil-server-deferred-test--now (word)
  "Answer WORD at once.

MCP Parameters:
  word - the answer"
  word)

(defmacro anvil-server-deferred-test--with-tools (&rest body)
  "Run BODY with the tools of these tests registered, and fresh state."
  (declare (indent 0))
  `(let ((anvil-server--running t)
         (anvil-server--deferred (make-hash-table :test #'equal))
         (anvil-server-deferred-test--answer nil)
         (anvil-server-deferred-test--cancelled nil)
         (anvil-server-deferred-test--meta nil))
     (anvil-server-register-tool #'anvil-server-deferred-test--later
                                 :id "later" :description "Answer later."
                                 :server-id anvil-server-deferred-test--server)
     (anvil-server-register-tool #'anvil-server-deferred-test--now
                                 :id "now" :description "Answer now."
                                 :server-id anvil-server-deferred-test--server)
     (unwind-protect
         (progn ,@body)
       (anvil-server-unregister-tool "later" anvil-server-deferred-test--server)
       (anvil-server-unregister-tool "now" anvil-server-deferred-test--server))))

(defun anvil-server-deferred-test--call (id tool word &optional meta)
  "Return the JSON-RPC text calling TOOL with WORD, request ID, `_meta' META."
  (json-encode `((jsonrpc . "2.0") (id . ,id) (method . "tools/call")
                 (params . ((name . ,tool)
                            (arguments . ((word . ,word)))
                            ,@(and meta `((_meta . ,meta))))))))

(defun anvil-server-deferred-test--text (response)
  "Return the text of the tool result in RESPONSE, a JSON-RPC text."
  (let ((parsed (json-read-from-string response)))
    (alist-get 'text (aref (alist-get 'content (alist-get 'result parsed)) 0))))

(defun anvil-server-deferred-test--job (reply)
  "Return the job of REPLY, a deferral, or fail."
  (should (string-match "\\`anvil-deferred:\\([^:]+\\):\\([0-9]+\\)\\'" reply))
  (should (equal (match-string 2 reply) "30"))
  (match-string 1 reply))

(ert-deftest anvil-server-deferred-test-answers-later ()
  "A deferred call answers once its poll does, with the request's id."
  (anvil-server-deferred-test--with-tools
    (let* ((reply (let ((anvil-server-deferrable t))
                    (anvil-server-process-jsonrpc
                     (anvil-server-deferred-test--call 7 "later" "hello"
                                                       '((ai.opencode/sessionID . "ses_1")))
                     anvil-server-deferred-test--server)))
           (job (anvil-server-deferred-test--job reply)))
      (should (equal (alist-get 'ai.opencode/sessionID anvil-server-deferred-test--meta) "ses_1"))
      (should (equal (anvil-server-deferred-poll job) "-"))
      (should (equal (anvil-server-deferred-poll job) "-"))
      (setq anvil-server-deferred-test--answer "world")
      (let ((response (anvil-server-deferred-poll job)))
        (should (equal (alist-get 'id (json-read-from-string response)) 7))
        (should (equal (anvil-server-deferred-test--text response) "hello: world")))
      ;; Answered once, the job is gone.
      (should (equal (anvil-server-deferred-poll job) "?"))
      (should-not anvil-server-deferred-test--cancelled))))

(ert-deftest anvil-server-deferred-test-error-answers-as-tool-error ()
  "A poll signalling answers as the handler's error would."
  (anvil-server-deferred-test--with-tools
    (let ((job (anvil-server-deferred-test--job
                (let ((anvil-server-deferrable t))
                  (anvil-server-process-jsonrpc
                   (anvil-server-deferred-test--call "r-1" "later" "x")
                   anvil-server-deferred-test--server)))))
      (setq anvil-server-deferred-test--answer 'fail)
      (let ((parsed (json-read-from-string (anvil-server-deferred-poll job))))
        (should (equal (alist-get 'id parsed) "r-1"))
        (should (string-match-p "The answer failed"
                                (format "%S" (or (alist-get 'error parsed)
                                                 (alist-get 'result parsed)))))))))

(ert-deftest anvil-server-deferred-test-without-deferrable-transport ()
  "A transport that cannot wait gets the immediate answer, and meta is unbound after."
  (anvil-server-deferred-test--with-tools
    (should (equal (anvil-server-deferred-test--text
                    (anvil-server-process-jsonrpc
                     (anvil-server-deferred-test--call 1 "later" "hi")
                     anvil-server-deferred-test--server))
                   "hi: now"))
    (should-not anvil-server-request-meta)
    (should (zerop (hash-table-count anvil-server--deferred)))))

(ert-deftest anvil-server-deferred-test-abandoned-cancelled ()
  "A deferred answer no one polls is forgotten, its cancel function run."
  (anvil-server-deferred-test--with-tools
    (let ((job (anvil-server-deferred-test--job
                (let ((anvil-server-deferrable t))
                  (anvil-server-process-jsonrpc
                   (anvil-server-deferred-test--call 2 "later" "x")
                   anvil-server-deferred-test--server)))))
      (plist-put (gethash job anvil-server--deferred) :polled
                 (- (float-time) anvil-server-deferred-abandon-seconds 1))
      (should (equal (anvil-server-deferred-poll "unknown") "?"))
      (should anvil-server-deferred-test--cancelled)
      (should (equal (anvil-server-deferred-poll job) "?")))))

(ert-deftest anvil-server-deferred-test-cancel ()
  "Cancelling a deferred answer runs its cancel function once."
  (anvil-server-deferred-test--with-tools
    (let ((job (anvil-server-deferred-test--job
                (let ((anvil-server-deferrable t))
                  (anvil-server-process-jsonrpc
                   (anvil-server-deferred-test--call 3 "later" "x")
                   anvil-server-deferred-test--server)))))
      (should (equal (anvil-server-deferred-cancel job) "ok"))
      (should anvil-server-deferred-test--cancelled)
      (should (equal (anvil-server-deferred-poll job) "?")))))

;;;; Through the stdio bridge

(defun anvil-server-deferred-test--read-response (process buffer id deadline)
  "Return the JSON-RPC response of id ID PROCESS wrote to BUFFER, by DEADLINE.
Each response is a line; those read are removed from BUFFER."
  (catch 'found
    (while (< (float-time) deadline)
      (with-current-buffer buffer
        (goto-char (point-min))
        (while (re-search-forward "^\\({.*}\\)\n" nil t)
          (let* ((line (match-string 1))
                 (parsed (ignore-errors (json-read-from-string line))))
            (when (equal (alist-get 'id parsed) id)
              (delete-region (match-beginning 0) (match-end 0))
              (throw 'found parsed)))))
      (accept-process-output process 0.05))
    nil))

(ert-deftest anvil-server-deferred-test-bridge-holds-and-answers-others ()
  "The bridge answers other requests while it holds a deferred one."
  (unless (and (executable-find "bash") (executable-find "emacsclient") (executable-find "base64"))
    (ert-skip "bash, emacsclient or base64 unavailable"))
  (anvil-server-deferred-test--with-tools
    (let* ((server-socket-dir (make-temp-file "anvil-deferred-socket" t))
           (server-name (format "anvil-deferred-%d" (emacs-pid)))
           (script (expand-file-name "../anvil-stdio.sh"
                                     (file-name-directory (or load-file-name buffer-file-name
                                                              (locate-library "anvil-server-deferred-test")))))
           (script (if (file-exists-p script) script
                     (expand-file-name "anvil-stdio.sh"
                                       (file-name-directory (locate-library "anvil-server")))))
           (output (generate-new-buffer " *anvil-bridge*"))
           (process nil))
      (unwind-protect
          (progn
            (server-start)
            (setq process
                  (make-process :name "anvil-bridge" :buffer output :connection-type 'pipe
                                :noquery t :stderr (get-buffer-create " *anvil-bridge-err*")
                                :command (list "bash" script
                                               (concat "--socket=" (expand-file-name server-name server-socket-dir))
                                               (concat "--server-id=" anvil-server-deferred-test--server))))
            (process-send-string process (concat (anvil-server-deferred-test--call 11 "later" "held") "\n"))
            (process-send-string process (concat (anvil-server-deferred-test--call 12 "now" "quick") "\n"))
            (let ((quick (anvil-server-deferred-test--read-response process output 12 (+ (float-time) 20))))
              (should quick)
              (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result quick)) 0))
                             "quick")))
            ;; Held, not answered, while the answer is not there.
            (should-not (anvil-server-deferred-test--read-response process output 11 (+ (float-time) 1.5)))
            (should (= (hash-table-count anvil-server--deferred) 1))
            (setq anvil-server-deferred-test--answer "done")
            (let ((held (anvil-server-deferred-test--read-response process output 11 (+ (float-time) 20))))
              (should held)
              (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result held)) 0))
                             "held: done")))
            (should (zerop (hash-table-count anvil-server--deferred)))
            ;; A cancelled request's poller stops, its job cancelled.
            (setq anvil-server-deferred-test--answer nil)
            (process-send-string process (concat (anvil-server-deferred-test--call 13 "later" "gone") "\n"))
            (let ((deadline (+ (float-time) 10)))
              (while (and (zerop (hash-table-count anvil-server--deferred)) (< (float-time) deadline))
                (accept-process-output process 0.05)))
            (should (= (hash-table-count anvil-server--deferred) 1))
            (process-send-string
             process
             "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":13}}\n")
            (let ((deadline (+ (float-time) 10)))
              (while (and (not anvil-server-deferred-test--cancelled) (< (float-time) deadline))
                (accept-process-output process 0.05)))
            (should anvil-server-deferred-test--cancelled)
            (should (zerop (hash-table-count anvil-server--deferred)))
            (setq anvil-server-deferred-test--answer "late")
            (should-not (anvil-server-deferred-test--read-response process output 13 (+ (float-time) 3)))
            (process-send-eof process)
            (let ((deadline (+ (float-time) 10)))
              (while (and (process-live-p process) (< (float-time) deadline))
                (accept-process-output process 0.05)))
            (should-not (process-live-p process)))
        (when (process-live-p process)
          (delete-process process))
        (server-force-delete)
        (kill-buffer output)
        (delete-directory server-socket-dir t)))))

(provide 'anvil-server-deferred-test)
;;; anvil-server-deferred-test.el ends here
