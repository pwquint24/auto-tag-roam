;;; auto-tag-apply.el --- Phase 3: apply tags via org-roam -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Phase 3 of the auto-tag pipeline.  Reads `auto-tag-final.json' and
;; writes the final tags into each note using only org-roam's editing
;; functions (`org-roam-tag-add'), which merge with any existing tags.
;;
;; By default only files that do not yet have file-level tags are
;; tagged, so re-running the pipeline does not modify already-tagged
;; notes.

;;; Code:

(require 'auto-tag-core)
(require 'org-roam)

(defun auto-tag--add-file-tags (file tags)
  "Add TAGS (list of strings) to FILE's file-level tags via org-roam."
  (let ((buf (find-file-noselect file t))
        (make-backup-files nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (org-roam-tag-add tags)
          (save-buffer))
      (kill-buffer buf))))

(defun auto-tag--apply-assignments (assignments &optional dry-run include-tagged)
  "Apply ASSIGNMENTS (list of plists) to their files.

When INCLUDE-TAGGED is nil (the default), skip files that already
have file-level tags.  When DRY-RUN is non-nil, only print what
would change."
  (dolist (a assignments)
    (let ((file (plist-get a :file))
          (tags (plist-get a :tags)))
      (cond
       ((not (file-exists-p file))
        (message "auto-tag: skipping missing file %s" file))
       ((and (not include-tagged) (auto-tag--file-has-tags-p file))
        (message "auto-tag: skipping already-tagged file %s"
                 (file-name-nondirectory file)))
       (dry-run
        (message "auto-tag [dry-run]: %s would add %S"
                 (file-name-nondirectory file) tags))
       (t
        (auto-tag--add-file-tags file tags)
        (message "auto-tag: %s +%S" (file-name-nondirectory file) tags)))))
  (message "auto-tag: processed %d notes%s"
           (length assignments) (if dry-run " (dry-run)" "")))

;;;###autoload
(defun auto-tag-apply (directory &optional dry-run include-tagged)
  "Apply final tags from `auto-tag-final.json' to notes in DIRECTORY.

By default only untagged files are tagged; pass INCLUDE-TAGGED
non-nil to also tag files that already have file-level tags.  When
DRY-RUN is non-nil, only print what would change."
  (interactive
   (list (read-directory-name "Directory: ")
         current-prefix-arg
         nil))
  (let* ((final-file (auto-tag--data-file directory auto-tag-final-filename))
         (final (auto-tag--read-json final-file)))
    (auto-tag--apply-assignments (plist-get final :assignments)
                                 dry-run include-tagged)))

(defun auto-tag-apply-files (files &optional dry-run include-tagged)
  "Apply final tags to FILES (a list of file paths).

Only assignments whose file is in FILES are applied.  All files must
be in one directory so `auto-tag-final.json' can be located next to
it.  By default only untagged files are tagged; pass INCLUDE-TAGGED
non-nil to also tag already-tagged files."
  (let* ((directory (auto-tag--files-directory files))
         (final-file (auto-tag--data-file directory auto-tag-final-filename))
         (final (auto-tag--read-json final-file))
         (want (mapcar #'expand-file-name files))
         (assignments (seq-filter
                       (lambda (a) (member (plist-get a :file) want))
                       (plist-get final :assignments))))
    (auto-tag--apply-assignments assignments dry-run include-tagged)))

;;;###autoload
(defun auto-tag-apply-project (&optional dry-run include-tagged)
  "Apply final tags to the current project directory.

By default only untagged files are tagged; pass INCLUDE-TAGGED
non-nil to also tag already-tagged files.  When DRY-RUN is non-nil,
only print what would change."
  (interactive (list current-prefix-arg nil))
  (auto-tag-apply (auto-tag--project-directory) dry-run include-tagged))

(provide 'auto-tag-apply)
;;; auto-tag-apply.el ends here
