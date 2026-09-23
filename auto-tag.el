;;; auto-tag.el --- Run the full auto-tag pipeline -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Convenience entry point that chains the three phases:
;;
;;   1. auto-tag-suggest     - per-note tag suggestions
;;   2. auto-tag-consolidate - controlled vocabulary + assignments
;;   3. auto-tag-apply       - write tags via org-roam
;;
;; By default only files that do not yet have tags are processed.

;;; Code:

(require 'auto-tag-suggest)
(require 'auto-tag-consolidate)
(require 'auto-tag-apply)

;;;###autoload
(defun auto-tag-run (directory &optional dry-run include-tagged)
  "Run the full auto-tag pipeline on DIRECTORY.

By default only untagged files are suggested and tagged; pass
INCLUDE-TAGGED non-nil to process all files.  When DRY-RUN is
non-nil, Phase 3 only prints what would change."
  (interactive
   (list (read-directory-name "Directory: ")
         current-prefix-arg
         nil))
  (when (auto-tag-suggest directory include-tagged)
    (auto-tag-consolidate directory)
    (auto-tag-apply directory dry-run include-tagged)))

(defun auto-tag-run-files (files &optional dry-run include-tagged)
  "Run the full auto-tag pipeline on FILES (a list of file paths).

All files must be in one directory.  By default only untagged files
are processed; pass INCLUDE-TAGGED non-nil to process all."
  (let ((directory (auto-tag--files-directory files)))
    (when (auto-tag-suggest-files files include-tagged)
      (auto-tag-consolidate directory)
      (auto-tag-apply directory dry-run include-tagged))))

;;;###autoload
(defun auto-tag-run-project (&optional dry-run include-tagged)
  "Run the full auto-tag pipeline on the current project directory.

By default only untagged files are processed; pass INCLUDE-TAGGED
non-nil to process all.  When DRY-RUN is non-nil, Phase 3 only
prints what would change."
  (interactive (list current-prefix-arg nil))
  (auto-tag-run (auto-tag--project-directory) dry-run include-tagged))

(provide 'auto-tag)
;;; auto-tag.el ends here
