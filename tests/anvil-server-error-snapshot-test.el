;;; anvil-server-error-snapshot-test.el --- Pre-print error data bounds -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-server)

(ert-deftest anvil-error-snapshot-printer-never-receives-original-graph ()
  (let* ((err (list 'error (make-string 1000000 ?x)))
         (original-format (symbol-function 'format))
         (observed nil))
    (cl-letf (((symbol-function 'format)
               (lambda (control &rest args)
                 (when (equal control "Error: %S")
                   (setq observed (car args)))
                 (apply original-format control args))))
      (anvil-server-format-tool-error err))
    (should observed)
    (should-not (eq observed err))
    (should (<= (length (cadr observed)) 4096))))

(ert-deftest anvil-error-snapshot-nil-final-cap-keeps-leaves-bounded ()
  (let ((anvil-server-tool-error-max-chars nil))
    (should (< (length (anvil-server-format-tool-error
                       (list 'error (make-string 200000 ?界))))
               4500))))

(ert-deftest anvil-error-snapshot-small-errors-keep-raw-text ()
  (dolist (err '((error "small") (void-function missing)
                (wrong-type-argument listp 3) (file-error "missing" "/a")))
    (should (equal (anvil-server-format-tool-error err)
                   (format "Error: %S" err)))))

(ert-deftest anvil-error-snapshot-cycles-and-opaque-values-use-markers ()
  (let ((cycle (list 'self)))
    (setcdr cycle cycle)
    (let ((text (anvil-server-format-tool-error
                 (list 'error (vector cycle (make-hash-table)
                                      (record 'probe 1) (expt 2 10000))))))
      (should (string-match-p "<cycle>" text))
      (should (string-match-p "<opaque>" text))
      (should (< (length text) 300)))))

(ert-deftest anvil-error-snapshot-original-vector-inspections-are-bounded ()
  (let ((input (make-vector 100000 'x))
        (original-aref (symbol-function 'aref))
        (reads 0))
    (cl-letf (((symbol-function 'aref)
               (lambda (object index)
                 (when (eq object input) (setq reads (1+ reads)))
                 (funcall original-aref object index))))
      (anvil-server-format-tool-error (list 'error input)))
    (should (> reads 0))
    (should (<= reads 512))))

(ert-deftest anvil-error-snapshot-server-pins-work-budgets ()
  (let ((anvil-server-tool-error-max-chars nil)
        (anvil-bounded-data--snapshot-node-limit 200000)
        (anvil-bounded-data--snapshot-depth-limit 200000)
        (anvil-bounded-data--snapshot-char-limit 200000))
    (should (< (length (anvil-server-format-tool-error
                       (list 'error (make-string 200000 ?x))))
               4500))))

(provide 'anvil-server-error-snapshot-test)
;;; anvil-server-error-snapshot-test.el ends here
