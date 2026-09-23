;;; auto-tag-suggest.el --- Phase 1: suggest tags per note -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Phase 1 of the auto-tag pipeline.  For each single-note org file
;; in a directory, ask the model for candidate tags and write the
;; results to `auto-tag-suggestions.json'.

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

NOTES is a list of note info plists; DIRECTORY locates the data file."
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
      out)))

;;;###autoload
(defun auto-tag-suggest (directory)
  "Suggest tags for each org file in DIRECTORY.

Writes results to `auto-tag-suggestions.json' in DIRECTORY's parent."
  (interactive "DDirectory: ")
  (auto-tag--suggest-and-write (auto-tag--collect-notes directory) directory))

(defun auto-tag-suggest-files (files)
  "Suggest tags for FILES (a list of file paths).

All files must be in one directory.  Writes results to
`auto-tag-suggestions.json' in that directory's parent."
  (let ((directory (auto-tag--files-directory files)))
    (auto-tag--suggest-and-write (auto-tag--notes-from-files files) directory)))

(provide 'auto-tag-suggest)
;;; auto-tag-suggest.el ends here
