;;; auto-tag-consolidate.el --- Phase 2: consolidate tags into a vocabulary -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Phase 2 of the auto-tag pipeline.  Reads the per-note suggestions,
;; asks the model to build a controlled vocabulary of roughly
;; `auto-tag-percentage' of the file count, assigns each note a subset,
;; and writes `auto-tag-final.json'.

;;; Code:

(require 'auto-tag-core)

(defconst auto-tag--consolidate-system
  (concat
   "You are a taxonomy designer for a personal knowledge base. "
   "You will be given a list of notes and the candidate tags suggested for each. "
   "Design a controlled vocabulary of EXACTLY %d tags: "
   "lowercase single words or short underscore-separated phrases, no colons or spaces. "
   "Merge near-synonyms into a single tag, and prefer tags reusable across several notes. "
   "Then assign each note the subset of the vocabulary that applies to it. "
   "Respond with ONLY valid JSON of the form "
   "{\"vocabulary\": [\"tag1\", ...], "
   "\"assignments\": [{\"file\": \"<basename>\", \"tags\": [\"tag1\", ...]}, ...]} "
   "and nothing else.")
  "System prompt for Phase 2.")

(defun auto-tag--consolidate-prompt (files)
  "Build the Phase 2 user prompt from FILES (list of plists)."
  (let ((lines nil))
    (dolist (f files)
      (push (format "- %s: %s"
                    (file-name-nondirectory (plist-get f :file))
                    (mapconcat #'identity (plist-get f :tags) ", "))
            lines))
    (concat "Notes and suggested tags:\n"
            (mapconcat #'identity (nreverse lines) "\n"))))

;;;###autoload
(defun auto-tag-consolidate (directory)
  "Consolidate Phase 1 suggestions for DIRECTORY into a vocabulary.

Reads `auto-tag-suggestions.json' and writes `auto-tag-final.json'
in `auto-tag-data-directory'."
  (interactive "DDirectory: ")
  (let* ((sugg-file (auto-tag--data-file directory auto-tag-suggestions-filename))
         (sugg (auto-tag--read-json sugg-file))
         (files (plist-get sugg :files))
         (count (length files))
         (target (max 1 (ceiling (* auto-tag-percentage count))))
         (system (format auto-tag--consolidate-system target))
         (prompt (concat (auto-tag--consolidate-prompt files)
                         (format "\n\nTarget number of tags: %d\n" target)))
         (schema '(:type "object"
                   :properties
                   (:vocabulary (:type "array" :items (:type "string"))
                    :assignments
                    (:type "array"
                           :items
                           (:type "object"
                                  :properties
                                  (:file (:type "string")
                                   :tags (:type "array" :items (:type "string")))
                                  :required ["file" "tags"])))
                   :required ["vocabulary" "assignments"]))
         (resp (auto-tag--gptel-json system prompt schema))
         (vocab (auto-tag--normalize-tags (plist-get resp :vocabulary)))
         (assignments nil))
    (message "auto-tag: consolidating %d notes into %d tags" count target)
    (dolist (a (plist-get resp :assignments))
      (let ((base (file-name-nondirectory (plist-get a :file)))
            (tags (auto-tag--normalize-tags (plist-get a :tags))))
        (push (list :file (expand-file-name base directory)
                    :tags tags)
              assignments)))
    (let* ((assignments (nreverse assignments))
           (results (list :directory (expand-file-name directory)
                          :target-count target
                          :vocabulary vocab
                          :assignments assignments))
           (out (auto-tag--data-file directory auto-tag-final-filename)))
      (auto-tag--write-json out results)
      (message "auto-tag: vocabulary (%d): %S" (length vocab) vocab)
      (message "auto-tag: wrote %s" out)
      out)))

;;;###autoload
(defun auto-tag-consolidate-project ()
  "Consolidate Phase 1 suggestions for the current project directory."
  (interactive)
  (auto-tag-consolidate (auto-tag--project-directory)))

(provide 'auto-tag-consolidate)
;;; auto-tag-consolidate.el ends here
