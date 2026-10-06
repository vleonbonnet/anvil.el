;;; anvil-server-condition-error-test.el --- Bounded native condition rendering -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'anvil-server)

(defun anvil-condition-test--response (err)
  "Return the decoded fallback response for ERR."
  (let ((anvil-server--current-request-id "condition-7"))
    (json-read-from-string (anvil-server--handle-error err))))

(defun anvil-condition-test--message (response)
  (alist-get 'message (alist-get 'error response)))

(ert-deftest anvil-condition-payload-is-bounded-before-native-formatting ()
  (let* ((original (symbol-function 'error-message-string))
         (err (list 'error (make-string 200000 ?界)))
         (observed nil))
    (cl-letf (((symbol-function 'error-message-string)
               (lambda (value)
                 (setq observed value)
                 (funcall original value))))
      (anvil-condition-test--response err))
    (should observed)
    (should-not (eq observed err))
    (should (<= (length (cadr observed)) 4096))))

(ert-deftest anvil-condition-metadata-is-bounded-before-native-formatting ()
  (let* ((symbol (make-symbol "condition-large"))
         (original (symbol-function 'error-message-string))
         (metadata (make-string 200000 ?x))
         (observed nil))
    (put symbol 'error-message metadata)
    (put symbol 'error-conditions '(error))
    (cl-letf (((symbol-function 'error-message-string)
               (lambda (value)
                 (setq observed (car value))
                 (funcall original value))))
      (anvil-condition-test--response (list symbol "detail")))
    (should observed)
    (should-not (eq observed symbol))
    (should (<= (length (get observed 'error-message)) 4096))
    (should (eq (get symbol 'error-message) metadata))))

(ert-deftest anvil-condition-small-errors-retain-native-message-and-id ()
  (dolist (err '((error "small") (void-function missing)
                (wrong-type-argument listp 3) (wrong-number-of-arguments f 2)
                (file-error "missing" "/a")))
    (let ((response (anvil-condition-test--response err)))
      (should (equal (alist-get 'id response) "condition-7"))
      (should (= (alist-get 'code (alist-get 'error response)) -32603))
      (should (equal (anvil-condition-test--message response)
                     (concat "Internal error: " (error-message-string err)))))))

(ert-deftest anvil-condition-custom-error-keeps-message ()
  (let ((symbol (make-symbol "condition-custom")))
    (put symbol 'error-message "Custom failure")
    (put symbol 'error-conditions '(error))
    (should (equal (anvil-condition-test--message
                    (anvil-condition-test--response (list symbol "detail")))
                   (concat "Internal error: "
                           (error-message-string (list symbol "detail")))))))

(ert-deftest anvil-condition-server-pins-work-limits ()
  (let ((anvil-bounded-data--snapshot-node-limit 200000)
        (anvil-bounded-data--snapshot-depth-limit 200000)
        (anvil-bounded-data--snapshot-char-limit 200000)
        (original (symbol-function 'error-message-string))
        (observed nil)
        (message-text nil))
    (cl-letf (((symbol-function 'error-message-string)
               (lambda (value)
                 (setq observed
                       (list anvil-bounded-data--snapshot-node-limit
                             anvil-bounded-data--snapshot-depth-limit
                             anvil-bounded-data--snapshot-char-limit))
                 (funcall original value))))
      (setq message-text (anvil-condition-test--message
                          (anvil-condition-test--response
                           (list 'error (make-string 200000 ?x))))))
    (should (< (length message-text) 4500))
    (should (equal observed '(512 8 4096)))))

(ert-deftest anvil-condition-generic-tool-error-retains-hook-and-bounds ()
  (let* ((symbol (make-symbol "condition-tool"))
         (payload (make-string 200000 ?x))
         (hook-value nil)
         (anvil-server--tools (make-hash-table :test #'equal))
         (table (make-hash-table :test #'equal))
         (anvil-server-tool-error-max-chars nil)
         (anvil-server-tool-error-hook
          (list (lambda (err tool source)
                  (setq hook-value (list err tool source))))))
    (put symbol 'error-message "Tool failure")
    (put symbol 'error-conditions '(error))
    (puthash "condition" (list :handler (lambda () (signal symbol (list payload)))
                              :arglist nil) table)
    (puthash "emacs-eval" table anvil-server--tools)
    (let* ((response (json-read-from-string
                      (anvil-server--handle-tools-call
                       9 '((name . "condition"))
                       (make-anvil-server-metrics) "emacs-eval")))
           (message-text (anvil-condition-test--message response)))
      (should (equal (alist-get 'id response) 9))
      (should (= (alist-get 'code (alist-get 'error response)) -32603))
      (should (string-prefix-p "Internal error executing tool: " message-text))
      (should (< (length message-text) 4500))
      (should (eq (caar hook-value) symbol))
      (should (eq (cadar hook-value) payload))
      (should (equal (cdr hook-value) '("condition" tool-body))))))

(ert-deftest anvil-condition-generic-tool-small-errors-retain-native-message ()
  (dolist (err '((error "small") (void-function missing)
                (wrong-type-argument listp 3) (file-error "missing" "/a")))
    (let ((anvil-server--tools (make-hash-table :test #'equal))
          (table (make-hash-table :test #'equal))
          (anvil-server-tool-error-hook nil))
      (puthash "condition" (list :handler (lambda () (signal (car err) (cdr err)))
                                :arglist nil) table)
      (puthash "emacs-eval" table anvil-server--tools)
      (let ((response (json-read-from-string
                       (anvil-server--handle-tools-call
                        "small-8" '((name . "condition"))
                        (make-anvil-server-metrics) "emacs-eval"))))
        (should (equal (anvil-condition-test--message response)
                       (concat "Internal error executing tool: "
                               (error-message-string err))))))))

(ert-deftest anvil-condition-cyclic-metadata-never-reaches-native-formatter ()
  (let* ((symbol (make-symbol "condition-cycle"))
         (properties (list 'error-message "Safe message"))
         (original (symbol-function 'error-message-string))
         (observed nil))
    (setcdr (cdr properties) properties)
    (setplist symbol properties)
    ;; Intercept without traversing the original cyclic plist on the baseline.
    (cl-letf (((symbol-function 'error-message-string)
               (lambda (value)
                 (setq observed (car value))
                 (if (eq (car value) symbol) "unsafe original metadata"
                   (funcall original value)))))
      (anvil-condition-test--response (list symbol)))
    (should-not (eq observed symbol))
    (should (equal (get observed 'error-message) "Safe message"))))

(provide 'anvil-server-condition-error-test)
;;; anvil-server-condition-error-test.el ends here
