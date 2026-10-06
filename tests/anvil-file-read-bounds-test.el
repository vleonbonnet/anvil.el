;;; anvil-file-read-bounds-test.el --- Bounded read tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-file)

;; Keep the legacy implementation's path callable for the causal control.
(defvar anvil-file-max-inline-read-bytes)

(defun anvil-file-read-bounds-test--with-bytes (bytes fn)
  "Write raw BYTES to a temporary file and call FN with its path."
  (let ((path (make-temp-file "anvil-file-bounds-")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil path nil 'silent))
          (funcall fn path))
      (when (file-exists-p path) (delete-file path)))))

(defun anvil-file-read-bounds-test--error-text (fn)
  "Return the printed error signaled by FN."
  (condition-case err
      (progn (funcall fn) (ert-fail "expected an error"))
    (error (format "%S" err))))

(ert-deftest anvil-file-read-bounds-validation-precedes-path-access ()
  (let ((touched nil))
    (cl-letf (((symbol-function 'anvil--prepare-path)
               (lambda (&rest _) (setq touched t) (error "path reached"))))
      (should-error (anvil-file-read "/unused" 0.5 1))
      (should-error (anvil-file-read "/unused" 0 0))
      (should-not touched)))
  (let ((calls nil))
    (cl-letf (((symbol-function 'anvil-file-read)
               (lambda (&rest args) (push args calls) '(:ok t))))
      (dolist (value '("1.0" "0" "-1" "+1" "1x" "１"))
        (should-error (anvil-file--tool-read "/unused" "0" value)))
      (dolist (value '("0.5" "-1" "+0" "0x" "０"))
        (should-error (anvil-file--tool-read "/unused" value "1")))
      (should-not calls))))

(ert-deftest anvil-file-read-bounds-default-cap-is-causal ()
  (anvil-file-read-bounds-test--with-bytes
   "0123456789"
   (lambda (path)
     (let ((anvil-file-max-inline-read-bytes 8)
           (full-loader-called nil))
       (cl-letf (((symbol-function 'anvil--insert-file)
                  (lambda (&rest _) (setq full-loader-called t)
                    (ert-fail "unbounded full-body loader was called"))))
         (let ((message (anvil-file-read-bounds-test--error-text
                         (lambda () (anvil-file-read path)))))
           (should-not full-loader-called)
           (should (string-match-p "maximum 8 bytes" message))
           (should-not (string-match-p "0123456789" message))))))))

(ert-deftest anvil-file-read-bounds-default-cap-metadata ()
  (should (= 1048576 anvil-file-max-inline-read-bytes)))

(ert-deftest anvil-file-read-bounds-pages-match-eol-normalization ()
  (dolist (case '(("a\nb\n" "a\n" "b\n" 2)
                  ("a\r\nb\r\n" "a\n" "b\n" 2)
                  ("a\rb\r" "a\n" "b\n" 2)
                  ("\303\251\r\nlast" "é\n" "last" 2)))
    (let ((raw (nth 0 case)) (first (nth 1 case)) (second (nth 2 case))
          (total (nth 3 case)))
      (anvil-file-read-bounds-test--with-bytes
       raw
       (lambda (path)
         (let* ((anvil-file-max-inline-read-bytes 16)
                (one (anvil-file-read path 0 1))
                (two (anvil-file-read path 1 1)))
           (should (equal first (plist-get one :content)))
           (should (equal second (plist-get two :content)))
           (should (= total (plist-get one :total-lines)))))))))

(ert-deftest anvil-file-read-bounds-page-byte-limit-and-eof ()
  (anvil-file-read-bounds-test--with-bytes
   "1234567\nend\n"
   (lambda (path)
     (let ((anvil-file-max-inline-read-bytes 8))
       (should (equal "1234567\n" (plist-get (anvil-file-read path 0 1) :content)))
       (should-error (anvil-file-read path 0 2))
       (let ((past (anvil-file-read path 8 1)))
         (should (equal "" (plist-get past :content)))
         (should (= 2 (plist-get past :total-lines))))))))

(ert-deftest anvil-file-read-bounds-streams-fixed-chunks ()
  (let ((body (concat (make-string 70000 ?a) "\nlast")))
    (anvil-file-read-bounds-test--with-bytes
     body
     (lambda (path)
       (let ((anvil-file-max-inline-read-bytes 80000)
             (orig (symbol-function 'insert-file-contents-literally))
             (largest 0) (requests nil))
         (cl-letf (((symbol-function 'anvil--insert-file)
                    (lambda (&rest _) (ert-fail "full loader called")))
                   ((symbol-function 'insert-file-contents-literally)
                    (lambda (filename &optional visit beg end replace)
                      (push (cons beg end) requests)
                      (prog1 (funcall orig filename visit beg end replace)
                        (setq largest (max largest (buffer-size)))))))
           (let ((page (anvil-file-read path 1 1)))
             (should (equal "last" (plist-get page :content)))
             (should (= 2 (plist-get page :total-lines))))
           (should requests)
           (should (<= largest anvil-file--stream-chunk-bytes))
           (should (cl-every (lambda (range)
                               (<= (- (cdr range) (car range))
                                   anvil-file--stream-chunk-bytes))
                             requests))))))))

(ert-deftest anvil-file-read-bounds-invalid-config-fails-closed ()
  (anvil-file-read-bounds-test--with-bytes
   "ok\n"
   (lambda (path)
     (dolist (value '(1.5 -0.5 "8"))
       (let ((anvil-file-max-inline-read-bytes value))
         (should-error (anvil-file-read path 0 1))))))
  (dolist (cap '(nil 0 -1))
    (anvil-file-read-bounds-test--with-bytes
     "legacy\n"
     (lambda (path)
       (let ((anvil-file-max-inline-read-bytes cap))
         (should (equal "legacy\n" (plist-get (anvil-file-read path) :content))))))))

(ert-deftest anvil-file-read-bounds-eol-classifier-cases ()
  (dolist (case '(("" lf)
                  ("a\nb\n" lf)
                  ("a\rb\r" cr)
                  ("a\r\nb\r\n" crlf)
                  ("a\rb\nc" lf)
                  ("a\r\nb\r" crlf)
                  ("a\r\rb\r\n" crlf)
                  ("xxx\r\ny" crlf)))
    (anvil-file-read-bounds-test--with-bytes
     (car case)
     (lambda (path)
       (let ((anvil-file--stream-chunk-bytes 4))
         (should (eq (cadr case)
                     (anvil-file--stream-eol-mode
                     path (anvil-file--file-generation path)))))))))

(ert-deftest anvil-file-read-bounds-split-utf8-and-short-read ()
  (anvil-file-read-bounds-test--with-bytes
   (concat (make-string 65535 ?a) "\303\251\n")
   (lambda (path)
     (let ((anvil-file-max-inline-read-bytes 65540))
       (should (equal (concat (make-string 65535 ?a) "é\n")
                      (plist-get (anvil-file-read path 0 1) :content))))))
  (dolist (truncate-at '(1 2))
    (anvil-file-read-bounds-test--with-bytes
     "short\n"
     (lambda (path)
       (let ((orig (symbol-function 'insert-file-contents-literally))
             (reads 0))
         (cl-letf (((symbol-function 'insert-file-contents-literally)
                    (lambda (file &optional visit beg end replace)
                      (setq reads (1+ reads))
                      (funcall orig file visit beg
                               (if (= reads truncate-at) (1- end) end)
                               replace))))
           (should-error (anvil-file-read path 0 1))
           (should (= truncate-at reads))))))))

(ert-deftest anvil-file-read-bounds-overflow-stops-selector-and-cleans-buffers ()
  (let ((size (* 17 anvil-file--stream-chunk-bytes)))
    (anvil-file-read-bounds-test--with-bytes
     (make-string size ?x)
     (lambda (path)
       (let ((anvil-file-max-inline-read-bytes 8)
             (orig (symbol-function 'insert-file-contents-literally))
             (make-buffer (symbol-function 'generate-new-buffer))
             (buffers nil) (reads 0))
         (cl-letf (((symbol-function 'generate-new-buffer)
                    (lambda (&rest args)
                      (let ((buffer (apply make-buffer args)))
                        (push buffer buffers) buffer)))
                   ((symbol-function 'insert-file-contents-literally)
                    (lambda (&rest args)
                      (setq reads (1+ reads))
                      (apply orig args)))
                   ((symbol-function 'anvil--insert-file)
                    (lambda (&rest _) (ert-fail "full loader called"))))
           (should-error (anvil-file-read path 0 1))
           ;; Classifier consumes 17 chunks; the selector rejects on its first.
           (should (= 18 reads))
           (should (cl-every (lambda (buffer) (not (buffer-live-p buffer)))
                             buffers))))))))

(ert-deftest anvil-file-read-bounds-generation-rejects-fifo-without-reading ()
  (unless (executable-find "mkfifo") (ert-skip "mkfifo unavailable"))
  (let ((path (make-temp-file "anvil-file-fifo-")) (reader-called nil))
    (unwind-protect
        (progn
          (delete-file path)
          (should (zerop (call-process "mkfifo" nil nil nil path)))
          (cl-letf (((symbol-function 'insert-file-contents-literally)
                     (lambda (&rest _)
                       (setq reader-called t)
                       (ert-fail "FIFO must never be opened"))))
            (should-not (anvil-file--file-generation path))
            (should-error
             (with-temp-buffer
               (anvil-file--insert-capped-unbounded path 16)))
            (should-not reader-called)))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest anvil-file-read-bounds-generation-change-cleans-buffers ()
  (anvil-file-read-bounds-test--with-bytes
   "old\nbody\n"
   (lambda (path)
     (let ((original (symbol-function 'anvil-file--stream-eol-mode))
           (make-buffer (symbol-function 'generate-new-buffer))
           (buffers nil))
       (cl-letf (((symbol-function 'generate-new-buffer)
                  (lambda (&rest args)
                    (let ((buffer (apply make-buffer args)))
                      (push buffer buffers) buffer)))
                 ((symbol-function 'anvil-file--stream-eol-mode)
                  (lambda (target generation)
                    (prog1 (funcall original target generation)
                      (let ((coding-system-for-write 'utf-8-unix))
                        (write-region "new\nbody\n" nil path nil 'silent))
                      (set-file-times path (time-add (current-time)
                                                     (seconds-to-time 2)))))))
         (let ((message (anvil-file-read-bounds-test--error-text
                         (lambda () (anvil-file-read path 0 1)))))
           (should (string-match-p "changed.*retry" message))
           (should-not (string-match-p "new\\|body" message))
           (should (cl-every (lambda (buffer) (not (buffer-live-p buffer)))
                             buffers))))))))

(ert-deftest anvil-file-read-bounds-uri-warnings-and-legacy-parity ()
  (let ((anvil-file-max-inline-read-bytes 128)
        (raw-cases '("" "a\nb\nc" "a\rb\rc" "a\r\nb\r\n"
                     "a\rb\nc" "a\r\nb\r" "a\r\rb\r\n" "xxx\r\ny")))
    (dolist (raw raw-cases)
      (anvil-file-read-bounds-test--with-bytes
       raw
       (lambda (path)
         (let ((anvil-file--stream-chunk-bytes 4))
           (dolist (offset '(0 1 5))
             (let* ((actual (anvil-file-read path offset 2))
                    (expected
                     (with-temp-buffer
                       (anvil--insert-file path)
                       (let ((total (count-lines (point-min) (point-max))))
                         (goto-char (point-min))
                         (forward-line offset)
                         (let* ((start (point))
                                (_ (forward-line 2))
                                (end (point)))
                           (list :content (buffer-substring start end)
                                 :total-lines total
                                 :lines-returned (count-lines start end)))))))
               (should (equal (plist-get expected :content)
                              (plist-get actual :content)))
               (should (= (plist-get expected :total-lines)
                          (plist-get actual :total-lines)))
               (should (= (plist-get expected :lines-returned)
                          (plist-get actual :lines-returned))))))))))
  (anvil-file-read-bounds-test--with-bytes
   "one\ntwo\n"
   (lambda (path)
     (let ((marker '(:buffer-newer t)))
       (cl-letf (((symbol-function 'anvil-file-warn-if-diverged)
                  (lambda (&rest _) marker)))
         (let* ((text (anvil-file--tool-read
                       (concat "file://" path "#L2-2")))
                (result (car (read-from-string text))))
           (should (equal marker (plist-get result :warnings)))
           (should (equal "two\n" (plist-get result :content)))
           (should (= 1 (plist-get result :offset)))))))))

(provide 'anvil-file-read-bounds-test)
;;; anvil-file-read-bounds-test.el ends here
