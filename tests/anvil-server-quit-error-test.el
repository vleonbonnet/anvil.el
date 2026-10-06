;;; anvil-server-quit-error-test.el --- Quit bounds and lazy fallback -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'anvil-server)

(defun anvil-quit-test--exercise (kind data &optional uri)
  "Return decoded KIND quit response and metrics for DATA."
  (let* ((anvil-server--tools (make-hash-table :test #'equal))
         (anvil-server-tool-error-hook nil)
         (table (make-hash-table :test #'equal))
         (metrics (make-anvil-server-metrics))
         (handler (lambda () (signal 'quit data)))
         (wire
          (if (eq kind 'resource)
              (anvil-server--execute-resource-handler
               (list :handler handler) (or uri "quit://small") nil "quit-7" metrics)
            (puthash "quit" (list :handler handler :arglist nil) table)
            (puthash "emacs-eval" table anvil-server--tools)
            (anvil-server--handle-tools-call
             "quit-7" '((name . "quit")) metrics "emacs-eval"))))
    (list :response (json-read-from-string wire) :metrics metrics)))

(defun anvil-quit-test--message (result)
  (alist-get 'message (alist-get 'error (plist-get result :response))))

(defun anvil-quit-test--contains-object-p (target object &optional seen)
  "Return non-nil when TARGET is reachable by identity from OBJECT."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((eq target object) t)
     ((and (or (consp object) (vectorp object))
           (not (gethash object seen)))
      (puthash object t seen)
      (if (consp object)
          (or (anvil-quit-test--contains-object-p target (car object) seen)
              (anvil-quit-test--contains-object-p target (cdr object) seen))
        (cl-some (lambda (item)
                   (anvil-quit-test--contains-object-p target item seen))
                 (append object nil)))))))

(defun anvil-quit-test--lazy (kind data)
  "Return the lazy-loader KIND fallback, its call count and follow-up reply."
  (let* ((anvil-server--running t)
         (anvil-server--tools (make-hash-table :test #'equal))
         (table (make-hash-table :test #'equal))
         (calls 0) (handler-calls 0))
    (puthash "lazy" (list :handler (lambda () (setq handler-calls (1+ handler-calls)))
                         :arglist nil :lazy-placeholder t
                         :lazy-loader (lambda (&rest _args)
                                        (setq calls (1+ calls))
                                        (signal kind data))) table)
    (puthash "small" (list :handler (lambda () "hello-é") :arglist nil) table)
    (puthash "emacs-eval" table anvil-server--tools)
    (let* ((wire (anvil-server-process-jsonrpc
                  (anvil-server-create-tools-call-request "lazy" "lazy-8" nil)
                  "emacs-eval"))
           (follow-up (anvil-server-process-jsonrpc
                       (anvil-server-create-tools-call-request "small" "next-9" nil)
                       "emacs-eval")))
      (list :response (json-read-from-string wire) :calls calls
            :handler-calls handler-calls
            :follow-up (let ((json-false nil)) (json-read-from-string follow-up))))))

(ert-deftest anvil-quit-error-original-payload-never-reaches-raw-printer ()
  (dolist (kind '(tool resource))
    (let* ((data (list (make-string 200000 ?界)))
           (original (symbol-function 'format))
           (observed nil))
      (cl-letf (((symbol-function 'format)
                 (lambda (control &rest args)
                   (cond
                    ((equal control "Tool handler quit: %S")
                     (push (car args) observed))
                    ((equal control "Resource handler quit for %s: %S")
                     (push (cadr args) observed))
                    ((and (equal control "%S") (consp (car args))
                          (eq (caar args) 'quit))
                     (push (car args) observed)))
                   (apply original control args))))
        (anvil-quit-test--exercise kind data))
      (should observed)
      (should (cl-every (lambda (raw-arg)
                          (and (not (anvil-quit-test--contains-object-p
                                     data raw-arg))
                               (not (anvil-quit-test--contains-object-p
                                     (car data) raw-arg))))
                        observed))
      (should (cl-every (lambda (raw-arg)
                          (<= (length (cadr raw-arg)) 4096))
                        observed)))))

(ert-deftest anvil-quit-error-resources-read-keeps-original-routing-data ()
  (let* ((anvil-server--running t)
         (server-id "quit-error-routing-test")
         (anvil-server--resources (make-hash-table :test #'equal))
         (anvil-server--resource-templates (make-hash-table :test #'equal))
         (direct-uri (concat "quit://direct/" (make-string 200000 ?d)))
         (template-value (make-string 200000 ?v))
         (template-uri (concat "quit://template/" template-value))
         (direct-calls 0)
         (template-params nil)
         (direct-wire nil)
         (template-wire nil))
    (anvil-server-register-resource
     direct-uri
     (lambda ()
       (setq direct-calls (1+ direct-calls))
       (signal 'quit (list direct-uri)))
     :name "large direct URI" :server-id server-id)
    (anvil-server-register-resource
     "quit://template/{value}"
     (lambda (params)
       (setq template-params params)
       (signal 'quit params))
     :name "large template value" :server-id server-id)
    (setq direct-wire
          (anvil-server-process-jsonrpc
           (anvil-server-create-resources-read-request direct-uri "direct-1")
           server-id)
          template-wire
          (anvil-server-process-jsonrpc
           (anvil-server-create-resources-read-request template-uri "template-2")
           server-id))
    (let ((direct-response (json-read-from-string direct-wire))
          (template-response (json-read-from-string template-wire)))
      (should (= direct-calls 1))
      (should (equal (alist-get "value" template-params nil nil #'equal)
                     template-value))
      (should (equal (alist-get 'id direct-response) "direct-1"))
      (should (equal (alist-get 'id template-response) "template-2"))
      (should (= (alist-get 'code (alist-get 'error direct-response)) -32603))
      (should (= (alist-get 'code (alist-get 'error template-response)) -32603))
      (should (string-prefix-p "Resource handler quit for "
                               (alist-get 'message (alist-get 'error direct-response))))
      (should (string-prefix-p "Resource handler quit for "
                               (alist-get 'message (alist-get 'error template-response))))
      (should (< (length (alist-get 'message (alist-get 'error direct-response))) 4500))
      (should (< (length (alist-get 'message (alist-get 'error template-response)))
                 4500)))))

(ert-deftest anvil-quit-error-nil-final-cap-keeps-whole-message-bounded ()
  (let ((anvil-server-tool-error-max-chars nil))
    (dolist (kind '(tool resource))
      (should (< (length (anvil-quit-test--message
                         (anvil-quit-test--exercise kind (list (make-string 200000 ?界)))))
                 4500)))))

(ert-deftest anvil-quit-error-small-text-ids-codes-and-metrics-remain-compatible ()
  (dolist (kind '(tool resource))
    (dolist (data '(nil (minibuffer-quit) ("small")))
      (let* ((result (anvil-quit-test--exercise kind data))
             (response (plist-get result :response))
             (prefix (if (eq kind 'tool) "Tool handler quit: "
                       "Resource handler quit for quit://small: ")))
        (should (equal (alist-get 'id response) "quit-7"))
        (should (= (alist-get 'code (alist-get 'error response)) -32603))
        (should (equal (anvil-quit-test--message result)
                       (concat prefix (format "%S" (cons 'quit data)))))
        (should (= (anvil-server-metrics-errors (plist-get result :metrics)) 1))))))

(ert-deftest anvil-quit-error-resource-uri-diagnostic-is-bounded ()
  (let* ((uri (concat "quit://" (make-string 200000 ?界)))
         (length-before (length uri))
         (result (anvil-quit-test--exercise 'resource nil uri)))
    (should (< (length (anvil-quit-test--message result)) 300))
    (should (= (length uri) length-before))
    (should (string-suffix-p ": (quit)" (anvil-quit-test--message result)))))

(ert-deftest anvil-quit-error-work-budgets-pinned-at-raw-printer ()
  (dolist (kind '(tool resource))
    (let ((anvil-bounded-data--snapshot-node-limit 200000)
          (anvil-bounded-data--snapshot-depth-limit 200000)
          (anvil-bounded-data--snapshot-char-limit 200000)
          (original (symbol-function 'format))
          (observed nil))
      (cl-letf (((symbol-function 'format)
                 (lambda (control &rest args)
                   (when (and (equal control "%S") (consp (car args))
                              (eq (caar args) 'quit))
                     (setq observed
                           (list anvil-bounded-data--snapshot-node-limit
                                 anvil-bounded-data--snapshot-depth-limit
                                 anvil-bounded-data--snapshot-char-limit)))
                   (apply original control args))))
        (anvil-quit-test--exercise kind '("small")))
      (should (equal observed '(512 8 4096))))))

(ert-deftest anvil-quit-error-cycles-and-opaque-data-are-elided ()
  (let ((cycle (list 'self)))
    (setcdr cycle cycle)
    (dolist (kind '(tool resource))
      (let ((message-text (anvil-quit-test--message
                           (anvil-quit-test--exercise
                            kind (list (vector cycle (make-hash-table)))))))
        (should (string-match-p "<cycle>" message-text))
        (should (string-match-p "<opaque>" message-text))
        (should (< (length message-text) 300))))))

(ert-deftest anvil-quit-error-lazy-fallback-already-bounded-and-follow-up-responsive ()
  (dolist (kind '(error quit))
    (let* ((result (anvil-quit-test--lazy kind (list (make-string 200000 ?界))))
           (follow-up (plist-get result :follow-up))
           (content (alist-get 'content (alist-get 'result follow-up))))
      (should (equal (alist-get 'id (plist-get result :response)) "lazy-8"))
      (should (= (plist-get result :calls) 1))
      (should (= (plist-get result :handler-calls) 0))
      (should (< (length (anvil-quit-test--message result)) 4500))
      (should (= (alist-get 'code (alist-get 'error (plist-get result :response))) -32603))
      (should (equal (alist-get 'id follow-up) "next-9"))
      (should-not (alist-get 'error follow-up))
      (should (equal (alist-get 'text (aref content 0)) "hello-é")))))

(ert-deftest anvil-quit-error-small-lazy-fallback-retains-native-message ()
  (dolist (kind '(error quit))
    (let* ((result (anvil-quit-test--lazy kind '("small")))
           (expected (concat "Internal error: "
                             (error-message-string (list kind "small")))))
      (should (equal (anvil-quit-test--message result) expected)))))

(provide 'anvil-server-quit-error-test)
;;; anvil-server-quit-error-test.el ends here
