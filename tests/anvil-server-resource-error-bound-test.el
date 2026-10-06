;;; anvil-server-resource-error-bound-test.el --- Resource error bounds -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'anvil-server)

(define-error 'anvil-resource-bound-cycle-error "Cycle fixture: %S")
(define-error 'anvil-resource-bound-metadata-error "Initial metadata")

(defun anvil-resource-bound-test--contains-object-p (target object &optional seen)
  "Return non-nil when TARGET is reachable by identity from OBJECT."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (cond
     ((eq target object) t)
     ((and (consp object) (not (gethash object seen)))
      (puthash object t seen)
      (or (anvil-resource-bound-test--contains-object-p target (car object) seen)
          (anvil-resource-bound-test--contains-object-p target (cdr object) seen)))
     ((and (vectorp object) (not (stringp object)) (not (gethash object seen)))
      (puthash object t seen)
      (cl-some (lambda (item)
                 (anvil-resource-bound-test--contains-object-p target item seen))
               (append object nil))))))

(defun anvil-resource-bound-test--read (wire)
  "Decode WIRE as a JSON-RPC response."
  (json-read-from-string wire))

(defun anvil-resource-bound-test--message (wire)
  "Return the error message from WIRE."
  (alist-get 'message (alist-get 'error
                                 (anvil-resource-bound-test--read wire))))

