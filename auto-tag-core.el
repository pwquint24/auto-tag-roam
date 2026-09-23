;;; auto-tag-core.el --- Shared helpers for auto-tagging org-roam notes -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Shared library for the auto-tag pipeline.  Provides file discovery,
;; read-only note parsing, a synchronous JSON request helper built on
;; gptel, tag normalization, and JSON I/O.
;;
;; Nothing in this file mutates org files.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'project)
(require 'gptel)
(require 'gptel-ollama)

(defgroup auto-tag nil
  "Auto-tag org-roam notes with a local LLM via gptel."
  :group 'org-roam)


;;; User options

(defcustom auto-tag-backend-name "Ollama"
  "Name of the gptel backend to use."
  :type 'string
  :group 'auto-tag)

(defcustom auto-tag-model nil
  "Model to use, as a symbol.
When nil, the first model of `auto-tag-backend-name' is used."
  :type '(choice (const :tag "First backend model" nil) symbol)
  :group 'auto-tag)

(defcustom auto-tag-percentage 0.20
  "Fraction of the number of files used as the target tag count."
  :type 'float
  :group 'auto-tag)

(defcustom auto-tag-max-body-chars 8000
  "Maximum characters of a note body sent to the model."
  :type 'integer
  :group 'auto-tag)

(defcustom auto-tag-max-tags-per-note 6
  "Maximum number of suggested tags to request per note."
  :type 'integer
  :group 'auto-tag)

(defcustom auto-tag-temperature 0.2
  "LLM temperature for tagging requests."
  :type 'number
  :group 'auto-tag)

(defcustom auto-tag-request-timeout 600
  "Maximum seconds to wait for a gptel response."
  :type 'integer
  :group 'auto-tag)

(defcustom auto-tag-suggestions-filename "auto-tag-suggestions.json"
  "Filename for Phase 1 per-note suggestions."
  :type 'string
  :group 'auto-tag)

(defcustom auto-tag-final-filename "auto-tag-final.json"
  "Filename for Phase 2 final vocabulary and assignments."
  :type 'string
  :group 'auto-tag)

(defcustom auto-tag-data-directory
  (expand-file-name "auto-tag" temporary-file-directory)
  "Directory where intermediate JSON data files are written.

The files are temporary pipeline artifacts, so this defaults to a
subdirectory of `temporary-file-directory'."
  :type 'directory
  :group 'auto-tag)


;;; Backend selection

(defun auto-tag--backend ()
  "Return the gptel backend for auto-tag.

Registers a default Ollama backend when none is known under
`auto-tag-backend-name'."
  (unless (assoc auto-tag-backend-name gptel--known-backends)
    (if (equal auto-tag-backend-name "Ollama")
        (gptel-make-ollama auto-tag-backend-name
          :host "localhost:11434"
          :models '("qwen2.5:latest")
          :stream t)
      (user-error "Backend %s is not known to gptel" auto-tag-backend-name)))
  (gptel-get-backend auto-tag-backend-name))

(defun auto-tag--model ()
  "Return the model to use."
  (or auto-tag-model
      (car (gptel-backend-models (auto-tag--backend)))))


;;; Synchronous gptel request

(defun auto-tag--gptel-json (system prompt schema)
  "Send PROMPT to gptel and return the parsed JSON response as a plist.

SYSTEM is the system message, SCHEMA forces JSON output, and the
call blocks until the response arrives.  JSON arrays are returned
as lists."
  (let* ((gptel-backend (auto-tag--backend))
         (gptel-model (auto-tag--model))
         (gptel-temperature auto-tag-temperature)
         (gptel-use-curl (or (executable-find "curl") t))
         (result nil)
         (status nil)
         (done nil))
    (gptel-request prompt
      :system system
      :schema schema
      :stream nil
      :callback (lambda (resp info)
                  (setq status (plist-get info :status))
                  (when (stringp resp)
                    (setq result (string-trim resp)))
                  (setq done t)))
    (let ((wait 0))
      (while (and (not done) (< wait (* auto-tag-request-timeout 10)))
        (accept-process-output nil 0.1)
        (setq wait (1+ wait))))
    (unless done
      (error "auto-tag: gptel request timed out after %d seconds"
             auto-tag-request-timeout))
    (unless (and result (not (string-empty-p result)))
      (error "auto-tag: gptel request failed (status %S)" status))
    (auto-tag--parse-json result)))


;;; JSON helpers

(defun auto-tag--parse-json (str)
  "Parse STR as JSON, returning a plist (arrays become lists).

Tolerates markdown fences and stray text around the JSON value."
  (let ((s (string-trim str)))
    (when (string-match "```[A-Za-z]*[[:space:]]*\n?\\(.*?\\)```" s)
      (setq s (match-string 1 s)))
    (setq s (string-trim s))
    (let* ((first (string-match-p "[{\\[]" s))
           (last (and first
                      (cl-loop for i downfrom (1- (length s)) to first
                               when (memq (aref s i) '(?} ?\]))
                               return i))))
      (unless (and first last)
        (error "auto-tag: no JSON value found in response: %S" str))
      (setq s (substring s first (1+ last)))
      (condition-case err
          (json-parse-string s :object-type 'plist :array-type 'list
                             :null-object nil :false-object :json-false)
        (error (error "auto-tag: JSON parse error: %S (json: %S)" err s))))))

(defun auto-tag--json-plist-p (obj)
  "Return non-nil if OBJ is a plist (JSON object) with keyword keys."
  (and (listp obj)
       (evenp (length obj))
       (let ((tail obj))
         (while (and tail (keywordp (car tail)))
           (setq tail (cddr tail)))
         (null tail))))

(defun auto-tag--json-normalize (obj)
  "Convert OBJ into a form `json-serialize' handles unambiguously.

Plists become alists (JSON objects) and lists become vectors
(JSON arrays), so a list of plists is never mistaken for an
alist."
  (cond
   ((or (null obj) (eq obj t) (eq obj :false) (eq obj :null)) obj)
   ((stringp obj) obj)
   ((numberp obj) obj)
   ((vectorp obj) (vconcat (mapcar #'auto-tag--json-normalize obj)))
   ((auto-tag--json-plist-p obj)
    (let (alist)
      (let ((tail obj))
        (while tail
          ;; Use a non-keyword symbol so the serialized key has no
          ;; leading colon; reading back as a plist adds the colon back.
          (push (cons (intern (substring (symbol-name (car tail)) 1))
                      (auto-tag--json-normalize (cadr tail)))
                alist)
          (setq tail (cddr tail))))
      (nreverse alist)))
   ((listp obj) (vconcat (mapcar #'auto-tag--json-normalize obj)))
   (t (error "auto-tag: cannot serialize value %S" obj))))

(defun auto-tag--write-json (file obj)
  "Write OBJ to FILE as pretty-printed JSON.

Creates FILE's parent directory if needed."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  (with-temp-buffer
    (insert (json-serialize (auto-tag--json-normalize obj)
                            :null-object nil :false-object :json-false))
    (json-pretty-print (point-min) (point-max))
    (write-region (point-min) (point-max) file nil 'silent))
  file)

(defun auto-tag--read-json (file)
  "Read FILE and parse it as a JSON plist (arrays become lists)."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'plist :array-type 'list
                       :null-object nil :false-object :json-false)))


;;; File discovery and parsing

(defun auto-tag--org-files (directory)
  "Return absolute paths of the org files in DIRECTORY, sorted."
  (let ((dir (file-name-as-directory (expand-file-name directory))))
    (directory-files dir t "\\.org\\'")))

(defun auto-tag--keyword-value (name)
  "Return the value of the `#+NAME:' keyword in the current buffer."
  (let ((case-fold-search t))
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^[ \t]*#\\+" (regexp-quote name) ":[ \t]*\\(.*\\)[ \t]*$")
             nil t)
        (match-string 1)))))

(defun auto-tag--current-tags ()
  "Return current file-level tags in the current buffer as a list."
  (let ((raw (auto-tag--keyword-value "filetags")))
    (when raw
      (split-string raw ":" 'omit-nulls))))

(defun auto-tag--trim-body (body)
  "Remove FILETAGS keyword lines from BODY and truncate it."
  (let ((s (replace-regexp-in-string "^[ \t]*#\\+filetags:.*\n" "" body)))
    (substring s 0 (min auto-tag-max-body-chars (length s)))))

(defun auto-tag--note-info (file)
  "Return a plist describing FILE.

Keys are :file, :title, :tags and :body."
  (with-temp-buffer
    (insert-file-contents file)
    (let* ((title (or (auto-tag--keyword-value "title") ""))
           (tags (auto-tag--current-tags))
           (body (auto-tag--trim-body (buffer-string))))
      (list :file (expand-file-name file)
            :title (string-trim title)
            :tags tags
            :body body))))

(defun auto-tag--collect-notes (directory)
  "Return note info plists for the org files in DIRECTORY."
  (mapcar #'auto-tag--note-info (auto-tag--org-files directory)))

(defun auto-tag--notes-from-files (files)
  "Return note info plists for FILES (a list of file paths)."
  (mapcar #'auto-tag--note-info files))

(defun auto-tag--files-directory (files)
  "Return the single directory containing FILES, or signal an error.

The list-of-files entry points require all files to live in one
directory so the data files can be located next to that directory."
  (let ((dirs (delete-dups (mapcar #'file-name-directory
                                   (mapcar #'expand-file-name files)))))
    (cond
     ((null files) (user-error "No files given"))
     ((= 1 (length dirs)) (car dirs))
     (t (user-error "Files must all be in one directory")))))

(defun auto-tag--file-has-tags-p (file)
  "Return non-nil if FILE already has file-level tags."
  (with-temp-buffer
    (insert-file-contents file)
    (and (auto-tag--current-tags) t)))

(defun auto-tag--filter-untagged (notes)
  "Return NOTES, dropping entries whose file already has tags."
  (seq-filter (lambda (info) (null (plist-get info :tags))) notes))


;;; Tag normalization

(defun auto-tag--normalize-tag (tag)
  "Normalize TAG to a safe org tag string.

Returns nil when TAG is not a string."
  (when (stringp tag)
    (let ((s (downcase (string-trim tag))))
      (setq s (replace-regexp-in-string "[[:space:]]+" "_" s))
      (setq s (replace-regexp-in-string ":" "_" s))
      (setq s (replace-regexp-in-string "^_+\\|_+$" "" s))
      s)))

(defun auto-tag--normalize-tags (tags)
  "Normalize and deduplicate TAGS, dropping empty entries."
  (seq-uniq
   (seq-filter (lambda (s) (and (stringp s) (not (string-empty-p s))))
               (mapcar #'auto-tag--normalize-tag tags))
   #'string-equal))


;;; Data file locations

(defun auto-tag--data-file (directory filename)
  "Return the temp data file path for DIRECTORY and FILENAME.

Intermediate JSON files are written to `auto-tag-data-directory'.
A hash of DIRECTORY is included in the name so different
directories do not collide."
  (let ((key (md5 (file-name-as-directory (expand-file-name directory)))))
    (expand-file-name (concat key "-" filename) auto-tag-data-directory)))

(defun auto-tag--ensure-data-directory ()
  "Ensure `auto-tag-data-directory' exists."
  (unless (file-directory-p auto-tag-data-directory)
    (make-directory auto-tag-data-directory t)))

;;; Project directory

(defun auto-tag--project-directory ()
  "Return the current project root, or `default-directory'.

Uses `project-current' to find the project root."
  (or (when-let* ((proj (project-current)))
        (project-root proj))
      (expand-file-name default-directory)))

(provide 'auto-tag-core)
;;; auto-tag-core.el ends here
