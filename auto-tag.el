;;; auto-tag.el --- Run the full auto-tag pipeline -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Convenience entry point that chains the three phases:
;;
;;   1. auto-tag-suggest     - per-note tag suggestions
;;   2. auto-tag-consolidate - controlled vocabulary + assignments
;;   3. auto-tag-apply       - write tags via org-roam

;;; Code:

(require 'auto-tag-suggest)
(require 'auto-tag-consolidate)
(require 'auto-tag-apply)

;;;###autoload
(defun auto-tag-run (directory &optional dry-run only-untagged)
  "Run the full auto-tag pipeline on DIRECTORY.

When DRY-RUN is non-nil, Phase 3 only prints what would change.
When ONLY-UNTAGGED is non-nil, Phase 3 only tags files that do not
already have file-level tags."
  (interactive
   (list (read-directory-name "Directory: ")
         current-prefix-arg
         nil))
  (auto-tag-suggest directory)
  (auto-tag-consolidate directory)
  (auto-tag-apply directory dry-run only-untagged))

(defun auto-tag-run-files (files &optional dry-run only-untagged)
  "Run the full auto-tag pipeline on FILES (a list of file paths).

All files must be in one directory.  See `auto-tag-run' for the
meaning of DRY-RUN and ONLY-UNTAGGED."
  (let ((directory (auto-tag--files-directory files)))
    (auto-tag-suggest-files files)
    (auto-tag-consolidate directory)
    (auto-tag-apply directory dry-run only-untagged)))

(provide 'auto-tag)
;;; auto-tag.el ends here
