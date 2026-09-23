;;; smoke-test.el --- Verify gptel + Ollama sync request in batch -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'json)

;; Add straight build directories to load-path.
(let ((build (expand-file-name "~/.config/emacs/.local/straight/build-31.1/")))
  (dolist (d (directory-files build t "\\`[^.]"))
    (when (file-directory-p d)
      (add-to-list 'load-path d))))

(require 'gptel)
(require 'gptel-ollama)

;; Register the Ollama backend if it is not already known.
(unless (assoc "Ollama" gptel--known-backends)
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :models '("qwen2.5:latest")
    :stream t))

(let* ((gptel-backend (gptel-get-backend "Ollama"))
       (gptel-model (car (gptel-backend-models gptel-backend)))
       (result nil)
       (status nil)
       (done nil))
  (princ (format "backend=%s model=%s\n"
                 (gptel-backend-name gptel-backend)
                 (gptel--model-name gptel-model)))
  (gptel-request "Return only JSON of the form {\"ok\": true}."
    :system "You are a JSON-only responder. Return valid JSON and nothing else."
    :schema '(:type "object" :properties (:ok (:type "boolean")) :required ["ok"])
    :stream nil
    :callback (lambda (resp info)
                (setq status (plist-get info :status))
                (when (stringp resp) (setq result resp))
                (setq done t)))
  (let ((wait 0))
    (while (and (not done) (< wait 6000))
      (accept-process-output nil 0.1)
      (setq wait (1+ wait))))
  (princ (format "done=%S status=%S result=%S\n" done status result)))
