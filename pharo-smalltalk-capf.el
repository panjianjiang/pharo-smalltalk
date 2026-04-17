;;; pharo-smalltalk-capf.el --- Completion and eldoc for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; Provides `completion-at-point' and eldoc functions that query the
;; live Pharo image via `PharoSmalltalkInteropServer'.  Uses small TTL
;; caches plus async eldoc fetching to keep typing responsive.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-capf nil
  "Completion and eldoc for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-capf-cache-ttl 15
  "Seconds to cache method/class query results during completion."
  :type 'integer
  :group 'pharo-smalltalk-capf)

(defcustom pharo-smalltalk-capf-method-cache-max-entries 256
  "Maximum number of cached selector-search entries."
  :type 'integer
  :group 'pharo-smalltalk-capf)

(defcustom pharo-smalltalk-capf-min-prefix 2
  "Minimum prefix length before firing a network completion query."
  :type 'integer
  :group 'pharo-smalltalk-capf)

(defvar pharo-smalltalk-capf--method-cache (make-hash-table :test 'equal)
  "Cache for `search-methods-like' results: query -> (HITS . TIMESTAMP).")

(defvar pharo-smalltalk-capf--in-flight-prefetch (make-hash-table :test 'equal)
  "Set of selector queries currently being prefetched asynchronously.")

(defun pharo-smalltalk-capf--invalidate ()
  "Drop completion caches; called on Pharo-side mutations."
  (clrhash pharo-smalltalk-capf--method-cache)
  (clrhash pharo-smalltalk-capf--in-flight-prefetch))

(add-hook 'pharo-smalltalk-after-mutation-hook
          #'pharo-smalltalk-capf--invalidate)

(defun pharo-smalltalk-capf--cache-prune (table max-entries)
  "Prune TABLE down to MAX-ENTRIES by evicting the oldest entries."
  (when (and (integerp max-entries)
             (> max-entries 0)
             (> (hash-table-count table) max-entries))
    (let (entries)
      (maphash (lambda (key value)
                 (push (cons key value) entries))
               table)
      (setq entries
            (sort entries
                  (lambda (a b)
                    (< (cdr (cdr a)) (cdr (cdr b))))))
      (while (> (hash-table-count table) max-entries)
        (let ((victim (pop entries)))
          (when victim
            (remhash (car victim) table)))))))

(defun pharo-smalltalk-capf--cached (table key compute max-entries)
  "Return value for KEY in TABLE, running COMPUTE on miss / expired."
  (let ((entry (gethash key table)))
    (if (and entry (< (- (float-time) (cdr entry))
                      pharo-smalltalk-capf-cache-ttl))
        (car entry)
      (let ((value (funcall compute)))
        (puthash key (cons value (float-time)) table)
        (pharo-smalltalk-capf--cache-prune table max-entries)
        value))))

(defun pharo-smalltalk-capf--methods-like (query)
  "Return selectors matching QUERY from cache, or nil while a prefetch flies.
A nil return on cold cache schedules an async prefetch; the next
completion poll (typically the next keystroke) will hit warm data."
  (let ((entry (gethash query pharo-smalltalk-capf--method-cache)))
    (cond
     ((and entry (< (- (float-time) (cdr entry))
                    pharo-smalltalk-capf-cache-ttl))
      (car entry))
     (t
      (remhash query pharo-smalltalk-capf--method-cache)
      (pharo-smalltalk-capf--prefetch-methods-like query)
      nil))))

(defun pharo-smalltalk-capf--prefetch-methods-like (query)
  "Kick off an async `/search-methods-like' for QUERY, dedup'd by query."
  (unless (gethash query pharo-smalltalk-capf--in-flight-prefetch)
    (puthash query t pharo-smalltalk-capf--in-flight-prefetch)
    (pharo-smalltalk--request-async
     "/search-methods-like"
     (pharo-smalltalk--unwrap-async
      (lambda (result error)
        (remhash query pharo-smalltalk-capf--in-flight-prefetch)
        (cond
         (error
          (remhash query pharo-smalltalk-capf--method-cache)
          (pharo-smalltalk--warn-once
           'capf-methods-like-prefetch
           "prefetch search-methods-like %S failed: %s" query error))
         (t
          (puthash query (cons (or result '()) (float-time))
                   pharo-smalltalk-capf--method-cache)
          (pharo-smalltalk-capf--cache-prune
           pharo-smalltalk-capf--method-cache
           pharo-smalltalk-capf-method-cache-max-entries)))))
     :params `((method_name_query . ,query)))))

(defun pharo-smalltalk-capf--symbol-bounds ()
  "Return (BEG . END) of the Smalltalk symbol/selector at point."
  (let ((beg (save-excursion
               (skip-chars-backward "A-Za-z0-9_:")
               (point)))
        (end (save-excursion
               (skip-chars-forward "A-Za-z0-9_:")
               (point))))
    (when (> end beg) (cons beg end))))

(defun pharo-smalltalk-capf--token-before (pos)
  "Return (TOKEN . START) of the alphanumeric token ending before POS, or nil."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t\n")
    (let ((end (point)))
      (skip-chars-backward "A-Za-z0-9_")
      (let ((start (point)))
        (when (< start end)
          (cons (buffer-substring-no-properties start end) start))))))

(defun pharo-smalltalk-capf--receiver-spec (beg)
  "Try to resolve the static class of the receiver immediately before BEG.
Returns a method spec without selector/category, or nil when unknown.

Cases handled (textual heuristics, no AST round-trip):
 * `self foo'  in a method buffer with known class  → buffer class, same side
 * `super foo' in a method buffer with known class  → buffer class, same side
 * `Integer foo'                                    → Integer, class-side
 * `Integer new foo'                                → Integer, instance-side"
  (let ((tok (pharo-smalltalk-capf--token-before beg)))
    (when tok
      (let ((token (car tok)) (start (cdr tok)))
        (cond
         ((member token '("self" "super"))
          (pharo-smalltalk-method-spec-from-buffer))
         ;; Capitalized identifier → class literal, class side.
         ((and (> (length token) 0) (<= ?A (aref token 0) ?Z))
          (pharo-smalltalk-method-spec-create
           :class-name token
           :class-side-p t))
         ;; `Class new' pattern → instance side of that class.
         ((string= token "new")
          (let ((prev (pharo-smalltalk-capf--token-before start)))
            (when (and prev (> (length (car prev)) 0)
                       (<= ?A (aref (car prev) 0) ?Z))
              (pharo-smalltalk-method-spec-create
               :class-name (car prev)
               :class-side-p nil)))))))))

(defun pharo-smalltalk-capf--class-selector-table (spec)
  "Return a completion table of SPEC's class selectors."
  (let ((selectors
         (condition-case err
             (pharo-smalltalk-class-selectors
              (pharo-smalltalk-method-spec-class-name spec)
              (pharo-smalltalk-method-spec-class-side-p spec))
           (error
            (pharo-smalltalk--warn-once
             (list 'capf-class-selectors
                   (pharo-smalltalk-method-spec-class-name spec)
                   (pharo-smalltalk-method-spec-class-side-p spec))
             "class-selectors %s%s failed: %s"
             (pharo-smalltalk-method-spec-class-name spec)
             (if (pharo-smalltalk-method-spec-class-side-p spec) " class" "")
             (error-message-string err))
            nil))))
    (and selectors (sort (copy-sequence selectors) #'string<))))

(defun pharo-smalltalk-capf--completion ()
  "`completion-at-point-functions' entry for Pharo buffers.
Tries receiver-aware selector completion first, falls back to global
class-name / selector search by prefix shape."
  (pcase (pharo-smalltalk-capf--symbol-bounds)
    (`(,beg . ,end)
     (let* ((prefix (buffer-substring-no-properties beg end))
            (first-char (and (> (length prefix) 0) (aref prefix 0)))
            (class-like (and first-char (<= ?A first-char ?Z))))
       (when (>= (length prefix) pharo-smalltalk-capf-min-prefix)
         (let ((receiver (and (not class-like)
                              (pharo-smalltalk-capf--receiver-spec beg))))
           (cond
            ;; Receiver resolved → narrow selector candidates to that class.
            (receiver
             (let ((table (pharo-smalltalk-capf--class-selector-table receiver)))
               (when table
                 (list beg end table
                       :exclusive 'no
                       :annotation-function
                       (lambda (_)
                         (format " [%s%s]"
                                 (pharo-smalltalk-method-spec-class-name receiver)
                                 (if (pharo-smalltalk-method-spec-class-side-p receiver)
                                     " class"
                                   "")))))))
            ;; Class-like prefix → all class names.
            (class-like
             (list beg end
                   (completion-table-dynamic
                    (lambda (_)
                      (condition-case err
                          (pharo-smalltalk-all-class-names)
                        (error
                         (pharo-smalltalk--warn-once
                          'capf-all-class-names
                          "all-class-names failed: %s"
                          (error-message-string err))
                         '()))))
                   :exclusive 'no
                   :annotation-function (lambda (_) " [class]")))
            ;; Otherwise → global selector search.
            (t
             (list beg end
                   (completion-table-dynamic
                    (lambda (input)
                      (when (>= (length input) pharo-smalltalk-capf-min-prefix)
                        (or (pharo-smalltalk-capf--methods-like input) '()))))
                   :exclusive 'no
                   :annotation-function (lambda (_) " [selector]"))))))))))

(defun pharo-smalltalk-capf--eldoc-class-comment-text (sym comment)
  "Return the first non-empty line of COMMENT as eldoc text for SYM, or nil."
  (when (and comment (not (string-empty-p (string-trim comment))))
    (list (car (split-string (string-trim comment) "\n" t))
          :thing sym :face 'font-lock-doc-face)))

(defun pharo-smalltalk-capf--eldoc-method-text (class side sym src)
  "Return the first source line for CLASS>>SYM as eldoc text, or nil."
  (when src
    (list (car (split-string (string-trim src) "\n" t))
          :thing (format "%s%s>>%s" class (if side " class" "") sym)
          :face 'font-lock-function-name-face)))

(defun pharo-smalltalk-capf--eldoc-deliver (callback args)
  "Invoke CALLBACK with ARGS, or with nil when ARGS is empty.
Eldoc waits for every deferred function it dispatched.  When our
async fetch comes back empty (nil source / empty comment) we still
have to release the slot, otherwise eldoc keeps the previous text
on screen until the next move."
  (if args
      (apply callback args)
    (funcall callback nil)))

(defun pharo-smalltalk-capf--symbol-still-at-point-p (buffer origin-bounds sym)
  "Non-nil iff BUFFER is live, point is still inside ORIGIN-BOUNDS, and
the buffer text at ORIGIN-BOUNDS is still SYM.
Used to discard async eldoc replies after the user moves on or edits."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (let ((beg (car origin-bounds))
               (end (cdr origin-bounds)))
           (and (<= end (point-max))
                (<= beg (point))
                (<= (point) end)
                (equal sym (buffer-substring-no-properties beg end)))))))

(defun pharo-smalltalk-capf--eldoc (callback &rest _ignored)
  "`eldoc-documentation-functions' entry for Pharo buffers.
Returns cached results synchronously when available; otherwise dispatches
the lookup asynchronously and invokes CALLBACK when the response arrives.
Async replies that arrive after the user has moved off the original
symbol deliver nil to release eldoc without showing stale text."
  (when-let* ((bounds (pharo-smalltalk-capf--symbol-bounds))
              (sym (buffer-substring-no-properties (car bounds) (cdr bounds)))
              (origin-buffer (current-buffer))
              (origin-bounds (cons (car bounds) (cdr bounds))))
    (cl-flet ((deliver-when-current (args)
                (pharo-smalltalk-capf--eldoc-deliver
                 callback
                 (and (pharo-smalltalk-capf--symbol-still-at-point-p
                       origin-buffer origin-bounds sym)
                      args))))
      (cond
       ;; Class: show first non-empty line of its comment.
       ((and (> (length sym) 0) (<= ?A (aref sym 0) ?Z))
        (let ((cached (pharo-smalltalk--source-cache-lookup
                       pharo-smalltalk--class-comment-cache sym)))
          (if cached
              (pharo-smalltalk-capf--eldoc-deliver
               callback
               (pharo-smalltalk-capf--eldoc-class-comment-text sym cached))
            (pharo-smalltalk-get-class-comment-async
             sym
             (lambda (comment)
               (deliver-when-current
                (pharo-smalltalk-capf--eldoc-class-comment-text
                 sym comment))))))
        t)
       ;; Selector: show first signature line of its source.
       ((and (> (length sym) 0)
             (or (string-match-p ":" sym)
                 (<= ?a (aref sym 0) ?z)))
        (let* ((spec (or (pharo-smalltalk-method-spec-from-buffer sym)
                         (pharo-smalltalk-method-spec-create
                          :class-name "Object"
                          :selector sym
                          :class-side-p nil)))
               (key (pharo-smalltalk-method-spec-key spec))
               (cached (pharo-smalltalk--source-cache-lookup
                        pharo-smalltalk--method-source-cache key)))
          (if cached
              (pharo-smalltalk-capf--eldoc-deliver
               callback
               (pharo-smalltalk-capf--eldoc-method-text
                (pharo-smalltalk-method-spec-class-name spec)
                (pharo-smalltalk-method-spec-class-side-p spec)
                sym cached))
            (pharo-smalltalk-get-method-source-async
             (pharo-smalltalk-method-spec-class-name spec)
             sym
             (pharo-smalltalk-method-spec-class-side-p spec)
             (lambda (src)
               (deliver-when-current
                (pharo-smalltalk-capf--eldoc-method-text
                 (pharo-smalltalk-method-spec-class-name spec)
                 (pharo-smalltalk-method-spec-class-side-p spec)
                 sym src))))))
        t)
       (t nil)))))

;;;###autoload
(defun pharo-smalltalk-capf-install ()
  "Install completion and eldoc in the current buffer."
  (add-hook 'completion-at-point-functions #'pharo-smalltalk-capf--completion nil t)
  (add-hook 'eldoc-documentation-functions #'pharo-smalltalk-capf--eldoc nil t))

(add-hook 'pharo-smalltalk-mode-hook #'pharo-smalltalk-capf-install)

(provide 'pharo-smalltalk-capf)
;;; pharo-smalltalk-capf.el ends here
