;;; run-tests.el --- Batch runner for fast auto-tag unit tests -*- lexical-binding: t; -*-

;; Usage: emacs --batch -Q -l test/run-tests.el

(let* ((test-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root (expand-file-name ".." test-dir)))
  (add-to-list 'load-path test-dir)
  (require 'auto-tag-test-util)
  (auto-tag-test--add-load-paths root test-dir))

(require 'auto-tag-test)
(ert-run-tests-batch-and-exit t)

;;; run-tests.el ends here
