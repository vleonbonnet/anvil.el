;;; anvil-server-inline-result-test.el --- Inline tool result cap tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'json)
(require 'anvil)
(require 'anvil-server)
(require 'anvil-server-metrics)

;; Keep the first dispatcher regression runnable on the pre-implementation
;; baseline so it demonstrates the missing behavior without relying on helpers.
(defvar anvil-server-max-inline-result-bytes (* 2 1024 1024))

(defun anvil-server-inline-result-test--large-result ()
  "Return a result larger than the configured inline limit."
  (make-string 32 ?x))

(defvar anvil-server-inline-result-test--handler-result nil)
(defvar anvil-server-inline-result-test--disclosure-result nil)
(defvar anvil-server-inline-result-test--disclosure-calls 0)

(defun anvil-server-inline-result-test--result-handler ()
  "Return the dynamically selected test result."
  anvil-server-inline-result-test--handler-result)

(defun anvil-server-inline-result-test--invoke (limit value &optional expanded)
  "Call the test tool with LIMIT, VALUE, and optional disclosure EXPANDED.
Return (RESPONSE METRICS PAYLOAD-COUNT CALLS HOOK-COUNT)."
  (let ((anvil-server-max-inline-result-bytes limit)
        (anvil-server-inline-result-test--handler-result value)
        (anvil-server-inline-result-test--disclosure-result expanded)
        (anvil-server-inline-result-test--disclosure-calls 0)
        (payload-count 0)
        (payload-text nil)
        (error-hook-count 0)
        (calls nil)
        (hook-count 0)
        (metrics (make-anvil-server-metrics)))
    (anvil-server-register-tool
     #'anvil-server-inline-result-test--result-handler
     :id "inline-result-test-tool"
     :description "Test tool"
     :server-id "inline-result-test")
    (unwind-protect
        (let ((anvil-server-tool-dispatch-hook
               (list (lambda (&rest _args) (cl-incf hook-count)))))
          (let ((response
                 (cl-letf (((symbol-function
                             'anvil-server-metrics--track-tool-payload)
                            (lambda (_tool-id _request response)
                              (cl-incf payload-count)
                              (setq payload-text response)))
                           ((symbol-function
                             'anvil-server-metrics--track-tool-call)
                            (lambda (tool-id &optional is-error)
                              (push (cons tool-id is-error) calls)))
                           ((symbol-function 'anvil-disclosure-budget-apply)
                            (lambda (_tool-id text)
                              (cl-incf anvil-server-inline-result-test--disclosure-calls)
                              (or anvil-server-inline-result-test--disclosure-result
                                  text)))
                           ((symbol-function 'anvil-server--run-tool-error-hook)
                            (lambda (&rest _args) (cl-incf error-hook-count))))
                   (json-read-from-string
                    (anvil-server--handle-tools-call
                     7 '((name . "inline-result-test-tool") (arguments))
                     metrics "inline-result-test")))))
            (list response metrics payload-count (nreverse calls) hook-count
                  anvil-server-inline-result-test--disclosure-calls
                  payload-text error-hook-count)))
      (anvil-server-unregister-tool
       "inline-result-test-tool" "inline-result-test"))))

(defun anvil-server-inline-result-test--response-text (response)
  "Return the first text block from a successful tool result RESPONSE."
  (alist-get 'text
             (aref (alist-get 'content (alist-get 'result response)) 0)))

(defun anvil-server-inline-result-test--json-text-bytes (text)
  "Return GNU Emacs's actual encoded JSON string bytes for TEXT, excluding quotes."
  (- (string-bytes
      (encode-coding-string (json-encode-string text) 'utf-8 t))
     2))

(ert-deftest anvil-server-inline-result-test-dispatch-rejects-oversized-result ()
  "Oversized successful tool text is rejected before successful accounting."
  (let ((anvil-server-max-inline-result-bytes 8)
        (payload-calls 0)
        (dispatch-calls 0))
    (anvil-server-register-tool
     #'anvil-server-inline-result-test--large-result
     :id "inline-result-large"
     :description "Test tool"
     :server-id "inline-result-test")
    (unwind-protect
        (let* ((anvil-server-tool-dispatch-hook
                (list (lambda (&rest _args) (cl-incf dispatch-calls))))
               (response
                (cl-letf (((symbol-function
                            'anvil-server-metrics--track-tool-payload)
                           (lambda (&rest _args) (cl-incf payload-calls))))
                  (json-read-from-string
                   (anvil-server--handle-tools-call
                    7 '((name . "inline-result-large") (arguments))
                    (make-anvil-server-metrics)
                    "inline-result-test"))))
               (result (alist-get 'result response)))
          (should (eq (alist-get 'isError result) t))
          (should (= payload-calls 0))
          (should (= dispatch-calls 0)))
      (anvil-server-unregister-tool
       "inline-result-large" "inline-result-test"))))

(ert-deftest anvil-server-inline-result-test-projector-matches-json-encoder ()
  "The projector matches actual escaped UTF-8 byte counts on GNU Emacs."
  (let ((samples
         (list
          (apply #'string (number-sequence 0 127))
          "quote: \" slash: \\ accent: é CJK: 漢 astral: 𝄞"
          (apply #'unibyte-string (number-sequence 128 255))
          (string-to-multibyte (apply #'unibyte-string (number-sequence 128 255)))
          (string #x3fffff))))
    (dolist (text samples)
      (should (= (anvil-server--projected-json-string-bytes text)
                 (anvil-server-inline-result-test--json-text-bytes text))))))

(ert-deftest anvil-server-inline-result-test-projector-stops-without-encoding ()
  "A bounded projection stops early and never calls a JSON encoder."
  (let ((text (make-string 100000 ?x)))
    (cl-letf (((symbol-function 'json-encode-string)
               (lambda (&rest _args) (ert-fail "encoder called"))))
      (should (= (anvil-server--projected-json-string-bytes text 8) 9)))))

(ert-deftest anvil-server-inline-result-test-exact-limit-and-one-over ()
  "Text at the byte limit succeeds and one escaped byte over is rejected."
  (let* ((exact (anvil-server-inline-result-test--invoke 4 "ab\\"))
         (over (anvil-server-inline-result-test--invoke 4 "abcde")))
    (should (eq (alist-get 'isError (alist-get 'result (car exact))) :json-false))
    (should (equal (anvil-server-inline-result-test--response-text (car exact))
                   "ab\\"))
    (should (eq (alist-get 'isError (alist-get 'result (car over))) t))
    (should (equal (anvil-server-inline-result-test--response-text (car over))
                   anvil-server--inline-result-too-large-text))
    (should (= (anvil-server-metrics-errors (cadr over)) 1))
    (should (= (nth 2 over) 0))
    (should (= (nth 4 over) 0))))

(ert-deftest anvil-server-inline-result-test-rejects-before-disclosure-and-telemetry ()
  "Initially oversized text is not disclosed or sent to success observers."
  (let ((outcome (anvil-server-inline-result-test--invoke 4 (make-string 5 ?x)
                                                        (make-string 40 ?z))))
    (should (eq (alist-get 'isError (alist-get 'result (car outcome))) t))
    (should (= (nth 5 outcome) 0))
    (should (= (nth 2 outcome) 0))
    (should (= (nth 4 outcome) 0))
    (should (= (nth 7 outcome) 0))
    (should (= (anvil-server-metrics-errors (cadr outcome)) 1))
    (should (equal (nth 3 outcome) '(("inline-result-test-tool" . t))))))

(ert-deftest anvil-server-inline-result-test-rejects-disclosure-expansion ()
  "Disclosure expansion is rechecked before successful payload accounting."
  (let ((outcome (anvil-server-inline-result-test--invoke 4 "ok" (make-string 5 ?x))))
    (should (eq (alist-get 'isError (alist-get 'result (car outcome))) t))
    (should (= (nth 5 outcome) 1))
    (should (= (anvil-server-metrics-errors (cadr outcome)) 1))
    (should (= (nth 2 outcome) 0))
    (should (= (nth 4 outcome) 0))))

(ert-deftest anvil-server-inline-result-test-disabled-limits-and-structured-result ()
  "Nil and nonpositive integer limits preserve ordinary dispatch behavior."
  (dolist (limit '(nil 0 -3))
    (let ((outcome (anvil-server-inline-result-test--invoke limit (make-string 32 ?x))))
      (should (eq (alist-get 'isError (alist-get 'result (car outcome))) :json-false))
      (should (= (nth 2 outcome) 1))
      (should (= (nth 4 outcome) 1))))
  (let ((outcome (anvil-server-inline-result-test--invoke 16 '(:ok t))))
    (should (eq (alist-get 'isError (alist-get 'result (car outcome))) :json-false)))
  (let ((outcome (anvil-server-inline-result-test--invoke 16 nil)))
    (should (equal (anvil-server-inline-result-test--response-text (car outcome)) ""))))

(ert-deftest anvil-server-inline-result-test-strips-properties-after-acceptance ()
  "Accepted result strings are stripped of text properties for transport."
  (let* ((text (propertize "fine" 'face 'bold))
         (outcome (anvil-server-inline-result-test--invoke 8 text)))
    (should (equal (nth 6 outcome) "fine"))
    (should-not (text-properties-at 0 (nth 6 outcome)))))

(ert-deftest anvil-server-inline-result-test-invalid-limit-fails-closed-before-handler ()
  "Unsupported limit values fail closed without calling the tool handler."
  (dolist (limit '("8" 8.0 t))
    (let ((handler-called nil)
          (anvil-server-inline-result-test--handler-result "ok"))
      (cl-letf (((symbol-function 'anvil-server-inline-result-test--result-handler)
                 (lambda () (setq handler-called t) "ok")))
        (let ((outcome (anvil-server-inline-result-test--invoke limit "ignored")))
          (should-not handler-called)
          (should (eq (alist-get 'isError (alist-get 'result (car outcome))) t))
          (should (equal (anvil-server-inline-result-test--response-text (car outcome))
                         anvil-server--inline-result-limit-error-text))
          (should (= (anvil-server-metrics-errors (cadr outcome)) 1)))))))

(ert-deftest anvil-server-inline-result-test-default-limit-is-two-mib ()
  "The default inline result limit is two mebibytes."
  (should (= anvil-server-max-inline-result-bytes (* 2 1024 1024))))

(ert-deftest anvil-server-inline-result-test-followup-small-call-succeeds ()
  "A rejection does not prevent a later small successful dispatch."
  (let ((large (anvil-server-inline-result-test--invoke 4 (make-string 8 ?x)))
        (small (anvil-server-inline-result-test--invoke 4 "ok")))
    (should (eq (alist-get 'isError (alist-get 'result (car large))) t))
    (should (eq (alist-get 'isError (alist-get 'result (car small))) :json-false))
    (should (equal (anvil-server-inline-result-test--response-text (car small)) "ok"))))

(provide 'anvil-server-inline-result-test)
;;; anvil-server-inline-result-test.el ends here
