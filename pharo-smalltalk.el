;;; pharo-smalltalk.el --- Live Pharo Smalltalk bridge and tools  -*- lexical-binding: t; -*-

;; Author: Jianjiang Pan <panjianjiang@hotmail.com>
;; Maintainer: Jianjiang Pan <panjianjiang@hotmail.com>
;; URL: https://github.com/panjianjiang/pharo-smalltalk
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, tools, smalltalk
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; `pharo-smalltalk' is an Emacs bridge to a running Pharo image served
;; by `PharoSmalltalkInteropServer' / `SisServer' (HTTP, default port
;; 8086). It provides a Smalltalk major mode, evaluation commands, an
;; xref backend, completion and eldoc, a tabulated-list system browser,
;; a test runner, and Org Babel integration.
;;
;; Entry point:
;;
;;     (require 'pharo-smalltalk)
;;     (pharo-smalltalk-install)
;;
;; This loads the optional submodules listed in
;; `pharo-smalltalk-package-modules' (xref, capf, test, browser by
;; default), registers `pharo-smalltalk-mode' for `.st' / `.smalltalk'
;; / `.tonel' files, and binds `pharo-smalltalk-command-map' to
;; `pharo-smalltalk-global-command-key' (`C-c s' by default).
;;
;; The Pharo side requires the bridge extras shipped under `pharo/' in
;; this repo — load them via Metacello.  See README.md for details.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'pp)
(require 'subr-x)
(require 'url)
(require 'url-http)

;; `url-http' sets these dynamically inside the `url-retrieve' callback;
;; declare them so the byte-compiler stops complaining about free refs.
(defvar url-http-response-status)
(defvar url-http-end-of-headers)
;; Org Babel hooks below are wrapped in `with-eval-after-load'; declare
;; the variables they touch so we don't pull `org' in unconditionally.
(defvar org-babel-tangle-lang-exts)
(defvar org-src-lang-modes)

(defgroup pharo-smalltalk nil
  "Bridge and lightweight workbench for PharoSmalltalkInteropServer."
  :group 'tools)

(defcustom pharo-smalltalk-server-url "http://127.0.0.1:8086"
  "Base URL of the PharoSmalltalkInteropServer."
  :type 'string
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-timeout 10
  "Timeout in seconds for synchronous requests to Pharo."
  :type 'integer
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-result-buffer-name "*Pharo Eval*"
  "Buffer name used to display the latest evaluation result."
  :type 'string
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-workspace-buffer-name "*Pharo Workspace*"
  "Default workspace buffer name."
  :type 'string
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-default-method-category "as yet unclassified"
  "Default protocol/category used when compiling a method."
  :type 'string
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-prompt-for-missing-method-metadata t
  "Whether to prompt when method compilation metadata is missing."
  :type 'boolean
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-package-modules '(xref capf test browser)
  "Optional support modules loaded by `pharo-smalltalk-install'."
  :type '(set (const :tag "xref backend" xref)
              (const :tag "completion and eldoc" capf)
              (const :tag "test runner" test)
              (const :tag "browser" browser))
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-global-command-key "C-c s"
  "Global key used to expose `pharo-smalltalk-command-map'.
Set to nil to leave the command map unbound globally."
  :type '(choice (const :tag "Do not bind globally" nil)
                 string)
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-auto-mode-patterns
  '("\\.st\\'" "\\.smalltalk\\'" "\\.tonel\\'")
  "File patterns that should open in `pharo-smalltalk-mode'."
  :type '(repeat string)
  :group 'pharo-smalltalk)

(defvar pharo-smalltalk-last-result nil
  "Last successful result returned by the server.")

(defvar pharo-smalltalk-last-response nil
  "Last parsed JSON response returned by the server.")

(defvar pharo-smalltalk-last-transcript nil
  "Last captured Transcript output from the server, or nil if empty.")

(defvar pharo-smalltalk-last-http-status nil
  "Last HTTP status code returned by the server.")

(defvar pharo-smalltalk-last-raw-body nil
  "Last raw HTTP response body returned by the server.")

(defvar pharo-smalltalk--installed-p nil
  "Non-nil once `pharo-smalltalk-install' has registered package defaults.")

(defconst pharo-smalltalk-version "0.1.0"
  "Current version of the `pharo-smalltalk' package.")

(autoload 'pharo-smalltalk-test-run-class "pharo-smalltalk-test" nil t)
(autoload 'pharo-smalltalk-test-run-package "pharo-smalltalk-test" nil t)
(autoload 'pharo-smalltalk-test-run-smoke "pharo-smalltalk-test" nil t)
(autoload 'pharo-smalltalk-test-rerun "pharo-smalltalk-test" nil t)
(autoload 'pharo-smalltalk-browse "pharo-smalltalk-browser" nil t)
(autoload 'pharo-smalltalk-browse-class-in-browser "pharo-smalltalk-browser" nil t)

(defvar pharo-smalltalk-command-map
  (let ((map (make-sparse-keymap)))
    map)
  "Prefix keymap for Pharo Smalltalk commands.")

(defvar pharo-smalltalk-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `pharo-smalltalk-mode'.")

(defvar-local pharo-smalltalk-buffer-class-name nil
  "Current target class name for this buffer.")

(defvar-local pharo-smalltalk-buffer-class-side-p nil
  "Non-nil when current buffer targets class-side methods.")

(defvar-local pharo-smalltalk-buffer-method-category nil
  "Current target method category/protocol for this buffer.")

(defvar-local pharo-smalltalk-buffer-source-kind 'workspace
  "Semantic source kind of current buffer.
Known values include `workspace', `method', `class-definition', `class-source'.")

(cl-defstruct (pharo-smalltalk-method-spec
               (:constructor pharo-smalltalk-method-spec-create))
  class-name
  selector
  class-side-p
  category)

(defun pharo-smalltalk-method-spec-side-symbol (spec)
  "Return SPEC's side as `class' or `instance'."
  (if (pharo-smalltalk-method-spec-class-side-p spec) 'class 'instance))

(defun pharo-smalltalk-method-spec-display-name (spec)
  "Return a human-readable CLASS>>SELECTOR name for SPEC."
  (format "%s%s>>%s"
          (pharo-smalltalk-method-spec-class-name spec)
          (if (pharo-smalltalk-method-spec-class-side-p spec) " class" "")
          (pharo-smalltalk-method-spec-selector spec)))

(defvar pharo-smalltalk-font-lock-keywords
  '(("\\_<\\(self\\|super\\|true\\|false\\|nil\\|thisContext\\)\\_>" . font-lock-constant-face)
    ("\\_<\\([A-Z][A-Za-z0-9_]*\\)\\_>" . font-lock-type-face)
    ("#[A-Za-z0-9_:]+" . font-lock-builtin-face)
    ("'[^']*'" . font-lock-string-face)
    ("\\_<\\([a-z][A-Za-z0-9_]*:\\)+" . font-lock-function-name-face))
  "Basic font-lock keywords for `pharo-smalltalk-mode'.")

(defvar pharo-smalltalk-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\" "'" table)
    (modify-syntax-entry ?\' "\"" table)
    (modify-syntax-entry ?_ "w" table)
    table)
  "Syntax table for `pharo-smalltalk-mode'.")

;; ---------- Indentation ----------

(defcustom pharo-smalltalk-indent-offset 2
  "Default indent step (in columns) inside `[ ]' blocks and method bodies."
  :type 'integer
  :group 'pharo-smalltalk)

(defun pharo-smalltalk--in-string-or-comment-p (pos)
  "Return non-nil when POS is inside a string or comment.
Heuristic: count unescaped `\"' (comment) and `''' (string) before POS."
  (save-excursion
    (let ((in-comment nil) (in-string nil))
      (goto-char (point-min))
      (while (< (point) pos)
        (cond
         (in-string
          (when (eq (char-after) ?\')
            (if (eq (char-after (1+ (point))) ?\')
                (forward-char 1)  ; doubled quote = literal
              (setq in-string nil)))
          (forward-char 1))
         (in-comment
          (when (eq (char-after) ?\")
            (setq in-comment nil))
          (forward-char 1))
         (t
          (cond
           ((eq (char-after) ?\') (setq in-string t) (forward-char 1))
           ((eq (char-after) ?\") (setq in-comment t) (forward-char 1))
           (t (forward-char 1))))))
      (or in-comment in-string))))

(defun pharo-smalltalk--bracket-context ()
  "Return (OPEN-POS . OPEN-COLUMN) of the innermost unclosed `[' before point.
Returns nil when not inside a bracketed block. Skips strings and comments
heuristically by scanning the buffer."
  (save-excursion
    (let ((target (point))
          (depth 0)
          last-open last-col)
      (goto-char (point-min))
      (let (in-comment in-string)
        (while (< (point) target)
          (let ((c (char-after)))
            (cond
             (in-string
              (when (eq c ?\')
                (if (eq (char-after (1+ (point))) ?\')
                    (forward-char 1)
                  (setq in-string nil))))
             (in-comment
              (when (eq c ?\") (setq in-comment nil)))
             (t
              (cond
               ((eq c ?\') (setq in-string t))
               ((eq c ?\") (setq in-comment t))
               ((eq c ?\[)
                (setq depth (1+ depth)
                      last-open (point)
                      last-col (current-column)))
               ((eq c ?\])
                (setq depth (1- depth))
                (when (zerop depth) (setq last-open nil last-col nil))))))
            (forward-char 1))))
      (when (and last-open (> depth 0))
        (cons last-open last-col)))))

(defun pharo-smalltalk--prev-nonblank-line ()
  "Move to the previous non-blank line; return t on success, nil at BOB."
  (let (found)
    (save-excursion
      (forward-line -1)
      (while (and (not (bobp)) (looking-at-p "^[[:space:]]*$"))
        (forward-line -1))
      (setq found (not (bobp))))
    (when found
      (forward-line -1)
      (while (and (not (bobp)) (looking-at-p "^[[:space:]]*$"))
        (forward-line -1)))
    found))

(defun pharo-smalltalk--current-indentation ()
  "Indentation column of the current line, ignoring blank lines."
  (save-excursion (back-to-indentation) (current-column)))

(defun pharo-smalltalk-calculate-indent ()
  "Return the column the current line should be indented to."
  (save-excursion
    (back-to-indentation)
    (let* ((bracket (pharo-smalltalk--bracket-context))
           (text (buffer-substring-no-properties (point) (line-end-position))))
      (cond
       ;; Closing `]' — align with its matching `[' column.
       ((and (string-prefix-p "]" text) bracket)
        (cdr bracket))
       ;; Inside a `[' block — indent body by one offset past the `['.
       (bracket
        (+ (cdr bracket) pharo-smalltalk-indent-offset))
       ;; Otherwise: continuation indent based on previous line.
       (t
        (let ((prev (when (pharo-smalltalk--prev-nonblank-line)
                      (save-excursion
                        (back-to-indentation)
                        (cons (current-column)
                              (buffer-substring-no-properties
                               (point) (line-end-position)))))))
          (if (null prev) 0
            (let ((prev-col (car prev))
                  (prev-text (cdr prev)))
              ;; If previous line ended with `.' or `^ ... .' (full statement),
              ;; we keep the same indent. If it ended with `[' we'd be inside
              ;; a block (handled above). Otherwise it's a continuation —
              ;; indent one offset past the previous line.
              (cond
               ((string-match-p "[.;][[:space:]]*\\(\"[^\"]*\"\\)?[[:space:]]*$"
                                prev-text)
                prev-col)
               (t (+ prev-col pharo-smalltalk-indent-offset)))))))))))

(defun pharo-smalltalk-indent-line ()
  "Indent the current line according to Smalltalk conventions."
  (interactive)
  (let* ((target (pharo-smalltalk-calculate-indent))
         (savep (> (- (point) (line-beginning-position))
                   (pharo-smalltalk--current-indentation))))
    (if savep
        (save-excursion (indent-line-to target))
      (indent-line-to target))))

(defun pharo-smalltalk--header-line ()
  "Compose a header-line string describing the buffer's Pharo context."
  (let* ((class pharo-smalltalk-buffer-class-name)
         (side (if pharo-smalltalk-buffer-class-side-p "class" "instance"))
         (category pharo-smalltalk-buffer-method-category)
         (kind (or pharo-smalltalk-buffer-source-kind 'code))
         (parts (delq nil
                      (list (format "Pharo[%s]" kind)
                            (and class (format "class: %s" class))
                            (and class (format "side: %s" side))
                            (and category (format "cat: %s" category))))))
    (mapconcat #'identity parts "  │  ")))

;;;###autoload
(define-derived-mode pharo-smalltalk-mode prog-mode "Pharo-Smalltalk"
  "Major mode for editing Smalltalk code targeting Pharo."
  :syntax-table pharo-smalltalk-mode-syntax-table
  (setq-local comment-start "\"")
  (setq-local comment-end "\"")
  (setq-local font-lock-defaults '(pharo-smalltalk-font-lock-keywords))
  (setq-local indent-tabs-mode nil)
  (setq-local indent-line-function #'pharo-smalltalk-indent-line)
  (setq header-line-format '(:eval (pharo-smalltalk--header-line))))

(defun pharo-smalltalk--base-url ()
  "Return normalized server base URL without a trailing slash."
  (replace-regexp-in-string "/\\'" "" pharo-smalltalk-server-url))

(defun pharo-smalltalk--endpoint (path)
  "Build an absolute URL under the server base for PATH."
  (concat (pharo-smalltalk--base-url)
          "/"
          (replace-regexp-in-string "\\`/" "" path)))

(defun pharo-smalltalk--make-query-string (params)
  "Return a URL query string built from PARAMS alist."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (format "%s" (car pair)))
             "="
             (url-hexify-string (format "%s" (cdr pair)))))
   params
   "&"))

(defun pharo-smalltalk--normalize-newlines (text)
  "Normalize newlines in TEXT to Unix style."
  (replace-regexp-in-string "\r\n?" "\n" (or text "")))

(defun pharo-smalltalk--smalltalk-string (text)
  "Return TEXT encoded as a Smalltalk string literal."
  (format "'%s'" (replace-regexp-in-string "'" "''" (or text "") t t)))

(defun pharo-smalltalk--symbol-literal (name)
  "Return NAME encoded as a Smalltalk symbol literal."
  (format "#%s" name))

(defun pharo-smalltalk--paragraph-bounds ()
  "Return bounds of the current paragraph."
  (save-excursion
    (let (begin end)
      (backward-paragraph)
      (setq begin (point))
      (forward-paragraph)
      (setq end (point))
      (cons begin end))))

(defun pharo-smalltalk--chunk-bounds ()
  "Return bounds of current top-level Smalltalk chunk.
Chunks are separated by blank lines."
  (save-excursion
    (let (begin end)
      (setq begin
            (progn
              (if (re-search-backward "^[[:space:]]*$" nil t)
                  (progn (forward-line 1) (point))
                (point-min))))
      (goto-char begin)
      (setq end
            (if (re-search-forward "^[[:space:]]*$" nil t)
                (match-beginning 0)
              (point-max)))
      (cons begin end))))

(defun pharo-smalltalk--http-body-string (buffer)
  "Return the decoded HTTP response body from BUFFER as a string."
  (with-current-buffer buffer
    (let ((coding-system-for-read 'utf-8))
      (goto-char (or url-http-end-of-headers (point-min)))
      (skip-chars-forward "\r\n\t ")
      (buffer-substring-no-properties (point) (point-max)))))

(defun pharo-smalltalk--parse-json-response (buffer)
  "Parse the JSON response body from BUFFER."
  (with-current-buffer buffer
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol)
          (json-false nil)
          (json-null nil))
      (goto-char (or url-http-end-of-headers (point-min)))
      (skip-chars-forward "\r\n\t ")
      (json-read))))

(defun pharo-smalltalk--format-error (err)
  "Format ERR from the server into a compact message."
  (cond
   ((stringp err) err)
   ((and (listp err) (alist-get 'description err))
    (alist-get 'description err))
   (t (format "%S" err))))

(defcustom pharo-smalltalk-warn-once-interval 10
  "Minimum seconds between repeated `pharo-smalltalk--warn-once' messages
sharing the same key."
  :type 'integer
  :group 'pharo-smalltalk)

(defvar pharo-smalltalk--warn-suppress (make-hash-table :test 'equal)
  "Map of warn-once key -> last emission timestamp.")

(defun pharo-smalltalk--warn-once (key fmt &rest args)
  "Emit a `[pharo-smalltalk]' message for KEY, throttled by interval."
  (let ((now (float-time))
        (last (gethash key pharo-smalltalk--warn-suppress 0)))
    (when (> (- now last) pharo-smalltalk-warn-once-interval)
      (puthash key now pharo-smalltalk--warn-suppress)
      (apply #'message (concat "[pharo-smalltalk] " fmt) args))))

(defun pharo-smalltalk--display-value (label value &optional buffer-name mode)
  "Display LABEL and VALUE in a dedicated buffer.
BUFFER-NAME defaults to `pharo-smalltalk-result-buffer-name'.
MODE defaults to `special-mode'.
When `pharo-smalltalk-last-transcript' is non-nil, prepend it as a
Transcript section."
  (with-current-buffer (get-buffer-create (or buffer-name pharo-smalltalk-result-buffer-name))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (when pharo-smalltalk-last-transcript
        (insert "Transcript\n----------\n"
                pharo-smalltalk-last-transcript
                (if (string-suffix-p "\n" pharo-smalltalk-last-transcript) "" "\n")
                "\n"))
      (insert label "\n\n")
      (pp value (current-buffer))
      (goto-char (point-min))
      (funcall (or mode #'special-mode)))
    (display-buffer (current-buffer))))

(defun pharo-smalltalk--format-transcript-and-result (result)
  "Format RESULT together with the last captured Transcript output.
Returns a string suitable for presentation in Org Babel and minibuffer-like
contexts where a single textual value is preferable."
  (let ((result-text (if (stringp result)
                         result
                       (format "%s" result))))
    (if pharo-smalltalk-last-transcript
        (concat "Transcript\n----------\n"
                pharo-smalltalk-last-transcript
                (if (string-suffix-p "\n" pharo-smalltalk-last-transcript) "" "\n")
                "\nResult\n------\n"
                result-text)
      result-text)))

(defun pharo-smalltalk--signal-http-error (buffer url)
  "Raise a descriptive error for BUFFER returned from URL."
  (with-current-buffer buffer
    (setq pharo-smalltalk-last-http-status url-http-response-status)
    (setq pharo-smalltalk-last-raw-body (pharo-smalltalk--http-body-string buffer))
    (error "Pharo HTTP %s from %s: %s"
           (or url-http-response-status "unknown")
           url
           (string-trim (or pharo-smalltalk-last-raw-body "")))))

(defun pharo-smalltalk--request-json (method url &optional payload)
  "Send METHOD to URL with optional JSON PAYLOAD and return parsed JSON."
  (let* ((url-request-method method)
         (url-request-extra-headers
          '(("Content-Type" . "application/json; charset=utf-8")
            ("Accept" . "application/json")))
         (url-request-data
          (when payload
            (encode-coding-string (json-encode payload) 'utf-8)))
         (buffer (url-retrieve-synchronously url nil nil pharo-smalltalk-timeout)))
    (unless buffer
      (error "Pharo request failed: no response from %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (setq pharo-smalltalk-last-http-status url-http-response-status)
          (setq pharo-smalltalk-last-raw-body (pharo-smalltalk--http-body-string buffer))
          (unless (and url-http-response-status
                       (>= url-http-response-status 200)
                       (< url-http-response-status 300))
            (pharo-smalltalk--signal-http-error buffer url))
          (condition-case err
              (pharo-smalltalk--parse-json-response buffer)
            (error
             (error "Pharo response from %s was not valid JSON: %s\nRaw body: %s"
                    url
                    (error-message-string err)
                    pharo-smalltalk-last-raw-body))))
      (kill-buffer buffer))))

(cl-defun pharo-smalltalk--request (endpoint &key params data (type "GET"))
  "Send a request to ENDPOINT and return parsed JSON.
PARAMS is an alist of query params. DATA is JSON-encoded for non-GET requests."
  (let ((url (pharo-smalltalk--endpoint endpoint)))
    (when params
      (setq url (concat url "?" (pharo-smalltalk--make-query-string params))))
    (pharo-smalltalk--request-json type url data)))

(defun pharo-smalltalk--request-json-async (method url payload callback)
  "Send METHOD to URL with optional JSON PAYLOAD asynchronously.
CALLBACK is invoked as (CALLBACK RESULT ERROR) when the request finishes."
  (let* ((url-request-method method)
         (url-request-extra-headers
          '(("Content-Type" . "application/json; charset=utf-8")
            ("Accept" . "application/json")))
         (url-request-data
          (when payload
            (encode-coding-string (json-encode payload) 'utf-8))))
    (url-retrieve
     url
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (let ((err (plist-get status :error)))
               (cond
                (err
                 (funcall callback nil
                          (format "Pharo request failed: %S" err)))
                ((and url-http-response-status
                      (or (< url-http-response-status 200)
                          (>= url-http-response-status 300)))
                 (let ((body (pharo-smalltalk--http-body-string buffer)))
                   (setq pharo-smalltalk-last-http-status url-http-response-status)
                   (setq pharo-smalltalk-last-raw-body body)
                   (funcall callback nil
                            (format "Pharo HTTP %s from %s: %s"
                                    url-http-response-status url
                                    (string-trim (or body ""))))))
                (t
                 (setq pharo-smalltalk-last-http-status url-http-response-status)
                 (setq pharo-smalltalk-last-raw-body
                       (pharo-smalltalk--http-body-string buffer))
                 (condition-case parse-err
                     (let ((response (pharo-smalltalk--parse-json-response buffer)))
                       (funcall callback response nil))
                   (error
                    (funcall callback nil
                             (format "Pharo response from %s was not valid JSON: %s"
                                     url (error-message-string parse-err))))))))
           (when (buffer-live-p buffer) (kill-buffer buffer)))))
     nil t t)))

(cl-defun pharo-smalltalk--request-async (endpoint callback &key params data (type "GET"))
  "Async counterpart to `pharo-smalltalk--request'.
Invokes CALLBACK as (CALLBACK RESULT ERROR) where RESULT is the parsed
response alist on success and ERROR is a string on failure."
  (let ((url (pharo-smalltalk--endpoint endpoint)))
    (when params
      (setq url (concat url "?" (pharo-smalltalk--make-query-string params))))
    (pharo-smalltalk--request-json-async type url data callback)))

(defun pharo-smalltalk--extract-transcript (response)
  "Store RESPONSE's transcript text (if non-empty) into the last-transcript var.
Line endings are normalized from Pharo's CR to LF for Emacs display."
  (let* ((raw (alist-get 'transcript response))
         (tr (and (stringp raw) (> (length raw) 0)
                  (pharo-smalltalk--normalize-newlines raw))))
    (setq pharo-smalltalk-last-transcript tr)))

(defun pharo-smalltalk--unwrap-async (callback)
  "Return a callback that unwraps the Pharo result envelope.
The wrapped CALLBACK is invoked as (RESULT ERROR)."
  (lambda (response error)
    (cond
     (error (funcall callback nil error))
     ((pharo-smalltalk--success-p response)
      (let ((result (alist-get 'result response)))
        (setq pharo-smalltalk-last-response response
              pharo-smalltalk-last-result result)
        (pharo-smalltalk--extract-transcript response)
        (funcall callback result nil)))
     (t
      (setq pharo-smalltalk-last-response response)
      (pharo-smalltalk--extract-transcript response)
      (funcall callback nil
               (pharo-smalltalk--format-error
                (or (alist-get 'error response)
                    (alist-get 'message response)
                    response)))))))

(defun pharo-smalltalk--success-p (response)
  "Return non-nil iff RESPONSE indicates a successful Pharo call.
JSON `false' is parsed as `:json-false' by `json-read', which would
otherwise pass a naive truthiness check."
  (let ((s (alist-get 'success response)))
    (and s (not (eq s :json-false)) (not (eq s :false)))))

(defun pharo-smalltalk--result (response)
  "Return RESPONSE result or raise a user-facing error."
  (setq pharo-smalltalk-last-response response)
  (pharo-smalltalk--extract-transcript response)
  (if (pharo-smalltalk--success-p response)
      (let ((result (alist-get 'result response)))
        (setq pharo-smalltalk-last-result result)
        result)
    (let ((error-value (or (alist-get 'error response)
                           (alist-get 'message response)
                           response)))
      (error "Pharo error: %s" (pharo-smalltalk--format-error error-value)))))

(defun pharo-smalltalk--action-buffer-name (action-name)
  "Return a per-action result buffer name so concurrent searches don't clash."
  (format "*Pharo %s*" action-name))

(defun pharo-smalltalk--store-and-display (response label action-name)
  "Store RESPONSE, display LABEL on success, and signal ACTION-NAME on failure.
The result is shown in a buffer whose name is derived from ACTION-NAME so
concurrent searches don't clobber each other."
  (setq pharo-smalltalk-last-response response)
  (pharo-smalltalk--extract-transcript response)
  (let ((buffer (pharo-smalltalk--action-buffer-name action-name)))
    (if (pharo-smalltalk--success-p response)
        (let ((result (alist-get 'result response)))
          (setq pharo-smalltalk-last-result result)
          (pharo-smalltalk--display-value label result buffer)
          result)
      (let ((error-value (or (alist-get 'error response)
                             (alist-get 'message response)
                             response)))
        (pharo-smalltalk--display-value "Error" error-value buffer)
        (error "Pharo %s failed: %s" action-name (pharo-smalltalk--format-error error-value))))))

(defun pharo-smalltalk-eval (code)
  "Evaluate CODE through the Pharo server and return the result."
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/eval"
                             :type "POST"
                             :data `((code . ,code)))))

(defun pharo-smalltalk-eval-and-display (code)
  "Evaluate CODE and display the result buffer."
  (interactive "sSmalltalk code: ")
  (let ((result (pharo-smalltalk-eval code)))
    (pharo-smalltalk--display-value "Result" result)
    result))

(defun pharo-smalltalk-eval-string-debug (code)
  "Evaluate CODE and echo the raw decoded response for debugging."
  (interactive "sSmalltalk code: ")
  (let ((response (pharo-smalltalk--request "/eval"
                                            :type "POST"
                                            :data `((code . ,code)))))
    (setq pharo-smalltalk-last-response response)
    (message "Pharo response: %S" response)
    response))

(defun pharo-smalltalk-eval-region (begin end)
  "Evaluate the active region from BEGIN to END in Pharo."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "No active region")))
  (let ((result (pharo-smalltalk-eval
                 (buffer-substring-no-properties begin end))))
    (pharo-smalltalk--display-value "Result" result)
    result))

(defun pharo-smalltalk-eval-buffer ()
  "Evaluate the current buffer contents in Pharo."
  (interactive)
  (let ((result (pharo-smalltalk-eval
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (pharo-smalltalk--display-value "Result" result)
    result))

(defun pharo-smalltalk-eval-paragraph-or-region ()
  "Evaluate the active region, or the current paragraph when no region is active."
  (interactive)
  (if (use-region-p)
      (pharo-smalltalk-eval-region (region-beginning) (region-end))
    (let* ((bounds (pharo-smalltalk--paragraph-bounds))
           (begin (car bounds))
           (end (cdr bounds)))
      (let ((result (pharo-smalltalk-eval
                     (buffer-substring-no-properties begin end))))
        (pharo-smalltalk--display-value "Result" result)
        result))))

(defun pharo-smalltalk-eval-region-or-line ()
  "Evaluate the active region, or the current line when no region is active.
When the server captures Transcript output, prepend it to the echoed message."
  (interactive)
  (let* ((code (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (buffer-substring-no-properties (line-beginning-position)
                                                 (line-end-position))))
         (result (pharo-smalltalk-eval code)))
    (if pharo-smalltalk-last-transcript
        (message "%s %s"
                 (string-trim-right pharo-smalltalk-last-transcript)
                 result)
      (message "%s" result))))

(defun pharo-smalltalk-list-packages (&optional force)
  "Return the list of packages in the image, cached for TTL.
With FORCE, bypass the cache."
  (let ((cached pharo-smalltalk--packages-cache))
    (if (and (not force) cached
             (pharo-smalltalk--cache-fresh-p (cdr cached)))
        (car cached)
      (let ((fresh (pharo-smalltalk--result
                    (pharo-smalltalk--request "/list-packages"))))
        (setq pharo-smalltalk--packages-cache (cons fresh (float-time)))
        fresh))))

(defun pharo-smalltalk-list-classes (package-name)
  "Return the classes of PACKAGE-NAME, cached per package."
  (pharo-smalltalk--cache-get
   pharo-smalltalk--classes-cache
   package-name
   (lambda ()
     (pharo-smalltalk--result
      (pharo-smalltalk--request "/list-classes"
                                :params `((package_name . ,package-name)))))))

(defun pharo-smalltalk-import-tonel-package (package-name path)
  "Import PACKAGE-NAME from Tonel PATH into Pharo."
  (interactive
   (list (read-string "Package name: ")
         (read-directory-name "Tonel root: " "/tmp/")))
  (let ((result
         (pharo-smalltalk--result
          (pharo-smalltalk--request "/import-package"
                                    :params `((package_name . ,package-name)
                                              (path . ,path))))))
    (message "%s" result)
    result))

(defun pharo-smalltalk-get-class-source (class-name)
  "Return the full source of CLASS-NAME, cached for TTL."
  (pharo-smalltalk--cached-source-value
   pharo-smalltalk--class-source-cache
   class-name
   (lambda ()
     (pharo-smalltalk--normalize-newlines
      (pharo-smalltalk--result
       (pharo-smalltalk--request "/get-class-source"
                                 :params `((class_name . ,class-name))))))))

(defun pharo-smalltalk-get-method-source (class-name method-name &optional class-side-p)
  "Return source for METHOD-NAME on CLASS-NAME, cached for TTL.
When CLASS-SIDE-P is non-nil, fetch the class-side method."
  (let ((key (list class-name method-name (and class-side-p t))))
    (pharo-smalltalk--cached-source-value
     pharo-smalltalk--method-source-cache
     key
     (lambda ()
       (pharo-smalltalk--normalize-newlines
        (pharo-smalltalk--result
         (pharo-smalltalk--request "/get-method-source"
                                   :params `((class_name . ,class-name)
                                             (method_name . ,method-name)
                                             (is_class_method . ,(if class-side-p "true" "false"))))))))))

(defun pharo-smalltalk-search-implementors (selector)
  "Search Pharo implementors for SELECTOR."
  (interactive "sSelector: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-implementors"
                             :params `((method_name . ,selector)))
   "Implementors"
   "search-implementors"))

(defun pharo-smalltalk-search-references (selector)
  "Search Pharo for senders / references of SELECTOR."
  (interactive "sSelector: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-references"
                             :params `((program_symbol . ,selector)))
   "Senders"
   "search-references"))

(defun pharo-smalltalk-search-references-to-class (class-name)
  "Search Pharo for references to CLASS-NAME."
  (interactive "sClass: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-references-to-class"
                             :params `((class_name . ,class-name)))
   (format "References to %s" class-name)
   "search-references-to-class"))

(defun pharo-smalltalk-search-classes-like (query)
  "Return class names matching QUERY (substring/regex per server)."
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/search-classes-like"
                             :params `((class_name_query . ,query)))))

(defun pharo-smalltalk-search-classes-like-display (query)
  "Interactively show classes matching QUERY."
  (interactive "sClass query: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-classes-like"
                             :params `((class_name_query . ,query)))
   (format "Classes matching %S" query)
   "search-classes-like"))

(defun pharo-smalltalk-search-methods-like (query)
  "Return method selectors matching QUERY."
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/search-methods-like"
                             :params `((method_name_query . ,query)))))

(defun pharo-smalltalk-search-methods-like-display (query)
  "Interactively show methods matching QUERY."
  (interactive "sMethod query: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-methods-like"
                             :params `((method_name_query . ,query)))
   (format "Methods matching %S" query)
   "search-methods-like"))

(defun pharo-smalltalk-search-traits-like (query)
  "Return traits matching QUERY."
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/search-traits-like"
                             :params `((trait_name_query . ,query)))))

(defun pharo-smalltalk-search-traits-like-display (query)
  "Interactively show traits matching QUERY."
  (interactive "sTrait query: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/search-traits-like"
                             :params `((trait_name_query . ,query)))
   (format "Traits matching %S" query)
   "search-traits-like"))

(defun pharo-smalltalk-get-class-comment (class-name)
  "Return the comment of CLASS-NAME, cached for TTL."
  (pharo-smalltalk--cached-source-value
   pharo-smalltalk--class-comment-cache
   class-name
   (lambda ()
     (pharo-smalltalk--normalize-newlines
      (pharo-smalltalk--result
       (pharo-smalltalk--request "/get-class-comment"
                                 :params `((class_name . ,class-name))))))))

(defvar pharo-smalltalk--in-flight-source nil
  "Hash of in-flight async source-fetch keys, to suppress duplicate dispatches.")

(defun pharo-smalltalk--in-flight-table ()
  "Return the in-flight source-fetch hash, lazily creating it."
  (or pharo-smalltalk--in-flight-source
      (setq pharo-smalltalk--in-flight-source
            (make-hash-table :test 'equal))))

(defun pharo-smalltalk-get-method-source-async (class-name method-name class-side-p k)
  "Fetch CLASS-NAME>>METHOD-NAME source asynchronously, caching it.
Calls K with the source string (or nil on failure).  Hits the shared
source cache on success; warns once on error."
  (let* ((key (list class-name method-name (and class-side-p t)))
         (params `((class_name . ,class-name)
                   (method_name . ,method-name)
                   (is_class_method . ,(if class-side-p "true" "false")))))
    (pharo-smalltalk--fetch-cached-source-async
     key
     pharo-smalltalk--method-source-cache
     "/get-method-source"
     params
     k
     (list 'method-source-async class-name class-side-p method-name)
     (format "async get-method-source for %s>>%s failed: %%s"
             class-name method-name))))

(defun pharo-smalltalk-get-class-comment-async (class-name k)
  "Fetch CLASS-NAME comment asynchronously, caching it.
Calls K with the comment string (or nil on failure)."
  (let ((key (list 'comment class-name)))
    (pharo-smalltalk--fetch-cached-source-async
     key
     pharo-smalltalk--class-comment-cache
     "/get-class-comment"
     `((class_name . ,class-name))
     k
     (list 'class-comment-async class-name)
     (format "async get-class-comment for %s failed: %%s" class-name))))

(defun pharo-smalltalk-show-class-comment (class-name)
  "Show comment of CLASS-NAME in a buffer."
  (interactive "sClass: ")
  (pharo-smalltalk--display-value
   (format "Comment: %s" class-name)
   (pharo-smalltalk-get-class-comment class-name)))

(defun pharo-smalltalk-list-extended-classes (package-name)
  "Return classes extended (but not defined) by PACKAGE-NAME, cached per package."
  (pharo-smalltalk--cache-get
   pharo-smalltalk--extended-classes-cache
   package-name
   (lambda ()
     (pharo-smalltalk--result
      (pharo-smalltalk--request "/list-extended-classes"
                                :params `((package_name . ,package-name)))))))

(defun pharo-smalltalk-list-methods (package-name)
  "Return method records for PACKAGE-NAME."
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/list-methods"
                             :params `((package_name . ,package-name)))))

(defun pharo-smalltalk-export-package (package-name path)
  "Export PACKAGE-NAME to Tonel directory PATH."
  (interactive
   (list (read-string "Package name: ")
         (read-directory-name "Export directory: " "/tmp/")))
  (let ((result
         (pharo-smalltalk--result
          (pharo-smalltalk--request "/export-package"
                                    :params `((package_name . ,package-name)
                                              (path . ,path))))))
    (message "Exported %s -> %s" package-name path)
    result))

(defun pharo-smalltalk-run-package-test (package-name)
  "Run all tests in PACKAGE-NAME."
  (interactive "sPackage: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/run-package-test"
                             :params `((package_name . ,package-name)))
   (format "Tests for package %s" package-name)
   "run-package-test"))

(defun pharo-smalltalk-run-class-test (class-name)
  "Run all tests in CLASS-NAME."
  (interactive "sTest class: ")
  (pharo-smalltalk--store-and-display
   (pharo-smalltalk--request "/run-class-test"
                             :params `((class_name . ,class-name)))
   (format "Tests for class %s" class-name)
   "run-class-test"))

(defun pharo-smalltalk-install-project (project-name repository-url &optional load-groups)
  "Install PROJECT-NAME from REPOSITORY-URL using Metacello.
Optional LOAD-GROUPS is a comma-separated list of Metacello load groups."
  (interactive
   (list (read-string "Project name (Metacello baseline): ")
         (read-string "Repository URL (e.g. github://owner/repo:main/src): ")
         (let ((g (read-string "Load groups (comma-separated, optional): ")))
           (and g (not (string-empty-p g)) g))))
  (let ((params `((project_name . ,project-name)
                  (repository_url . ,repository-url))))
    (when load-groups
      (push `(load_groups . ,load-groups) params))
    (pharo-smalltalk--store-and-display
     (pharo-smalltalk--request "/install-project" :params params)
     (format "Install %s" project-name)
     "install-project")))

(defun pharo-smalltalk-get-settings ()
  "Return current Pharo SisServer settings."
  (interactive)
  (let ((settings (pharo-smalltalk--result
                   (pharo-smalltalk--request "/get-settings"))))
    (when (called-interactively-p 'interactive)
      (pharo-smalltalk--display-value "Pharo settings" settings))
    settings))

(defun pharo-smalltalk-apply-settings (settings)
  "Apply SETTINGS (alist) on the Pharo SisServer."
  (interactive
   (list (read-from-minibuffer
          "Settings alist (eg. ((stackSize . 200))): "
          nil nil t)))
  (let ((result (pharo-smalltalk--result
                 (pharo-smalltalk--request "/apply-settings"
                                           :type "POST"
                                           :data `((settings . ,settings))))))
    (message "Pharo apply-settings: %s" result)
    result))

(defun pharo-smalltalk-insert-class-source (class-name)
  "Insert CLASS-NAME source at point."
  (interactive "sClass name: ")
  (insert (pharo-smalltalk-get-class-source class-name)))

(defun pharo-smalltalk-insert-method-source (class-name method-name &optional class-side-p)
  "Insert METHOD-NAME from CLASS-NAME at point.
When CLASS-SIDE-P is non-nil, fetch the class-side method."
  (interactive
   (list (read-string "Class name: ")
         (read-string "Method selector: ")
         (y-or-n-p "Class-side method? ")))
  (insert (pharo-smalltalk-get-method-source class-name method-name class-side-p)))

(defun pharo-smalltalk-show-last-result ()
  "Redisplay the last response received from Pharo."
  (interactive)
  (unless pharo-smalltalk-last-response
    (user-error "No Pharo result has been captured yet"))
  (if (pharo-smalltalk--success-p pharo-smalltalk-last-response)
      (pharo-smalltalk--display-value "Result" pharo-smalltalk-last-result)
    (pharo-smalltalk--display-value
     "Error"
     (or (alist-get 'error pharo-smalltalk-last-response)
         (alist-get 'message pharo-smalltalk-last-response)
         pharo-smalltalk-last-response))))

(defun pharo-smalltalk-show-last-http-response ()
  "Show the last raw HTTP status and body from the Pharo server."
  (interactive)
  (unless (or pharo-smalltalk-last-http-status pharo-smalltalk-last-raw-body)
    (user-error "No HTTP response captured yet"))
  (pharo-smalltalk--display-value
   "Last HTTP Response"
   `((status . ,pharo-smalltalk-last-http-status)
     (body . ,pharo-smalltalk-last-raw-body))))

(defun pharo-smalltalk--class-definition (class-name)
  "Extract the class definition portion for CLASS-NAME."
  (let ((source (pharo-smalltalk-get-class-source class-name)))
    (string-trim
     (car (split-string source "\n\n{ #category :" t)))))

(defun pharo-smalltalk--class-protocols (class-name)
  "Return class and instance protocols for CLASS-NAME, cached per class."
  (pharo-smalltalk--cache-get
   pharo-smalltalk--protocols-cache
   class-name
   (lambda ()
     (pharo-smalltalk-eval
      (format
       (concat "| cls result |"
               " cls := Smalltalk at: #%s."
               " result := Dictionary new."
               " result at: #instance put:"
               " ((cls protocols collect: [ :p |"
               "     { (#category -> p name asString)."
               "       (#methods -> (p methodSelectors collect: [ :s | s asString ]) asArray) }"
               "       asDictionary ]) asArray)."
               " result at: #class put:"
               " ((cls class protocols collect: [ :p |"
               "     { (#category -> p name asString)."
               "       (#methods -> (p methodSelectors collect: [ :s | s asString ]) asArray) }"
               "       asDictionary ]) asArray)."
               " result")
       class-name)))))

(defun pharo-smalltalk-selector-from-source (source)
  "Extract a selector from Smalltalk SOURCE."
  (let* ((first-line (car (split-string source "\n" t)))
         (parts (split-string first-line "[[:space:]]+" t))
         (keywords
          (cl-loop for part in parts
                   when (string-match-p ":" part)
                   collect part)))
    (if (= (length parts) 1)
        (car parts)
      (if keywords
          (string-join keywords "")
        (car parts)))))

(defun pharo-smalltalk--class-def-field (field source)
  "Extract FIELD from class definition SOURCE."
  (when (string-match
         (format "#%s[[:space:]]*:[[:space:]]*'\\([^']*\\)'" field)
         source)
    (match-string 1 source)))

(defun pharo-smalltalk--class-def-array (field source)
  "Extract FIELD array entries from class definition SOURCE."
  (when (string-match
         (format "#%s[[:space:]]*:[[:space:]]*\\(\\[[^]]*\\]\\)" field)
         source)
    (let ((raw (match-string 1 source))
          values)
      (with-temp-buffer
        (insert raw)
        (goto-char (point-min))
        (while (re-search-forward "'\\([^']+\\)'" nil t)
          (push (match-string 1) values)))
      (nreverse values))))

(defun pharo-smalltalk-parse-class-definition (source)
  "Parse SOURCE in `Class { ... }' format into an alist."
  (let ((normalized (pharo-smalltalk--normalize-newlines source)))
    `((name . ,(pharo-smalltalk--class-def-field "name" normalized))
      (superclass . ,(pharo-smalltalk--class-def-field "superclass" normalized))
      (package . ,(pharo-smalltalk--class-def-field "package" normalized))
      (tag . ,(pharo-smalltalk--class-def-field "tag" normalized))
      (instvars . ,(pharo-smalltalk--class-def-array "instVars" normalized))
      (classvars . ,(pharo-smalltalk--class-def-array "classVars" normalized))
      (classinstvars . ,(pharo-smalltalk--class-def-array "classInstVars" normalized)))))

(defun pharo-smalltalk--class-builder-script (definition)
  "Return a ShiftClassBuilder install script for DEFINITION."
  (let* ((name (alist-get 'name definition))
         (superclass (alist-get 'superclass definition))
         (package (alist-get 'package definition))
         (tag (alist-get 'tag definition))
         (instvars (alist-get 'instvars definition))
         (classvars (alist-get 'classvars definition))
         (classinstvars (alist-get 'classinstvars definition))
         (forms
          (delq nil
                (list
                 (format "existing := Smalltalk at: %s ifAbsent: [ nil ]."
                         (pharo-smalltalk--symbol-literal name))
                 "builder := ShiftClassBuilder new."
                 (format "existing ifNil: [ builder name: %s ] ifNotNil: [ builder fillFor: existing ]."
                         (pharo-smalltalk--symbol-literal name))
                 (when superclass
                   (format "builder superclass: (Smalltalk at: %s ifAbsent: [ nil ])."
                           (pharo-smalltalk--symbol-literal superclass)))
                 (format "builder slotsFromString: %s."
                         (pharo-smalltalk--smalltalk-string
                          (string-join instvars " ")))
                 (format "builder sharedVariables: (%s asClassVariableCollection)."
                         (pharo-smalltalk--smalltalk-string
                          (string-join classvars " ")))
                 (format "builder classSlots: (%s asSlotCollection)."
                         (pharo-smalltalk--smalltalk-string
                          (string-join classinstvars " ")))
                 (when package
                   (format "builder package: %s."
                           (pharo-smalltalk--smalltalk-string package)))
                 (when tag
                   (format "builder tag: %s."
                           (pharo-smalltalk--smalltalk-string tag)))
                 "cls := builder install."
                 "cls name asString"))))
    (string-join (append '("| existing builder cls |") forms) " ")))

(defun pharo-smalltalk-class-selectors (class-name class-side-p)
  "Return selectors for CLASS-NAME on the requested side."
  (cl-mapcan
   (lambda (protocol)
     (copy-sequence (alist-get 'methods protocol)))
   (alist-get (if class-side-p 'class 'instance)
              (pharo-smalltalk--class-protocols class-name))))

(defun pharo-smalltalk--method-block-type (body params)
  "Infer the Smalltalk block type from BODY and PARAMS."
  (let ((declared-type (cdr (assq :type params))))
    (cond
     (declared-type (intern declared-type))
     ((and (cdr (assq :class params)) (cdr (assq :category params))) 'method)
     ((string-match-p "\\`[[:space:]\n]*Class[[:space:]]*{" body) 'class-definition)
     (t 'code))))

(defun pharo-smalltalk-compile-method (class-name side category source)
  "Compile SOURCE on CLASS-NAME, SIDE and CATEGORY."
  (let ((result
         (pharo-smalltalk-eval
          (format
           (concat "| cls selector |"
                   " cls := Smalltalk at: #%s."
                   " %s"
                   " selector := cls compile: %s classified: %s."
                   " selector asString")
           class-name
           (if (string= side "class") "cls := cls class." "")
           (pharo-smalltalk--smalltalk-string source)
           (pharo-smalltalk--smalltalk-string category)))))
    (message "Compiled %s%s>>%s"
             class-name
             (if (string= side "class") " class" "")
             result)
    (run-hooks 'pharo-smalltalk-after-mutation-hook)
    result))

(defun pharo-smalltalk-compile-class-definition (source)
  "Compile a `Class { ... }' definition SOURCE via ShiftClassBuilder."
  (let* ((definition (pharo-smalltalk-parse-class-definition source))
         (name (alist-get 'name definition)))
    (unless name
      (user-error "Could not parse class name from class definition"))
    (pharo-smalltalk-eval (pharo-smalltalk--class-builder-script definition))
    (message "Installed class %s" name)
    (run-hooks 'pharo-smalltalk-after-mutation-hook)
    name))

(defvar pharo-smalltalk--all-classes-cache nil
  "Cached vector of (NAMES . TIMESTAMP) for completion.")

(defcustom pharo-smalltalk-class-cache-ttl 30
  "Seconds to keep `pharo-smalltalk--all-classes-cache' before refreshing."
  :type 'integer
  :group 'pharo-smalltalk)

(defun pharo-smalltalk-all-class-names (&optional force)
  "Return a sorted list of all class+trait names in the live image.
With FORCE, bypass the in-process cache."
  (let* ((now (float-time))
         (cached pharo-smalltalk--all-classes-cache)
         (names (car cached))
         (ts (cdr cached)))
    (if (and (not force) names ts
             (< (- now ts) pharo-smalltalk-class-cache-ttl))
        names
      (let ((fresh
             (sort (copy-sequence
                    (pharo-smalltalk-eval
                     "(Smalltalk globals allClassesAndTraits collect: [ :c | c name asString ]) asSortedCollection asArray"))
                   #'string<)))
        (setq pharo-smalltalk--all-classes-cache (cons fresh now))
        fresh))))

(defun pharo-smalltalk-refresh-class-cache ()
  "Force refresh of the cached class/trait names."
  (interactive)
  (pharo-smalltalk-all-class-names t)
  (message "Pharo class cache refreshed (%d entries)"
           (length (car pharo-smalltalk--all-classes-cache))))

(defvar pharo-smalltalk-after-mutation-hook nil
  "Hook run after a local Pharo image-mutating operation.
Functions are called with no arguments; downstream caches should listen
here and invalidate themselves.")

(defun pharo-smalltalk--invalidate-class-cache ()
  "Drop the class/trait completion cache."
  (setq pharo-smalltalk--all-classes-cache nil))

(add-hook 'pharo-smalltalk-after-mutation-hook
          #'pharo-smalltalk--invalidate-class-cache)

(defcustom pharo-smalltalk-browser-cache-ttl 30
  "Seconds to cache browser metadata (packages/classes/protocols)."
  :type 'integer
  :group 'pharo-smalltalk)

(defvar pharo-smalltalk--packages-cache nil
  "Cons cell (PACKAGES . TIMESTAMP) for cached package list, or nil.")

(defvar pharo-smalltalk--classes-cache (make-hash-table :test 'equal)
  "Hash: package-name -> (CLASSES . TIMESTAMP).")

(defvar pharo-smalltalk--extended-classes-cache (make-hash-table :test 'equal)
  "Hash: package-name -> (EXTENDED-CLASSES . TIMESTAMP).")

(defvar pharo-smalltalk--protocols-cache (make-hash-table :test 'equal)
  "Hash: class-name -> (PROTOCOLS . TIMESTAMP).")

(defvar pharo-smalltalk--class-source-cache (make-hash-table :test 'equal)
  "Hash: class-name -> (SOURCE . TIMESTAMP).")

(defvar pharo-smalltalk--method-source-cache (make-hash-table :test 'equal)
  "Hash: (CLASS-NAME METHOD-NAME CLASS-SIDE-P) -> (SOURCE . TIMESTAMP).")

(defvar pharo-smalltalk--class-comment-cache (make-hash-table :test 'equal)
  "Hash: class-name -> (COMMENT . TIMESTAMP).")

(defun pharo-smalltalk--cache-fresh-p (timestamp)
  "Non-nil when TIMESTAMP is within `pharo-smalltalk-browser-cache-ttl'."
  (and (numberp timestamp)
       (< (- (float-time) timestamp)
          pharo-smalltalk-browser-cache-ttl)))

(defun pharo-smalltalk--cache-get (table key compute)
  "Return cached value for KEY in TABLE; otherwise call COMPUTE and store it."
  (let ((entry (gethash key table)))
    (if (and entry (pharo-smalltalk--cache-fresh-p (cdr entry)))
        (car entry)
      (let ((fresh (funcall compute)))
        (puthash key (cons fresh (float-time)) table)
        fresh))))

(defun pharo-smalltalk--invalidate-browser-caches ()
  "Drop browser caches; called on Pharo-side mutations and manual refresh."
  (setq pharo-smalltalk--packages-cache nil)
  (clrhash pharo-smalltalk--classes-cache)
  (clrhash pharo-smalltalk--extended-classes-cache)
  (clrhash pharo-smalltalk--protocols-cache)
  (clrhash pharo-smalltalk--class-source-cache)
  (clrhash pharo-smalltalk--method-source-cache)
  (clrhash pharo-smalltalk--class-comment-cache))

(defun pharo-smalltalk--source-cache-lookup (table key)
  "Return fresh cached value for KEY in TABLE, or nil when missing/stale."
  (let ((entry (gethash key table)))
    (when (and entry (pharo-smalltalk--cache-fresh-p (cdr entry)))
      (car entry))))

(defun pharo-smalltalk--source-cache-store (table key value)
  "Store VALUE under KEY in TABLE with the current timestamp."
  (puthash key (cons value (float-time)) table)
  value)

(defun pharo-smalltalk--cached-source-value (table key fetcher)
  "Return cached value from TABLE for KEY, or compute it with FETCHER.
FETCHER is only run on cache miss or expiry."
  (or (pharo-smalltalk--source-cache-lookup table key)
      (pharo-smalltalk--source-cache-store table key (funcall fetcher))))

(defun pharo-smalltalk--fetch-cached-source-async (key table endpoint params k warn-key warn-format)
  "Fetch a cached source-like value asynchronously and deliver it to K.
KEY and TABLE select the shared cache entry.  ENDPOINT and PARAMS are
forwarded to `pharo-smalltalk--request-async'.  WARN-KEY and WARN-FORMAT
control the warning emitted on async failure."
  (let* ((in-flight (pharo-smalltalk--in-flight-table))
         (cached (pharo-smalltalk--source-cache-lookup table key)))
    (cond
     (cached (funcall k cached))
     ((gethash key in-flight)
      (push k (gethash key in-flight)))
     (t
      (puthash key (list k) in-flight)
      (pharo-smalltalk--request-async
       endpoint
       (pharo-smalltalk--unwrap-async
        (lambda (result error)
          (let ((waiters (gethash key in-flight))
                (value (and (not error) result
                            (pharo-smalltalk--normalize-newlines result))))
            (remhash key in-flight)
            (when value
              (pharo-smalltalk--source-cache-store table key value))
            (when error
              (pharo-smalltalk--warn-once warn-key warn-format error))
            (dolist (waiter (nreverse waiters))
              (funcall waiter value)))))
       :params params)))))

(add-hook 'pharo-smalltalk-after-mutation-hook
          #'pharo-smalltalk--invalidate-browser-caches)

;; ---------- AST parsing via Pharo's RBParser ----------

(defconst pharo-smalltalk--ast-walker
  "| toDict ast |
toDict := nil.
toDict := [ :node |
  node isNil
    ifTrue: [ nil ]
    ifFalse: [
      | d |
      d := Dictionary new.
      d at: 'class' put: node class name asString.
      d at: 'start' put: node start.
      d at: 'stop' put: node stop.
      node isMethod ifTrue: [
        d at: 'selector' put: node selector asString.
        d at: 'arguments' put: (node arguments collect: [ :a | toDict value: a ]) asArray.
        d at: 'body' put: (toDict value: node body) ].
      node isSequence ifTrue: [
        d at: 'temporaries' put: (node temporaries collect: [ :t | toDict value: t ]) asArray.
        d at: 'statements' put: (node statements collect: [ :s | toDict value: s ]) asArray ].
      node isMessage ifTrue: [
        d at: 'selector' put: node selector asString.
        d at: 'receiver' put: (toDict value: node receiver).
        d at: 'arguments' put: (node arguments collect: [ :a | toDict value: a ]) asArray ].
      node isCascade ifTrue: [
        d at: 'receiver' put: (toDict value: node receiver).
        d at: 'messages' put: (node messages collect: [ :m | toDict value: m ]) asArray ].
      node isBlock ifTrue: [
        d at: 'arguments' put: (node arguments collect: [ :a | toDict value: a ]) asArray.
        d at: 'body' put: (toDict value: node body) ].
      node isAssignment ifTrue: [
        d at: 'variable' put: (toDict value: node variable).
        d at: 'value' put: (toDict value: node value) ].
      node isReturn ifTrue: [
        d at: 'value' put: (toDict value: node value) ].
      node isVariable ifTrue: [
        d at: 'name' put: node name asString ].
      node isLiteralNode ifTrue: [
        d at: 'value' put: node value printString ].
      node isArray ifTrue: [
        d at: 'statements' put: (node statements collect: [ :s | toDict value: s ]) asArray ].
      d ] ].
ast := [ RBParser parseMethod: %s ]
  on: Error do: [ :ex |
    [ RBParser parseExpression: %s ]
      on: Error do: [ :ex2 |
        [ RBParser parseFaultyMethod: %s ]
          on: Error do: [ :ex3 | nil ] ] ].
toDict value: ast"
  "Smalltalk script that walks an RBParser AST into a JSON-safe Dictionary.
Three `%s' placeholders receive the same source-as-Smalltalk-string literal.")

(defun pharo-smalltalk-parse-source (source)
  "Parse SOURCE via the live Pharo image and return a nested alist AST.
Returns nil when the parse fails."
  (let* ((literal (pharo-smalltalk--smalltalk-string source))
         (script (format pharo-smalltalk--ast-walker literal literal literal)))
    (condition-case _
        (pharo-smalltalk-eval script)
      (error nil))))

(defvar-local pharo-smalltalk--ast-cache nil
  "Pair (HASH . AST) memoizing the last parse for the current buffer.")

(defun pharo-smalltalk-buffer-ast ()
  "Return the AST for the current buffer, parsing on demand and caching by hash."
  (let ((hash (md5 (buffer-string))))
    (if (and pharo-smalltalk--ast-cache
             (string= (car pharo-smalltalk--ast-cache) hash))
        (cdr pharo-smalltalk--ast-cache)
      (let ((ast (pharo-smalltalk-parse-source (buffer-string))))
        (setq pharo-smalltalk--ast-cache (cons hash ast))
        ast))))

(defun pharo-smalltalk-ast-node-at (point ast)
  "Return the smallest AST subtree containing POINT (1-based) within AST.
Returns nil when AST is nil or POINT is outside the AST range."
  (when ast
    (let ((start (alist-get 'start ast))
          (stop (alist-get 'stop ast)))
      (when (and start stop (<= start point) (<= point (1+ stop)))
        (let ((children-of (lambda (node)
                             (let (acc)
                               (dolist (entry node)
                                 (let ((v (cdr entry)))
                                   (cond
                                    ((and (listp v) (assq 'class v))
                                     (push v acc))
                                    ((and (listp v) (listp (car-safe v))
                                          (assq 'class (car v)))
                                     (setq acc (append v acc))))))
                               acc))))
          (let ((deepest ast))
            (catch 'done
              (while t
                (let ((next (catch 'next
                              (dolist (child (funcall children-of deepest))
                                (let ((cs (alist-get 'start child))
                                      (cp (alist-get 'stop child)))
                                  (when (and cs cp (<= cs point) (<= point (1+ cp)))
                                    (throw 'next child))))
                              nil)))
                  (if next (setq deepest next)
                    (throw 'done deepest)))))
            deepest))))))

(defun pharo-smalltalk--read-class-name (&optional prompt initial)
  "Read a class name with PROMPT and INITIAL value, completing on the live image.
Falls back to plain `read-string' when the server is unreachable."
  (let* ((prompt (or prompt "Class: "))
         (candidates
          (condition-case nil
              (pharo-smalltalk-all-class-names)
            (error nil))))
    (if candidates
        (completing-read prompt candidates nil 'confirm initial 'pharo-smalltalk--class-history)
      (read-string prompt initial))))

(defvar pharo-smalltalk--class-history nil)
(defvar pharo-smalltalk--selector-history nil)

(defun pharo-smalltalk--read-selector (&optional prompt class-name class-side-p)
  "Read a selector with PROMPT.
Completes against CLASS-NAME's selectors when known.
When CLASS-NAME is nil, fall back to a simple `read-string'."
  (let ((prompt (or prompt "Selector: ")))
    (if (and class-name (not (string-empty-p class-name)))
        (let ((selectors
               (condition-case nil
                   (pharo-smalltalk-class-selectors class-name class-side-p)
                 (error nil))))
          (if selectors
              (completing-read prompt selectors nil 'confirm nil 'pharo-smalltalk--selector-history)
            (read-string prompt nil 'pharo-smalltalk--selector-history)))
      (read-string prompt nil 'pharo-smalltalk--selector-history))))

(defun pharo-smalltalk--read-method-category (&optional prompt initial)
  "Read method category with PROMPT and INITIAL value."
  (read-string (or prompt "Category: ")
               (or initial pharo-smalltalk-default-method-category)))

(defun pharo-smalltalk--maybe-read-method-metadata ()
  "Return method metadata plist, prompting when needed.
The result contains :class, :side and :category when available."
  (let* ((class pharo-smalltalk-buffer-class-name)
         (side (if pharo-smalltalk-buffer-class-side-p "class" "instance"))
         (category pharo-smalltalk-buffer-method-category))
    (cond
     ((and class category)
      (list :class class :side side :category category))
     (pharo-smalltalk-prompt-for-missing-method-metadata
      (let ((class* (pharo-smalltalk--read-class-name "Method class: " class))
            (side* (if (y-or-n-p (format "Class-side method for %s? " (or class "method")))
                       "class"
                     "instance"))
            (category* (pharo-smalltalk--read-method-category "Method category: " category)))
        (setq-local pharo-smalltalk-buffer-class-name class*)
        (setq-local pharo-smalltalk-buffer-class-side-p (string= side* "class"))
        (setq-local pharo-smalltalk-buffer-method-category category*)
        (list :class class* :side side* :category category*)))
     (t nil))))

(defun pharo-smalltalk--guess-source-kind (source)
  "Guess semantic source kind for SOURCE."
  (cond
   ((string-match-p "\\`[[:space:]\n]*Class[[:space:]]*{" source) 'class-definition)
   ((and pharo-smalltalk-buffer-class-name pharo-smalltalk-buffer-method-category) 'method)
   (t 'code)))

(defun pharo-smalltalk--send-source (source &optional force-kind)
  "Send SOURCE to Pharo according to FORCE-KIND or inferred source kind."
  (let ((kind (or force-kind (pharo-smalltalk--guess-source-kind source))))
    (pcase kind
      ('class-definition
       (pharo-smalltalk-compile-class-definition source))
      ('method
       (let* ((meta (or (pharo-smalltalk--maybe-read-method-metadata)
                        (user-error "Missing method metadata")))
              (class (plist-get meta :class))
              (side (plist-get meta :side))
              (category (plist-get meta :category)))
         (pharo-smalltalk-compile-method class side category source)))
      (_
       (pharo-smalltalk-eval source)))))

(defun pharo-smalltalk-send-region (begin end)
  "Send region from BEGIN to END using context-aware semantics."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "No active region")))
  (let* ((source (pharo-smalltalk--normalize-newlines
                  (buffer-substring-no-properties begin end)))
         (result (pharo-smalltalk--send-source source)))
    (pharo-smalltalk--display-value "Pharo Send" result)
    result))

(defun pharo-smalltalk-send-buffer ()
  "Send the current buffer using context-aware semantics."
  (interactive)
  (let* ((source (pharo-smalltalk--normalize-newlines
                  (buffer-substring-no-properties (point-min) (point-max))))
         (result (pharo-smalltalk--send-source source pharo-smalltalk-buffer-source-kind)))
    (pharo-smalltalk--display-value "Pharo Send" result)
    result))

(defun pharo-smalltalk-send-chunk ()
  "Send the active region, or the current chunk separated by blank lines."
  (interactive)
  (if (use-region-p)
      (pharo-smalltalk-send-region (region-beginning) (region-end))
    (pcase-let ((`(,begin . ,end) (pharo-smalltalk--chunk-bounds)))
      (let* ((source (pharo-smalltalk--normalize-newlines
                      (buffer-substring-no-properties begin end)))
             (result (pharo-smalltalk--send-source source)))
        (pharo-smalltalk--display-value "Pharo Send" result)
        result))))

(defun pharo-smalltalk-send-defun ()
  "Send the current Smalltalk chunk.
This is an alias in spirit to Geiser/SLY style send-defun behavior."
  (interactive)
  (pharo-smalltalk-send-chunk))

(defun pharo-smalltalk-load-file (file)
  "Load FILE by sending its contents to Pharo."
  (interactive "fSmalltalk file: ")
  (with-temp-buffer
    (insert-file-contents file)
    (let* ((source (pharo-smalltalk--normalize-newlines
                    (buffer-substring-no-properties (point-min) (point-max))))
           (result (pharo-smalltalk--send-source source)))
      (pharo-smalltalk--display-value "Pharo Load File" `((file . ,file) (result . ,result)))
      result)))

(defun pharo-smalltalk-ping ()
  "Ping the Pharo server with a trivial evaluation."
  (interactive)
  (let ((result (pharo-smalltalk-eval "42")))
    (message "Pharo ping OK: %s" result)
    result))

(defun pharo-smalltalk--class-name-at-point ()
  "Return a plausible Smalltalk class name at point."
  (let ((sym (thing-at-point 'symbol t)))
    (when (and sym (string-match-p "\\`[A-Z][A-Za-z0-9_]*\\'" sym))
      sym)))

(defun pharo-smalltalk--render-inspect-buffer (class-name)
  "Populate and display an inspection buffer for CLASS-NAME."
  (let* ((class-source (pharo-smalltalk-get-class-source class-name))
         (comment (condition-case nil
                      (pharo-smalltalk-get-class-comment class-name)
                    (error nil)))
         (protocols (pharo-smalltalk--class-protocols class-name))
         (buffer (get-buffer-create "*Pharo Inspect*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Class: %s\n\n" class-name))
        (when (and comment (not (string-empty-p (string-trim comment))))
          (insert "Comment\n-------\n")
          (insert (string-trim comment) "\n\n"))
        (insert "Class definition\n----------------\n")
        (insert (string-trim class-source) "\n\n")
        (insert "Protocols\n---------\n\n")
        (insert "Instance side\n~~~~~~~~~~~~~\n")
        (dolist (protocol (alist-get 'instance protocols))
          (insert (format "[%s]\n" (alist-get 'category protocol)))
          (dolist (selector (alist-get 'methods protocol))
            (insert "  " selector "\n"))
          (insert "\n"))
        (insert "Class side\n~~~~~~~~~~\n")
        (dolist (protocol (alist-get 'class protocols))
          (insert (format "[%s]\n" (alist-get 'category protocol)))
          (dolist (selector (alist-get 'methods protocol))
            (insert "  " selector "\n"))
          (insert "\n"))
        (goto-char (point-min))
        (pharo-smalltalk-mode)
        (setq-local buffer-read-only t)
        (setq-local pharo-smalltalk-buffer-class-name class-name)
        (setq-local pharo-smalltalk-buffer-source-kind 'class-source)))
    (display-buffer buffer)))

(defun pharo-smalltalk-inspect-class (class-name)
  "Inspect CLASS-NAME by displaying its definition and protocols."
  (interactive (list (pharo-smalltalk--read-class-name)))
  (pharo-smalltalk--render-inspect-buffer class-name))

(defun pharo-smalltalk-inspect-class-at-point ()
  "Inspect the class at point, prompting when no class-like symbol is found."
  (interactive)
  (pharo-smalltalk-inspect-class
   (or (pharo-smalltalk--class-name-at-point)
       (pharo-smalltalk--read-class-name))))

(defun pharo-smalltalk-browse-class (class-name)
  "Open a temporary buffer with the full source of CLASS-NAME."
  (interactive (list (pharo-smalltalk--read-class-name)))
  (with-current-buffer (get-buffer-create "*Smalltalk Class*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (pharo-smalltalk-get-class-source class-name))
      (goto-char (point-min))
      (pharo-smalltalk-mode)
      (setq-local pharo-smalltalk-buffer-class-name class-name)
      (setq-local pharo-smalltalk-buffer-source-kind 'class-source)
      (setq-local buffer-read-only nil))
    (display-buffer (current-buffer))))

(defun pharo-smalltalk-show-method-source (class-name method-name class-side-p)
  "Show METHOD-NAME from CLASS-NAME in a temporary buffer."
  (interactive
   (let* ((class-name (pharo-smalltalk--read-class-name))
          (class-side-p (y-or-n-p "Class-side method? "))
          (selector (completing-read "Method selector: "
                                     (pharo-smalltalk-class-selectors class-name class-side-p)
                                     nil nil)))
     (list class-name selector class-side-p)))
  (with-current-buffer (get-buffer-create "*Smalltalk Method*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (pharo-smalltalk-get-method-source class-name method-name class-side-p))
      (goto-char (point-min))
      (pharo-smalltalk-mode)
      (setq-local pharo-smalltalk-buffer-class-name class-name)
      (setq-local pharo-smalltalk-buffer-class-side-p class-side-p)
      (setq-local pharo-smalltalk-buffer-method-category pharo-smalltalk-default-method-category)
      (setq-local pharo-smalltalk-buffer-source-kind 'method)
      (setq-local buffer-read-only nil))
    (display-buffer (current-buffer))))

(defun pharo-smalltalk-workspace (&optional new-buffer)
  "Open or switch to a Pharo workspace buffer.
With prefix argument NEW-BUFFER, create a fresh workspace buffer."
  (interactive "P")
  (let* ((name (if new-buffer
                   (generate-new-buffer-name pharo-smalltalk-workspace-buffer-name)
                 pharo-smalltalk-workspace-buffer-name))
         (buffer (get-buffer-create name)))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'pharo-smalltalk-mode)
      (pharo-smalltalk-mode))
    (setq-local pharo-smalltalk-buffer-source-kind 'workspace)
    (setq-local pharo-smalltalk-buffer-class-name nil)
    (setq-local pharo-smalltalk-buffer-class-side-p nil)
    (setq-local pharo-smalltalk-buffer-method-category nil)
    (unless (> (buffer-size) 0)
      (insert "\"Pharo workspace\"\n\n"))
    buffer))

(with-eval-after-load 'org
  (require 'ob)
  (defun org-babel-execute:smalltalk (body params)
    "Execute a Smalltalk source block with BODY and PARAMS."
    (pcase (pharo-smalltalk--method-block-type body params)
      ('method
       (pharo-smalltalk-compile-method
        (cdr (assq :class params))
        (or (cdr (assq :side params)) "instance")
        (or (cdr (assq :category params)) pharo-smalltalk-default-method-category)
        (pharo-smalltalk--normalize-newlines body)))
      ('class-definition
       (pharo-smalltalk-compile-class-definition body))
      (_
       (let ((result (pharo-smalltalk-eval body)))
         (pharo-smalltalk--format-transcript-and-result result)))))

  (add-to-list 'org-babel-tangle-lang-exts '("smalltalk" . "st"))
  (defvar org-babel-default-header-args:smalltalk '())
  (add-to-list 'org-src-lang-modes '("smalltalk" . pharo-smalltalk)))

(define-key pharo-smalltalk-mode-map (kbd "C-c C-z") #'pharo-smalltalk-send-chunk)
(define-key pharo-smalltalk-mode-map (kbd "C-c C-c") #'pharo-smalltalk-send-defun)
(define-key pharo-smalltalk-mode-map (kbd "C-c C-b") #'pharo-smalltalk-send-buffer)
(define-key pharo-smalltalk-mode-map (kbd "C-c C-k") #'pharo-smalltalk-load-file)
(define-key pharo-smalltalk-mode-map (kbd "C-c C-w") #'pharo-smalltalk-workspace)
(define-key pharo-smalltalk-mode-map (kbd "C-c C-i") #'pharo-smalltalk-inspect-class-at-point)

(define-key pharo-smalltalk-command-map (kbd "e") #'pharo-smalltalk-eval-region-or-line)
(define-key pharo-smalltalk-command-map (kbd "E") #'pharo-smalltalk-eval-region)
(define-key pharo-smalltalk-command-map (kbd "b") #'pharo-smalltalk-eval-buffer)
(define-key pharo-smalltalk-command-map (kbd "p") #'pharo-smalltalk-eval-paragraph-or-region)
(define-key pharo-smalltalk-command-map (kbd "d") #'pharo-smalltalk-eval-string-debug)
(define-key pharo-smalltalk-command-map (kbd "r") #'pharo-smalltalk-show-last-result)
(define-key pharo-smalltalk-command-map (kbd "h") #'pharo-smalltalk-show-last-http-response)
(define-key pharo-smalltalk-command-map (kbd "i") #'pharo-smalltalk-import-tonel-package)
(define-key pharo-smalltalk-command-map (kbd "c") #'pharo-smalltalk-browse-class)
(define-key pharo-smalltalk-command-map (kbd "m") #'pharo-smalltalk-show-method-source)
(define-key pharo-smalltalk-command-map (kbd "s") #'pharo-smalltalk-search-implementors)
(define-key pharo-smalltalk-command-map (kbd "w") #'pharo-smalltalk-workspace)
(define-key pharo-smalltalk-command-map (kbd "P") #'pharo-smalltalk-ping)
(define-key pharo-smalltalk-command-map (kbd "I") #'pharo-smalltalk-inspect-class-at-point)
(define-key pharo-smalltalk-command-map (kbd "k") #'pharo-smalltalk-send-chunk)
(define-key pharo-smalltalk-command-map (kbd "f") #'pharo-smalltalk-send-buffer)
(define-key pharo-smalltalk-command-map (kbd "S") #'pharo-smalltalk-search-references)
(define-key pharo-smalltalk-command-map (kbd "R") #'pharo-smalltalk-search-references-to-class)
(define-key pharo-smalltalk-command-map (kbd "C") #'pharo-smalltalk-search-classes-like-display)
(define-key pharo-smalltalk-command-map (kbd "M") #'pharo-smalltalk-search-methods-like-display)
(define-key pharo-smalltalk-command-map (kbd "T") #'pharo-smalltalk-search-traits-like-display)
(define-key pharo-smalltalk-command-map (kbd "D") #'pharo-smalltalk-show-class-comment)
(define-key pharo-smalltalk-command-map (kbd "x") #'pharo-smalltalk-export-package)
(defvar pharo-smalltalk-test-map
  (make-sparse-keymap)
  "Prefix keymap for Pharo Smalltalk test commands.")
(define-key pharo-smalltalk-test-map (kbd "c") #'pharo-smalltalk-test-run-class)
(define-key pharo-smalltalk-test-map (kbd "p") #'pharo-smalltalk-test-run-package)
(define-key pharo-smalltalk-test-map (kbd "s") #'pharo-smalltalk-test-run-smoke)
(define-key pharo-smalltalk-test-map (kbd "r") #'pharo-smalltalk-test-rerun)
(define-key pharo-smalltalk-command-map (kbd "t") pharo-smalltalk-test-map)
(define-key pharo-smalltalk-command-map (kbd "B") #'pharo-smalltalk-browse)
(define-key pharo-smalltalk-command-map (kbd "F") #'pharo-smalltalk-browse-class-in-browser)

(defun pharo-smalltalk--load-package-modules ()
  "Load optional package modules configured in `pharo-smalltalk-package-modules'."
  (dolist (feature pharo-smalltalk-package-modules)
    (pcase feature
      ('xref (require 'pharo-smalltalk-xref))
      ('capf (require 'pharo-smalltalk-capf))
      ('test (require 'pharo-smalltalk-test))
      ('browser (require 'pharo-smalltalk-browser)))))

(defun pharo-smalltalk--register-auto-modes ()
  "Register `pharo-smalltalk-mode' for `pharo-smalltalk-auto-mode-patterns'."
  (dolist (pattern pharo-smalltalk-auto-mode-patterns)
    (add-to-list 'auto-mode-alist (cons pattern #'pharo-smalltalk-mode))))

(defun pharo-smalltalk--install-global-key ()
  "Install the global command prefix key, when configured."
  (when pharo-smalltalk-global-command-key
    (global-set-key (kbd pharo-smalltalk-global-command-key)
                    pharo-smalltalk-command-map)))

;;;###autoload
(defun pharo-smalltalk-install ()
  "Install the Pharo Smalltalk package defaults into the current Emacs session.
Loads optional support modules, registers file associations, and binds the
global command prefix when configured."
  (interactive)
  (unless pharo-smalltalk--installed-p
    (pharo-smalltalk--load-package-modules)
    (pharo-smalltalk--register-auto-modes)
    (pharo-smalltalk--install-global-key)
    (setq pharo-smalltalk--installed-p t)))

(provide 'pharo-smalltalk)
;;; pharo-smalltalk.el ends here
