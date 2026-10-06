;;; anvil-stdio-timeout-test.el --- Black-box timeout contract -*- lexical-binding: t; -*-

(require 'ert)
(require 'subr-x)

(defconst anvil-stdio-timeout-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest anvil-stdio-timeout-test/python-contract ()
  "Run the black-box stdio bridge timeout contract checks."
  (let* ((test-dir anvil-stdio-timeout-test--dir)
         (repo-dir (file-name-directory (directory-file-name test-dir)))
         (script (expand-file-name "anvil-stdio.sh" repo-dir))
         (python (or (executable-find "python3") (ert-skip "python3 unavailable")))
         (timeout-bin (executable-find "timeout")))
    (unless (and (eq system-type 'gnu/linux) timeout-bin)
      (ert-skip "Timeout contract suite is qualified only with Linux GNU coreutils"))
    (with-temp-buffer
      (unless (and (= 0 (call-process timeout-bin nil t nil "--version"))
                   (string-match-p "GNU coreutils" (buffer-string)))
        (ert-skip "GNU timeout unavailable; timeout-specific cases require Linux coreutils")))
    (with-temp-buffer
      (let ((status (call-process python nil t nil
                                  (expand-file-name "anvil-stdio-timeout-test.py" test-dir)
                                  "--script" script)))
        (should (= status 0))
        (should (string-match-p "PASS" (buffer-string)))))))

(ert-deftest anvil-stdio-timeout-test/perl-contract ()
  "Run the fallback contract without relying on GNU timeout."
  (unless (memq system-type '(gnu/linux darwin))
    (ert-skip "Perl process-group contracts require Linux or macOS"))
  (let* ((test-dir anvil-stdio-timeout-test--dir)
         (repo-dir (file-name-directory (directory-file-name test-dir)))
         (python (or (executable-find "python3") (ert-skip "python3 unavailable")))
         (perl (or (executable-find "perl") (ert-skip "Perl unavailable"))))
    (with-temp-buffer
      (unless (= 0 (call-process perl nil t nil "-MPOSIX" "-MTime::HiRes"
                                "-e" "POSIX::isfinite(Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())) or die"))
        (ert-skip "Perl POSIX monotonic clock unavailable")))
    (with-temp-buffer
      (let ((status (call-process python nil t nil
                                  (expand-file-name "anvil-stdio-timeout-test.py" test-dir)
                                  "--script" (expand-file-name "anvil-stdio.sh" repo-dir)
                                  "--backend" "perl")))
        (should (= status 0))
        (should (string-match-p "PASS" (buffer-string)))))))

(provide 'anvil-stdio-timeout-test)
;;; anvil-stdio-timeout-test.el ends here
