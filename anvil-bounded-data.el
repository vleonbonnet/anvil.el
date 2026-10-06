;;; anvil-bounded-data.el --- Pure bounded snapshots of Lisp data -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 zawatton

;; This file is part of anvil.el.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'cl-lib)

(defvar anvil-bounded-data--snapshot-node-limit 512)
(defvar anvil-bounded-data--snapshot-depth-limit 8)
(defvar anvil-bounded-data--snapshot-char-limit 4096)

(defun anvil-bounded-data--finite-limit (value default)
  (if (and (integerp value) (>= value 0))
      (min value anvil-bounded-data--snapshot-char-limit)
    default))

(defun anvil-bounded-data--bounded-symbol-properties (symbol)
  "Copy SYMBOL's error metadata through a bounded plist traversal."
  (let ((tail (symbol-plist symbol)) (seen (make-hash-table :test #'eq))
        (message-value nil) (conditions-value nil) (steps 0) (malformed nil)
        (message-found nil) (conditions-found nil) (stopped-early nil))
    (while (and (consp tail) (< steps anvil-bounded-data--snapshot-node-limit)
                (not (gethash tail seen))
                (not (and message-found conditions-found)))
      (puthash tail t seen)
      (let ((value-cell (cdr tail)))
        (if (not (consp value-cell))
            (setq tail nil malformed t)
          (puthash value-cell t seen)
          (when (and (eq (car tail) 'error-message) (not message-found))
            (setq message-value (car value-cell) message-found t))
          (when (and (eq (car tail) 'error-conditions) (not conditions-found))
            (setq conditions-value (car value-cell) conditions-found t))
          (setq tail (cdr value-cell)
                steps (+ steps 2)))))
    (setq stopped-early
          (and (consp tail) (not (and message-found conditions-found))))
    (list :error-message message-value :error-conditions conditions-value
          :steps steps :truncated (or malformed stopped-early))))

(defun anvil-bounded-data--safe-condition-names (symbol condition-value)
  "Return a normalized formatter condition list for SYMBOL."
  (let ((tail condition-value) (seen (make-hash-table :test #'eq))
        (out nil) (steps 0))
    (while (and (consp tail) (< steps anvil-bounded-data--snapshot-node-limit)
                (not (gethash tail seen)))
      (puthash tail t seen)
      (when (eq (car tail) 'file-error) (push 'file-error out))
      (setq tail (cdr tail) steps (1+ steps)))
    (cond ((memq 'file-error out) '(file-error error))
          ((memq symbol '(void-function wrong-type-argument wrong-number-of-arguments))
           (list symbol 'error))
          (t '(error)))))

(defun anvil-bounded-data--render-snapshot (snapshot &optional message-max raw-max)
  "Render trusted already-bounded SNAPSHOT into message and raw-context strings.
SNAPSHOT must be the result of `anvil-bounded-data--bounded-snapshot'."
  (let* ((value (plist-get snapshot :value))
         (msg-limit (anvil-bounded-data--finite-limit message-max 4096))
         (raw-limit (anvil-bounded-data--finite-limit raw-max 500))
         (float-output-format nil) (print-gensym nil)
         (print-length 512) (print-level 8) (print-circle t)
         (message-text
          (cond
           ((stringp value) value)
           ((and (consp value) (symbolp (car value)))
            (if (eq (car value) 'error)
                (condition-case nil
                    (error-message-string (cons 'error (cdr value)))
                  (error (format "%S" value)))
              (let* ((head (make-symbol (substring-no-properties (symbol-name (car value)))))
                     (properties (anvil-bounded-data--bounded-symbol-properties (car value)))
                     (metadata (or (plist-get properties :error-message)
                                   (and (plist-get properties :truncated) "<metadata truncated>")))
                     (meta-snap (and metadata (anvil-bounded-data--bounded-snapshot metadata 4096)))
                     (meta (if meta-snap (plist-get meta-snap :value) nil)))
                (put head 'error-conditions
                     (anvil-bounded-data--safe-condition-names
                      (car value) (plist-get properties :error-conditions)))
                (when metadata
                  (if (not (stringp meta))
                      (put head 'error-message "<invalid error-message>")
                    (if (cl-some (lambda (directive)
                                   (string-match-p (regexp-quote directive) meta))
                                 '("\\[" "\\<" "\\{" "\\="))
                        (put head 'error-message "<key sequence elided>")
                      (put head 'error-message meta))))
                (condition-case nil
                    (error-message-string (cons head (cdr value)))
                  (error (format "%S" value))))))
           ((null value) "")
           (t (format "%S" value))))
         (raw (let ((print-length 512) (print-level 8) (print-circle t)
                    (float-output-format nil) (print-gensym nil))
                (format "%S" value))))
    (list :message (substring-no-properties message-text 0 (min msg-limit (length message-text)))
          :raw-context (substring-no-properties raw 0 (min raw-limit (length raw))))))

(defun anvil-bounded-data--bounded-snapshot (value &optional maxchars)
  "Copy VALUE into a bounded printable data tree.
MAXCHARS limits leaf characters; return :value, :nodes, and :chars."
  (let ((left (if (and (integerp maxchars) (>= maxchars 0))
                  (min maxchars anvil-bounded-data--snapshot-char-limit)
                anvil-bounded-data--snapshot-char-limit))
        (chars 0) (nodes 0) (path (make-hash-table :test #'eq)))
    (cl-labels
        ((token (s)
           (let ((n (min left (length s))))
             (setq left (- left n) chars (+ chars n))
             (substring-no-properties s 0 n)))
         (walk (x depth)
           (cond
            ((>= nodes anvil-bounded-data--snapshot-node-limit)
             (token "<nodes>"))
            (t
             (setq nodes (1+ nodes))
             (cond
              ((stringp x)
               (let ((out (token x))) (set-text-properties 0 (length out) nil out) out))
              ((symbolp x)
               (let ((n (length (symbol-name x))))
                 (if (and (<= n 128) (<= n left))
                     (progn (setq left (- left n) chars (+ chars n)) x)
                   (token "<symbol>"))))
              ((or (null x) (eq x t) (and (integerp x) (<= most-negative-fixnum x most-positive-fixnum))
                   (floatp x)) x)
              ((or (integerp x) (hash-table-p x) (recordp x)) (token "<opaque>"))
              ((or (consp x) (vectorp x))
               (cond ((>= depth anvil-bounded-data--snapshot-depth-limit) (token "<depth>"))
                     ((gethash x path) (token "<cycle>"))
                     (t
                      (puthash x t path)
                      (let ((out
                             (if (consp x)
                                 (cons (walk (car x) (1+ depth))
                                       (walk (cdr x) (1+ depth)))
                               (let ((i 0) (n (length x)) (items nil))
                                 (while (and (< i n) (< nodes anvil-bounded-data--snapshot-node-limit))
                                   (push (walk (aref x i) (1+ depth)) items)
                                   (setq i (1+ i)))
                                 (vconcat (nreverse items))))))
                        (remhash x path) out))))
              (t (token "<opaque>")))))))
      (list :value (walk value 0) :nodes nodes :chars chars))))

(provide 'anvil-bounded-data)
;;; anvil-bounded-data.el ends here
