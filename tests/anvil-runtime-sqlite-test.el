;;; anvil-runtime-sqlite-test.el --- SQLite compatibility regressions -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'anvil-sqlite)

(defconst anvil-runtime-sqlite-test--polyfill-file
  (expand-file-name "../scripts/anvil-runtime-polyfills.el"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun anvil-runtime-sqlite-test--eval-polyfill-sqlite-forms ()
  "Evaluate only the SQLite polyfill forms, without loading the bootstrap."
  (with-temp-buffer
    (insert-file-contents anvil-runtime-sqlite-test--polyfill-file)
    (goto-char (point-min))
    (search-forward "(defvar anvil-runtime-polyfills--sqlite-native-select")
    (beginning-of-line)
    (let ((start (point)) source)
      (search-forward ";; --- benchmark / profiler stubs")
      (beginning-of-line)
      (setq source (buffer-substring-no-properties start (point)))
      (with-temp-buffer
        (insert source)
        (goto-char (point-min))
        (condition-case nil
            (while t (eval (read (current-buffer))))
          (end-of-file nil))))))

(defun anvil-runtime-sqlite-test--with-polyfill-forms (backend fn)
  "Run FN with isolated SQLite bindings and evaluate source forms twice."
  (let ((db-opened 0) (db-closed 0))
    (let ((state '(anvil-runtime-polyfills--sqlite-native-select
                   anvil-runtime-polyfills--sqlite-native-more
                   anvil-runtime-polyfills--sqlite-native-next
                   anvil-runtime-polyfills--sqlite-native-finalize
                   anvil-runtime-polyfills--sqlite-needs-set-polyfill)))
     (cl-progv state nil
      (cl-letf (((symbol-function 'sqlite-select) (nth 0 backend))
                ((symbol-function 'sqlite-more-p) (nth 1 backend))
                ((symbol-function 'sqlite-next) (nth 2 backend))
                ((symbol-function 'sqlite-finalize) (nth 3 backend))
                ((symbol-function 'sqlite-open)
                 (lambda (&rest _) (setq db-opened (1+ db-opened)) 'probe-db))
                ((symbol-function 'sqlite-close)
                 (lambda (&rest _) (setq db-closed (1+ db-closed)) t)))
        (mapc #'makunbound state)
        (anvil-runtime-sqlite-test--eval-polyfill-sqlite-forms)
        (anvil-runtime-sqlite-test--eval-polyfill-sqlite-forms)
        (funcall fn)
        (should (= db-opened 2))
        (should (= db-closed 2)))))))

(ert-deftest anvil-runtime-sqlite-test/partial-native-backend-is-adapted-safely ()
  "Unsupported set uses tagged rows while all native shapes still delegate."
  (let* ((calls nil)
        (native-select
         (lambda (_db query &optional params type)
           (push (list query params type) calls)
           (cond ((eq type 'set) (error "set unsupported"))
                 ((equal query "SELECT 1 UNION ALL SELECT 2") '((1) (2)))
                 ((equal query "rows") '((native-row-1) (native-row-2)))
                 ((equal query "empty") nil)
                 ((equal query "boom") (error "query failed"))
                 ((eq type 'full) 'native-full)
                 ((null type) 'native-default)
                 (t 'native-other))))
        (native-more (lambda (cursor) (push (list 'more cursor) calls) 'native-more))
        (native-next (lambda (cursor) (push (list 'next cursor) calls) 'native-row))
        (native-finalize (lambda (cursor) (push (list 'finalize cursor) calls) 'native-done)))
    (anvil-runtime-sqlite-test--with-polyfill-forms
     (list native-select native-more native-next native-finalize)
     (lambda ()
       (should anvil-runtime-polyfills--sqlite-needs-set-polyfill)
       ;; The previous fboundp gate skipped this backend because it has
       ;; sqlite-more-p even though its select implementation rejects set.
       (should anvil-runtime-polyfills--sqlite-native-more)
       (should (eq (sqlite-select 'db "Q" '(param)) 'native-default))
       (should (eq (sqlite-select 'db "Q" nil 'full) 'native-full))
       (let ((cursor (sqlite-select 'db "rows" '(param) 'set)))
         (should (equal cursor '(:anvil-sqlite-cursor (native-row-1) (native-row-2))))
         (should (sqlite-more-p cursor))
         (should (equal (sqlite-next cursor) '(native-row-1)))
         (should (sqlite-more-p cursor))
         (should (equal (sqlite-next cursor) '(native-row-2)))
         (should-not (sqlite-more-p cursor))
         (sqlite-finalize cursor)
         (should-not (cdr cursor)))
       (should (eq (sqlite-more-p 'native-cursor) 'native-more))
       (should (eq (sqlite-next 'native-cursor) 'native-row))
       (should (eq (sqlite-finalize 'native-cursor) 'native-done))
       (should (member '("rows" (param) nil) calls))
       (should (member '("Q" nil full) calls))
       (should (null (cdr (sqlite-select 'db "empty" nil 'set))))
       (should-error (sqlite-select 'db "boom" nil 'set))))))

(ert-deftest anvil-runtime-sqlite-test/legacy-backend-gets-list-cursor-helpers ()
  "A legacy backend without cursor functions receives all three helpers."
  (let ((native-select
         (lambda (_db query &optional _params type)
           (if (equal query "SELECT 1 UNION ALL SELECT 2")
               '((1) (2))
             (if (eq type 'full) 'native-full '((7) (8)))))))
    (anvil-runtime-sqlite-test--with-polyfill-forms
     (list native-select nil nil nil)
     (lambda ()
       (should anvil-runtime-polyfills--sqlite-needs-set-polyfill)
       (let ((cursor (sqlite-select 'db "legacy" nil 'set)))
         (should (sqlite-more-p cursor))
         (should (equal (sqlite-next cursor) '(7)))
         (should (equal (sqlite-next cursor) '(8)))
         (should-not (sqlite-more-p cursor))
         (sqlite-finalize cursor)
         (should-not (cdr cursor)))
       (should (eq (sqlite-select 'db "legacy" nil 'full) 'native-full))))))

(ert-deftest anvil-runtime-sqlite-test/native-cursor-is-preserved-and-finalize-probed ()
  "A complete native cursor keeps function identity; finalize errors trigger fallback."
  (let* ((native-select
          (lambda (_db query &optional _params type)
            (cond ((and (eq type 'set)
                        (equal query "SELECT 1 UNION ALL SELECT 2"))
                   (list :native '(1) '(2)))
                  ((equal query "SELECT 1 UNION ALL SELECT 2") '((1) (2)))
                  ((eq type 'set) (list :native '(3)))
                  (t 'native-default))))
         (native-more (lambda (cursor) (cdr cursor)))
         (native-next (lambda (cursor)
                        (prog1 (cadr cursor) (setcdr cursor (cddr cursor)))))
         (native-finalize (lambda (_cursor) t)))
    (anvil-runtime-sqlite-test--with-polyfill-forms
     (list native-select native-more native-next native-finalize)
     (lambda ()
       (should-not anvil-runtime-polyfills--sqlite-needs-set-polyfill)
       (should (eq (symbol-function 'sqlite-select) native-select))
       (should (eq (sqlite-select 'db "Q") 'native-default))))
    (let ((bad-finalize (lambda (_cursor) (error "broken finalize"))))
      (anvil-runtime-sqlite-test--with-polyfill-forms
       (list native-select native-more native-next bad-finalize)
       (lambda ()
         (should anvil-runtime-polyfills--sqlite-needs-set-polyfill)
         (should (consp (sqlite-select 'db "Q" nil 'set))))))
    (let ((broken-default (lambda (&rest _) (error "database query failed"))))
      (anvil-runtime-sqlite-test--with-polyfill-forms
       (list broken-default native-more native-next native-finalize)
       (lambda ()
         (should-not anvil-runtime-polyfills--sqlite-needs-set-polyfill)
         (should (eq (symbol-function 'sqlite-select) broken-default)))))))

(ert-deftest anvil-runtime-sqlite-test/cap-keeps-first-rows-in-order ()
  "The response cap retains the first rows in SQLite query order."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (let* ((path (make-temp-file "anvil-sqlite-test"))
         (db (sqlite-open path))
         (anvil-sqlite-max-rows 2))
    (unwind-protect
        (progn
          (sqlite-execute db "CREATE TABLE sample (n INTEGER)")
          (sqlite-execute db "INSERT INTO sample VALUES (42), (43), (44)")
          (should
           (equal (anvil-sqlite--tool-query
                   path "SELECT n FROM sample ORDER BY n")
                  "(:row-count 2 :truncated t :rows ((42) (43)))")))
      (sqlite-close db)
      (delete-file path))))

(provide 'anvil-runtime-sqlite-test)
;;; anvil-runtime-sqlite-test.el ends here
