;;; auto-tag-suggest.el --- Phase 1: suggest tags per note -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Phase 1 of the auto-tag pipeline.  For each note, ask the model for
;; candidate tags and write the results to `auto-tag-suggestions.json'.
;; By default only files that do not yet have tags are processed.

;;; Code:

(require 'auto-tag-core)

(defconst auto-tag--suggest-system
  (concat
   "You are an expert at classifying personal knowledge-base notes. "
   "For each note you will be shown its title and body. "
   "Suggest a small set of concise, reusable tags that capture the note's "
   "main topics, tools, and purpose. "
   "Use lowercase single words or short underscore-separated phrases. "
   "Do not use colons or spaces inside a tag. "
   "Suggest between 1 and %d tags. "
   "Respond with ONLY valid JSON of the form {\"tags\": [\"tag1\", \"tag2\"]} "
   "and nothing else.")
  "System prompt for Phase 1.")

(defun auto-tag--suggest-one (info)
  "Return a list of suggested tags for note INFO."
  (let* ((system (format auto-tag--suggest-system auto-tag-max-tags-per-note))
         (prompt (format "Title: %s\n\nBody:\n%s"
                         (plist-get info :title)
                         (plist-get info :body)))
         (schema '(:type "object"
                   :properties (:tags (:type "array" :items (:type "string")))
                   :required ["tags"]))
         (resp (auto-tag--gptel-json system prompt schema)))
    (auto-tag--normalize-tags (plist-get resp :tags))))

(defun auto-tag--suggest-and-write (notes directory)
  "Suggest tags for NOTES and write `auto-tag-suggestions.json'.

NOTES is a list of note info plists; DIRECTORY locates the data file.
Returns the output file, or nil when NOTES is empty."
  (if (null notes)
      (progn
        (message "auto-tag: no notes to suggest tags for")
        nil)
    (let (files)
      (message "auto-tag: suggesting tags for %d notes in %s"
               (length notes) directory)
      (dolist (info notes)
        (let ((tags (auto-tag--suggest-one info)))
          (push (list :file (plist-get info :file)
                      :title (plist-get info :title)
                      :tags tags)
                files)
          (message "  %s -> %S"
                   (file-name-nondirectory (plist-get info :file)) tags)))
      (let* ((files (nreverse files))
             (results (list :directory (expand-file-name directory)
                            :file-count (length notes)
                            :files files))
             (out (auto-tag--data-file directory auto-tag-suggestions-filename)))
        (auto-tag--write-json out results)
        (message "auto-tag: wrote %s" out)
        out))))

;;;###autoload
(defun auto-tag-suggest (directory &optional include-tagged)
  "Suggest tags for org files in DIRECTORY.

By default only files without existing file-level tags are
processed; with INCLUDE-TAGGED non-nil, all files are processed.
Writes `auto-tag-suggestions.json' in `auto-tag-data-directory'."
  (interactive "DDirectory: ")
  (let ((notes (auto-tag--collect-notes directory)))
    (unless include-tagged
      (setq notes (auto-tag--filter-untagged notes)))
    (auto-tag--suggest-and-write notes directory)))

(defun auto-tag-suggest-files (files &optional include-tagged)
  "Suggest tags for FILES (a list of file paths).

All files must be in one directory.  By default only untagged files
are processed; with INCLUDE-TAGGED non-nil, all are.  Writes
`auto-tag-suggestions.json' in `auto-tag-data-directory'."
  (let* ((directory (auto-tag--files-directory files))
         (notes (auto-tag--notes-from-files files)))
    (unless include-tagged
      (setq notes (auto-tag--filter-untagged notes)))
    (auto-tag--suggest-and-write notes directory)))

;;;###autoload
(defun auto-tag-suggest-project (&optional include-tagged)
  "Suggest tags for the current project directory.

By default only untagged files are processed; with INCLUDE-TAGGED
non-nil, all are."
  (interactive)
  (auto-tag-suggest (auto-tag--project-directory) include-tagged))

(provide 'auto-tag-suggest)
;;; auto-tag-suggest.el ends here
