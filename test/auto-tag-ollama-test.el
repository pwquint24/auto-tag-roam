;;; auto-tag-ollama-test.el --- Optional real-Ollama integration test -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A single, slow integration test that asks the real local model for
;; tags on one fixture file.  This is intentionally kept separate from
;; the fast unit tests.  Run via `test/run-ollama-test.el'.
;;
;; Adjust the `defvar's below (or bind them) to point at your model.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'auto-tag-test-util)
(require 'auto-tag)

(defvar auto-tag-ollama-test-backend "Ollama"
  "gptel backend name to use for the Ollama integration test.")

(defvar auto-tag-ollama-test-model nil
  "Model to use for the Ollama integration test (nil = first backend model).")

(defun auto-tag-ollama-test--reachable-p ()
  "Return non-nil if the configured Ollama host answers /api/tags."
  (let ((host (condition-case nil
                  (gptel-backend-host (gptel-get-backend auto-tag-ollama-test-backend))
                (error "localhost:11434"))))
    (and (executable-find "curl")
         (zerop (call-process "curl" nil nil nil
                              "--silent" "--max-time" "3"
                              (format "http://%s/api/tags" host))))))

(ert-deftest auto-tag-ollama-single-file ()
  "Ask the real Ollama model for tags on a single fixture file.

Skipped when Ollama is unreachable or curl is missing."
  (unless (auto-tag-ollama-test--reachable-p)
    (ert-skip "Ollama is not reachable (skipping integration test)"))
  (let* ((auto-tag-backend-name auto-tag-ollama-test-backend)
         (auto-tag-model auto-tag-ollama-test-model)
         (file (expand-file-name "note-a.org" (auto-tag-test-fixture-dir)))
         (info (auto-tag--note-info file))
         (tags (auto-tag--suggest-one info)))
    (should (listp tags))
    (should (cl-every #'stringp tags))
    (should (> (length tags) 0))))

(provide 'auto-tag-ollama-test)
;;; auto-tag-ollama-test.el ends here
