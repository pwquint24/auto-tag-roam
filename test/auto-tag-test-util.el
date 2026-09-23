;;; auto-tag-test-util.el --- Shared helpers for auto-tag ERT tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Load-path bootstrap and fixture helpers used by the ERT test files.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar auto-tag-test--straight-build-dir nil
  "Override for the straight build directory, when autodetection fails.")

(defvar auto-tag-test--test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this file.")

(defvar auto-tag-test--root-dir
  (expand-file-name ".." auto-tag-test--test-dir)
  "Repository root directory (parent of the test directory).")

(defun auto-tag-test--find-straight-build ()
  "Return the straight build directory, or nil.

Prefers the build directory matching the running Emacs version,
falling back to the newest `build-*' directory (excluding
`-cache.el' files)."
  (or auto-tag-test--straight-build-dir
      (let* ((straight (expand-file-name "~/.config/emacs/.local/straight/"))
             (ver (format "build-%d.%d" emacs-major-version emacs-minor-version))
             (exact (expand-file-name ver straight)))
        (if (file-directory-p exact)
            exact
          (car (last (sort (seq-filter #'file-directory-p
                                       (directory-files straight t "\\`build-" t))
                           #'string<)))))))

(defun auto-tag-test--add-load-paths (&optional root test-dir)
  "Add ROOT, TEST-DIR and straight build directories to `load-path'.

Defaults ROOT and TEST-DIR to the repository root and test dir."
  (let ((root (or root auto-tag-test--root-dir))
        (test-dir (or test-dir auto-tag-test--test-dir)))
    (add-to-list 'load-path root)
    (add-to-list 'load-path test-dir)
    (let ((build (auto-tag-test--find-straight-build)))
      (when (and build (file-directory-p build))
        (dolist (d (directory-files build t "\\`[^.]"))
          (when (file-directory-p d)
            (add-to-list 'load-path d)))))))

(defun auto-tag-test-fixture-dir ()
  "Return the fixtures directory."
  (expand-file-name "fixtures" auto-tag-test--test-dir))

(defun auto-tag-test-copy-fixtures (dest-dir)
  "Copy fixture org files into DEST-DIR."
  (dolist (f (directory-files (auto-tag-test-fixture-dir) t "\\.org\\'"))
    (copy-file f (expand-file-name (file-name-nondirectory f) dest-dir)))
  dest-dir)

(defun auto-tag-test-make-temp-notes ()
  "Create a unique temp directory with fixture copies in a `notes' subdir.

Returns the `notes' directory; its parent is unique per test."
  (let* ((root (file-name-as-directory (make-temp-file "auto-tag-test-" t)))
         (notes (file-name-as-directory (expand-file-name "notes" root))))
    (make-directory notes)
    (auto-tag-test-copy-fixtures notes)
    notes))

(defun auto-tag-test--with-temp (fn)
  "Call FN with a fresh temp notes directory, cleaning up afterwards."
  (let ((dir (auto-tag-test-make-temp-notes)))
    (unwind-protect
        (funcall fn dir)
      (delete-directory (file-name-directory (directory-file-name dir)) t)
      (dolist (f (list auto-tag-suggestions-filename auto-tag-final-filename))
        (ignore-errors (delete-file (auto-tag--data-file dir f)))))))

(defun auto-tag-test--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(provide 'auto-tag-test-util)
;;; auto-tag-test-util.el ends here
