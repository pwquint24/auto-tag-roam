;;; run-ollama-test.el --- Batch runner for the Ollama integration test -*- lexical-binding: t; -*-

;; Usage: emacs --batch -Q -l test/run-ollama-test.el

(let* ((test-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root (expand-file-name ".." test-dir)))
  (add-to-list 'load-path test-dir)
  (require 'auto-tag-test-util)
  (auto-tag-test--add-load-paths root test-dir))

(require 'auto-tag-ollama-test)
(ert-run-tests-batch-and-exit t)

;;; run-ollama-test.el ends here
