;;; auto-tag-test.el --- ERT tests for auto-tag (faked AI) -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Fast unit tests.  All model interaction is faked by overriding
;; `auto-tag--gptel-json' with `cl-letf', so no network or Ollama is
;; needed.  Run via `test/run-tests.el'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'auto-tag-test-util)
(require 'auto-tag)

(defun auto-tag-test--fake-gptel (response)
  "Return a function that ignores its arguments and returns RESPONSE."
  (lambda (&rest _) response))

(defun auto-tag-test--data-file (dir filename)
  "Return the data file path for DIR/FILENAME."
  (auto-tag--data-file dir filename))


;;; Core: file discovery and parsing

(ert-deftest auto-tag-org-files-finds-fixtures ()
  (let ((files (auto-tag--org-files (auto-tag-test-fixture-dir))))
    (should (= 3 (length files)))
    (should (cl-every #'file-exists-p files))
    (should (equal '("note-a.org" "note-b.org" "note-c.org")
                   (mapcar #'file-name-nondirectory files)))))

(ert-deftest auto-tag-keyword-value-reads-title ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "note-a.org" (auto-tag-test-fixture-dir)))
    (should (equal "emacs config" (auto-tag--keyword-value "title")))))

(ert-deftest auto-tag-current-tags-parses-filetags ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "note-a.org" (auto-tag-test-fixture-dir)))
    (should (equal '("gpt") (auto-tag--current-tags)))))

(ert-deftest auto-tag-current-tags-nil-when-absent ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "note-b.org" (auto-tag-test-fixture-dir)))
    (should-not (auto-tag--current-tags))))

(ert-deftest auto-tag-note-info-shape ()
  (let ((info (auto-tag--note-info
               (expand-file-name "note-b.org" (auto-tag-test-fixture-dir)))))
    (should (string-match-p "note-b\\.org\\'" (plist-get info :file)))
    (should (equal "python tips" (plist-get info :title)))
    (should-not (plist-get info :tags))
    (should (string-match-p "Python tips" (plist-get info :body)))
    (should-not (string-match-p "#\\+filetags:" (plist-get info :body)))))

(ert-deftest auto-tag-note-info-body-strips-filetags ()
  (let ((info (auto-tag--note-info
               (expand-file-name "note-a.org" (auto-tag-test-fixture-dir)))))
    (should-not (string-match-p "#\\+filetags:" (plist-get info :body)))))


;;; Tag normalization

(ert-deftest auto-tag-normalize-tags ()
  (should (equal '("emacs" "some_tag" "x")
                 (auto-tag--normalize-tags
                  '("Emacs" "some tag" ":x:" "" "emacs" nil)))))


;;; JSON round trip

(ert-deftest auto-tag-json-round-trip ()
  (let ((file (make-temp-file "auto-tag-json-" nil ".json"))
        (obj '(:directory "/tmp/x" :file-count 2
               :files ((:file "/tmp/x/a.org" :title "a" :tags ("x" "y"))
                       (:file "/tmp/x/b.org" :title "b" :tags ("z"))))))
    (unwind-protect
        (progn
          (auto-tag--write-json file obj)
          (let ((back (auto-tag--read-json file)))
            (should (equal "/tmp/x" (plist-get back :directory)))
            (should (equal 2 (plist-get back :file-count)))
            (should (equal '("x" "y")
                           (plist-get (car (plist-get back :files)) :tags)))))
      (delete-file file))))


;;; Phase 1 (suggest) with a faked model

(ert-deftest auto-tag-suggest-one-fake ()
  (let ((info '(:file "/x/a.org" :title "Emacs tips" :body "lisp keybindings" :tags nil)))
    (cl-letf (((symbol-function 'auto-tag--gptel-json)
               (lambda (system prompt _schema)
                 (should (string-match-p "Emacs tips" prompt))
                 (should (string-match-p "lisp keybindings" prompt))
                 '(:tags ("Emacs" "lisp")))))
      (should (equal '("emacs" "lisp") (auto-tag--suggest-one info))))))

(ert-deftest auto-tag-suggest-writes-file-with-fake ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (cl-letf (((symbol-function 'auto-tag--gptel-json)
                (auto-tag-test--fake-gptel '(:tags ("Emacs" "lisp")))))
       (auto-tag-suggest dir t))                 ; include already-tagged
     (let* ((out (auto-tag-test--data-file dir auto-tag-suggestions-filename))
            (data (auto-tag--read-json out)))
       (should (file-exists-p out))
       (should (equal 3 (plist-get data :file-count)))
       (dolist (f (plist-get data :files))
         (should (equal '("emacs" "lisp") (plist-get f :tags))))))))

(ert-deftest auto-tag-suggest-default-only-untagged ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (cl-letf (((symbol-function 'auto-tag--gptel-json)
                (auto-tag-test--fake-gptel '(:tags ("emacs")))))
       (auto-tag-suggest dir))                   ; default: untagged only
     (let* ((out (auto-tag-test--data-file dir auto-tag-suggestions-filename))
            (data (auto-tag--read-json out)))
       (should (file-exists-p out))
       ;; Only note-b.org is untagged.
       (should (equal 1 (plist-get data :file-count)))
       (should (equal '("note-b.org")
                      (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file)))
                              (plist-get data :files))))))))


;;; Phase 2 (consolidate) with a faked model

(ert-deftest auto-tag-consolidate-writes-file-with-fake ()
  (auto-tag-test--with-temp
   (lambda (dir)
     ;; Seed suggestions.json directly.
     (auto-tag--write-json
      (auto-tag-test--data-file dir auto-tag-suggestions-filename)
      '(:directory "/tmp/x" :file-count 3
        :files ((:file "/tmp/x/note-a.org" :title "a" :tags ("emacs"))
                (:file "/tmp/x/note-b.org" :title "b" :tags ("python"))
                (:file "/tmp/x/note-c.org" :title "c" :tags ("sqlite")))))
     (cl-letf (((symbol-function 'auto-tag--gptel-json)
                (lambda (&rest _)
                  '(:vocabulary ("emacs" "python" "sqlite")
                    :assignments ((:file "note-a.org" :tags ("emacs"))
                                  (:file "note-b.org" :tags ("python"))
                                  (:file "note-c.org" :tags ("sqlite")))))))
       (auto-tag-consolidate dir))
     (let* ((out (auto-tag-test--data-file dir auto-tag-final-filename))
            (data (auto-tag--read-json out)))
       (should (file-exists-p out))
       ;; ceiling(0.20 * 3) = 1
       (should (equal 1 (plist-get data :target-count)))
       (should (equal '("emacs" "python" "sqlite") (plist-get data :vocabulary)))
       (should (= 3 (length (plist-get data :assignments))))
       (should (equal '("note-a.org" "note-b.org" "note-c.org")
                      (mapcar (lambda (a) (file-name-nondirectory (plist-get a :file)))
                              (plist-get data :assignments))))))))


;;; Phase 3 (apply) using the real org-roam tag API

(ert-deftest auto-tag-add-file-tags-creates-filetags ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((f (expand-file-name "note-b.org" dir)))  ; no #+filetags:
       (auto-tag--add-file-tags f '("python"))
       (with-temp-buffer
         (insert-file-contents f)
         (should (string-match-p "^#\\+filetags: :python:" (buffer-string))))))))

(ert-deftest auto-tag-add-file-tags-merges ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((f (expand-file-name "note-a.org" dir)))  ; has :gpt:
       (auto-tag--add-file-tags f '("emacs"))
       (with-temp-buffer
         (insert-file-contents f)
         (should (string-match-p "^#\\+filetags: :emacs:gpt:" (buffer-string))))))))

(ert-deftest auto-tag-apply-with-fake-final ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (auto-tag--write-json
      (auto-tag-test--data-file dir auto-tag-final-filename)
      (list :directory dir :target-count 1 :vocabulary '("emacs")
            :assignments (list (list :file (expand-file-name "note-a.org" dir)
                                     :tags '("emacs"))
                               (list :file (expand-file-name "note-b.org" dir)
                                     :tags '("python")))))
     (auto-tag-apply dir nil t)                  ; include already-tagged
     (with-temp-buffer
       (insert-file-contents (expand-file-name "note-a.org" dir))
       (should (string-match-p ":emacs:gpt:" (buffer-string))))
     (with-temp-buffer
       (insert-file-contents (expand-file-name "note-b.org" dir))
       (should (string-match-p ":python:" (buffer-string)))))))

(ert-deftest auto-tag-apply-dry-run-does-not-modify ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((before (auto-tag-test--file-string (expand-file-name "note-b.org" dir))))
       (auto-tag--write-json
        (auto-tag-test--data-file dir auto-tag-final-filename)
        (list :directory dir :target-count 1 :vocabulary '("emacs")
              :assignments (list (list :file (expand-file-name "note-b.org" dir)
                                       :tags '("python")))))
       (auto-tag-apply dir t)                     ; dry-run (note-b is untagged)
       (should (equal before
                      (auto-tag-test--file-string (expand-file-name "note-b.org" dir))))))))


;;; List-of-files and only-untagged variants

(ert-deftest auto-tag-file-has-tags-p ()
  (should (auto-tag--file-has-tags-p
           (expand-file-name "note-a.org" (auto-tag-test-fixture-dir))))
  (should-not (auto-tag--file-has-tags-p
               (expand-file-name "note-b.org" (auto-tag-test-fixture-dir)))))

(ert-deftest auto-tag-files-directory ()
  (should (equal "/a/" (auto-tag--files-directory '("/a/one.org" "/a/two.org"))))
  (should-error (auto-tag--files-directory '("/a/one.org" "/b/two.org")))
  (should-error (auto-tag--files-directory '())))

(ert-deftest auto-tag-suggest-files-writes-only-given-files ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((files (list (expand-file-name "note-a.org" dir)
                        (expand-file-name "note-b.org" dir))))
       (cl-letf (((symbol-function 'auto-tag--gptel-json)
                  (auto-tag-test--fake-gptel '(:tags ("emacs")))))
         (auto-tag-suggest-files files t))       ; include already-tagged
       (let ((data (auto-tag--read-json
                    (auto-tag-test--data-file dir auto-tag-suggestions-filename))))
         (should (equal 2 (plist-get data :file-count)))
         (should (equal '("note-a.org" "note-b.org")
                        (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file)))
                                (plist-get data :files)))))))))

(ert-deftest auto-tag-suggest-files-default-only-untagged ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((files (list (expand-file-name "note-a.org" dir)
                        (expand-file-name "note-b.org" dir))))
       (cl-letf (((symbol-function 'auto-tag--gptel-json)
                  (auto-tag-test--fake-gptel '(:tags ("emacs")))))
         (auto-tag-suggest-files files))         ; default: untagged only
       (let ((data (auto-tag--read-json
                    (auto-tag-test--data-file dir auto-tag-suggestions-filename))))
         (should (equal 1 (plist-get data :file-count)))
         (should (equal '("note-b.org")
                        (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file)))
                                (plist-get data :files)))))))))

(ert-deftest auto-tag-apply-files-only-applies-to-given-files ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((note-c-before (auto-tag-test--file-string (expand-file-name "note-c.org" dir))))
       (auto-tag--write-json
        (auto-tag-test--data-file dir auto-tag-final-filename)
        (list :directory dir :target-count 1 :vocabulary '("emacs")
              :assignments (list (list :file (expand-file-name "note-a.org" dir)
                                       :tags '("emacs"))
                                 (list :file (expand-file-name "note-b.org" dir)
                                       :tags '("python"))
                                 (list :file (expand-file-name "note-c.org" dir)
                                       :tags '("sqlite")))))
       (auto-tag-apply-files (list (expand-file-name "note-a.org" dir)
                                   (expand-file-name "note-b.org" dir))
                             nil t)              ; include already-tagged
       (with-temp-buffer
         (insert-file-contents (expand-file-name "note-a.org" dir))
         (should (string-match-p ":emacs:gpt:" (buffer-string))))
       (with-temp-buffer
         (insert-file-contents (expand-file-name "note-b.org" dir))
         (should (string-match-p ":python:" (buffer-string))))
       ;; note-c was not in the list, so it must be untouched.
       (should (equal note-c-before
                      (auto-tag-test--file-string (expand-file-name "note-c.org" dir))))))))

(ert-deftest auto-tag-apply-only-untagged ()
  (auto-tag-test--with-temp
   (lambda (dir)
     (let ((note-a-before (auto-tag-test--file-string (expand-file-name "note-a.org" dir))))
       (auto-tag--write-json
        (auto-tag-test--data-file dir auto-tag-final-filename)
        (list :directory dir :target-count 1 :vocabulary '("emacs")
              :assignments (list (list :file (expand-file-name "note-a.org" dir)
                                       :tags '("emacs"))
                                 (list :file (expand-file-name "note-b.org" dir)
                                       :tags '("python")))))
       (auto-tag-apply dir)                       ; default: untagged only
       ;; note-a already has :gpt:, so it must be untouched.
       (should (equal note-a-before
                      (auto-tag-test--file-string (expand-file-name "note-a.org" dir))))
       ;; note-b had no tags, so it gets tagged.
       (with-temp-buffer
         (insert-file-contents (expand-file-name "note-b.org" dir))
         (should (string-match-p ":python:" (buffer-string))))))))

(ert-deftest auto-tag-data-file-lives-in-temp-directory ()
  (let ((f (auto-tag--data-file "/some/dir" auto-tag-suggestions-filename)))
    (should (equal (file-name-as-directory auto-tag-data-directory)
                   (file-name-directory f)))
    (should (string-match-p "auto-tag-suggestions\\.json\\'" f))))

(ert-deftest auto-tag-project-directory-falls-back-to-default ()
  (let ((default-directory temporary-file-directory)
        (project-find-functions nil))
    (should (equal (expand-file-name default-directory)
                   (auto-tag--project-directory)))))

(provide 'auto-tag-test)
;;; auto-tag-test.el ends here