(ert-deftest anvil-resource-generic-error-avoids-unbounded-native-printer ()
  (let* ((payload (make-string 200000 ?界))
         (native (symbol-function 'error-message-string))
         (observed nil)
         (metrics (make-anvil-server-metrics))
         (wire (cl-letf (((symbol-function 'error-message-string)
                          (lambda (data)
                            (push data observed)
                            (funcall native data))))
                 (anvil-server--execute-resource-handler
                 (list :handler (lambda () (signal 'error (list payload))))
                  "test://large" nil "large-1" metrics)))
         (response (anvil-resource-bound-test--read wire)))
    ;; Make observations only after the production catch has returned.
    (should observed)
    (should-not (cl-some
                 (lambda (input)
                   (anvil-resource-bound-test--contains-object-p payload input))
                 observed))
    (should (<= (length (alist-get 'message (alist-get 'error response))) 4500))
    (should (= (alist-get 'code (alist-get 'error response)) -32603))
    (should (= (anvil-server-metrics-errors metrics) 1))))

(ert-deftest anvil-resource-generic-error-cycle-opaque-and-hostile-budgets ()
  (let ((cycle (list 'self))
        (anvil-bounded-data--snapshot-node-limit 200000)
        (anvil-bounded-data--snapshot-depth-limit 200000)
        (anvil-bounded-data--snapshot-char-limit 200000))
    (setcdr cycle cycle)
    (let* ((wire (anvil-server--execute-resource-handler
                  (list :handler (lambda ()
                                   (signal 'anvil-resource-bound-cycle-error
                                           (list (vector cycle
                                                         (make-hash-table))))))
                  "test://cycle" nil "cycle-1" (make-anvil-server-metrics)))
           (message (anvil-resource-bound-test--message wire)))
      (should (string-match-p "<cycle>" message))
      (should (string-match-p "<opaque>" message))
      (should (< (length message) 4500)))))

(ert-deftest anvil-resource-generic-error-pins-snapshot-work-limits ()
  (let ((anvil-bounded-data--snapshot-node-limit 200000)
        (anvil-bounded-data--snapshot-depth-limit 200000)
        (anvil-bounded-data--snapshot-char-limit 200000)
        (snapshot-original (symbol-function 'anvil-bounded-data--bounded-snapshot))
        (render-original (symbol-function 'anvil-bounded-data--render-snapshot))
        (snapshots nil) (renders nil))
    (cl-letf (((symbol-function 'anvil-bounded-data--bounded-snapshot)
               (lambda (data)
                 (push (list anvil-bounded-data--snapshot-node-limit
                             anvil-bounded-data--snapshot-depth-limit
                             anvil-bounded-data--snapshot-char-limit)
                       snapshots)
                 (funcall snapshot-original data)))
              ((symbol-function 'anvil-bounded-data--render-snapshot)
               (lambda (snapshot &optional message-max raw-max)
                 (push (list anvil-bounded-data--snapshot-node-limit
                             anvil-bounded-data--snapshot-depth-limit
                             anvil-bounded-data--snapshot-char-limit)
                       renders)
                 (funcall render-original snapshot message-max raw-max))))
      (anvil-server--execute-resource-handler
       (list :handler (lambda () (error "small")))
       "test://small" nil "small-1" (make-anvil-server-metrics)))
    (should (equal snapshots '((512 8 4096) (512 8 4096))))
    (should (equal renders '((512 8 4096) (512 8 4096))))))

(ert-deftest anvil-resource-generic-error-bounds-large-custom-error-metadata ()
  (let* ((symbol 'anvil-resource-bound-metadata-error)
         (old-message (get symbol 'error-message))
         (metadata (make-string 200000 ?m))
         (wire nil))
    (unwind-protect
        (progn
          (put symbol 'error-message metadata)
          (setq wire
                (anvil-server--execute-resource-handler
                 (list :handler (lambda () (signal symbol (list metadata))))
                 "test://metadata" nil "metadata-1"
                 (make-anvil-server-metrics))))
      (put symbol 'error-message old-message))
    (should (< (length (anvil-resource-bound-test--message wire)) 4500))))

(ert-deftest anvil-resource-generic-error-keeps-direct-and-template-routing-data ()
  (let* ((anvil-server--running t)
         (server-id "resource-error-routing-test")
         (anvil-server--resources (make-hash-table :test #'equal))
         (anvil-server--resource-templates (make-hash-table :test #'equal))
         (direct-uri (concat "test://direct/" (make-string 200000 ?d)))
         (template-value (make-string 200000 ?v))
         (template-uri (concat "test://template/" template-value))
         (direct-calls 0)
         (template-params nil))
    (anvil-server-register-resource
     direct-uri (lambda () (setq direct-calls (1+ direct-calls))
                  (error "direct-failure"))
     :name "large direct URI" :server-id server-id)
    (anvil-server-register-resource
     "test://template/{value}"
     (lambda (params) (setq template-params params) (error "template-failure"))
     :name "large template value" :server-id server-id)
    (let* ((direct (anvil-resource-bound-test--read
                    (anvil-server-process-jsonrpc
                     (anvil-server-create-resources-read-request direct-uri "direct-1")
                     server-id)))
           (template (anvil-resource-bound-test--read
                      (anvil-server-process-jsonrpc
                       (anvil-server-create-resources-read-request template-uri "template-2")
                       server-id)))
           (direct-message (alist-get 'message (alist-get 'error direct)))
           (template-message (alist-get 'message (alist-get 'error template))))
      (should (= direct-calls 1))
      (should (equal (alist-get "value" template-params nil nil #'equal)
                     template-value))
      (should (equal (alist-get 'id direct) "direct-1"))
      (should (equal (alist-get 'id template) "template-2"))
      (should (= (alist-get 'code (alist-get 'error direct)) -32603))
      (should (= (alist-get 'code (alist-get 'error template)) -32603))
      (should (string-prefix-p "Error reading resource " direct-message))
      (should (string-prefix-p "Error reading resource " template-message))
      (should (< (length direct-message) 4500))
      (should (< (length template-message) 4500)))))

(ert-deftest anvil-resource-generic-error-bounds-real-json-serialization-failure ()
  (let* ((buffer (get-buffer-create (make-string 200000 ?界)))
         (metrics (make-anvil-server-metrics))
         (native (symbol-function 'json-encode))
         (handler-calls 0) (result-encodes 0) (error-encodes 0)
         (wire nil))
    (unwind-protect
        (cl-letf (((symbol-function 'json-encode)
                   (lambda (object)
                     (when (assq 'result object) (setq result-encodes (1+ result-encodes)))
                     (when (assq 'error object) (setq error-encodes (1+ error-encodes)))
                     (funcall native object))))
          (setq wire
                (anvil-server--execute-resource-handler
                 (list :handler (lambda () (setq handler-calls (1+ handler-calls)) buffer))
                 "test://buffer" nil "buffer-1" metrics)))
      (kill-buffer buffer))
    (let ((response (anvil-resource-bound-test--read wire)))
      (should (= handler-calls 1))
      (should (= result-encodes 1))
      (should (= error-encodes 1))
      (should (= (anvil-server-metrics-errors metrics) 1))
      (should (equal (alist-get 'id response) "buffer-1"))
      (should (= (alist-get 'code (alist-get 'error response)) -32603))
      (should (string-prefix-p "Error reading resource test://buffer: "
                               (alist-get 'message (alist-get 'error response))))
      (should (< (length (alist-get 'message (alist-get 'error response))) 4500)))))

(ert-deftest anvil-resource-generic-error-nil-final-cap-stays-bounded ()
  (let ((anvil-server-tool-error-max-chars nil))
    (let* ((wire (anvil-server--execute-resource-handler
                  (list :handler (lambda ()
                                   (error "%s" (make-string 200000 ?界))))
                  "test://large" nil "nil-cap-1" (make-anvil-server-metrics)))
           (message (anvil-resource-bound-test--message wire)))
      (should (< (length message) 4500)))))

(ert-deftest anvil-resource-generic-error-preserves-native-message-code-id-and-metric ()
  (let* ((metrics (make-anvil-server-metrics))
         (wire (anvil-server--execute-resource-handler
                (list :handler (lambda () (error "ordinary failure")))
                "test://ordinary" nil "ordinary-9" metrics))
         (response (anvil-resource-bound-test--read wire))
         (message (alist-get 'message (alist-get 'error response))))
    (should (equal (alist-get 'id response) "ordinary-9"))
    (should (= (alist-get 'code (alist-get 'error response)) -32603))
    (should (equal message
                   (format "Error reading resource test://ordinary: %s"
                           (error-message-string '(error "ordinary failure")))))
    (should (= (anvil-server-metrics-errors metrics) 1))))

(ert-deftest anvil-resource-generic-error-success-path-keeps-unicode-content ()
  (let* ((wire (anvil-server--execute-resource-handler
                (list :handler (lambda () "hello-é界"))
                "test://success" nil "success-1" (make-anvil-server-metrics)))
         (response (anvil-resource-bound-test--read wire))
         (contents (alist-get 'contents (alist-get 'result response))))
    (should (equal (alist-get 'id response) "success-1"))
    (should-not (alist-get 'error response))
    (should (equal (alist-get 'text (aref contents 0)) "hello-é界"))))

(provide 'anvil-server-resource-error-bound-test)
;;; anvil-server-resource-error-bound-test.el ends here
