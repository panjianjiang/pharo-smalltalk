;;; pharo-smalltalk-capf.el --- completion & eldoc for Pharo Smalltalk -*- lexical-binding: t; -*-

;; Provides completion-at-point and eldoc functions that query the live
;; Pharo image via the interop server. Uses small caches to keep typing
;; responsive.

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

(defcustom pharo-smalltalk-capf-method-source-cache-max-entries 128
  "Maximum number of cached method source entries."
  :type 'integer
  :group 'pharo-smalltalk-capf)

(defcustom pharo-smalltalk-capf-min-prefix 2
  "Minimum prefix length before firing a network completion query."
  :type 'integer
  :group 'pharo-smalltalk-capf)

(defvar pharo-smalltalk-capf--method-cache (make-hash-table :test 'equal))
(defvar pharo-smalltalk-capf--method-source-cache (make-hash-table :test 'equal))

(defun pharo-smalltalk-capf--invalidate ()
  "Drop completion caches; called on Pharo-side mutations."
  (clrhash pharo-smalltalk-capf--method-cache)
  (clrhash pharo-smalltalk-capf--method-source-cache))

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
  "Return selectors matching QUERY, cached."
  (pharo-smalltalk-capf--cached
   pharo-smalltalk-capf--method-cache
   query
   (lambda ()
     (condition-case _
         (pharo-smalltalk-search-methods-like query)
       (error nil)))
   pharo-smalltalk-capf-method-cache-max-entries))

(defun pharo-smalltalk-capf--method-source (class selector class-side-p)
  "Return method source for CLASS>>SELECTOR, cached."
  (pharo-smalltalk-capf--cached
   pharo-smalltalk-capf--method-source-cache
   (list class selector class-side-p)
   (lambda ()
     (condition-case _
         (pharo-smalltalk-get-method-source class selector class-side-p)
       (error nil)))
   pharo-smalltalk-capf-method-source-cache-max-entries))

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

(defun pharo-smalltalk-capf--receiver-class (beg)
  "Try to resolve the static class of the receiver immediately before BEG.
Returns (CLASS-NAME . CLASS-SIDE-P) or nil when unknown.

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
          (when pharo-smalltalk-buffer-class-name
            (cons pharo-smalltalk-buffer-class-name
                  pharo-smalltalk-buffer-class-side-p)))
         ;; Capitalized identifier → class literal, class side.
         ((and (> (length token) 0) (<= ?A (aref token 0) ?Z))
          (cons token t))
         ;; `Class new' pattern → instance side of that class.
         ((string= token "new")
          (let ((prev (pharo-smalltalk-capf--token-before start)))
            (when (and prev (> (length (car prev)) 0)
                       (<= ?A (aref (car prev) 0) ?Z))
              (cons (car prev) nil)))))))))

(defun pharo-smalltalk-capf--class-selector-table (class-name class-side-p)
  "Return a completion table of CLASS-NAME's selectors (subject to side)."
  (let ((selectors
         (condition-case _
             (pharo-smalltalk-class-selectors class-name class-side-p)
           (error nil))))
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
                              (pharo-smalltalk-capf--receiver-class beg))))
           (cond
            ;; Receiver resolved → narrow selector candidates to that class.
            (receiver
             (let* ((cls (car receiver))
                    (side (cdr receiver))
                    (table (pharo-smalltalk-capf--class-selector-table cls side)))
               (when table
                 (list beg end table
                       :exclusive 'no
                       :annotation-function
                       (lambda (_)
                         (format " [%s%s]" cls (if side " class" "")))))))
            ;; Class-like prefix → all class names.
            (class-like
             (list beg end
                   (completion-table-dynamic
                    (lambda (_)
                      (or (ignore-errors (pharo-smalltalk-all-class-names))
                          '())))
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

(defun pharo-smalltalk-capf--eldoc (callback &rest _ignored)
  "`eldoc-documentation-functions' entry for Pharo buffers."
  (when-let* ((bounds (pharo-smalltalk-capf--symbol-bounds))
              (sym (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (cond
     ;; Class: show first non-empty line of its comment.
     ((and (> (length sym) 0) (<= ?A (aref sym 0) ?Z))
      (condition-case _
          (let ((comment (pharo-smalltalk-get-class-comment sym)))
            (when (and comment (not (string-empty-p (string-trim comment))))
              (funcall callback
                       (car (split-string (string-trim comment) "\n" t))
                       :thing sym :face 'font-lock-doc-face)))
        (error nil))
      t)
     ;; Selector: show implementor count + first signature.
     ((and (> (length sym) 0)
           (or (string-match-p ":" sym)
               (<= ?a (aref sym 0) ?z)))
      (condition-case _
          (let* ((class (or pharo-smalltalk-buffer-class-name "Object"))
                 (side pharo-smalltalk-buffer-class-side-p)
                 (src (pharo-smalltalk-capf--method-source class sym side)))
            (when src
              (funcall callback
                       (car (split-string (string-trim src) "\n" t))
                       :thing (format "%s%s>>%s" class (if side " class" "") sym)
                       :face 'font-lock-function-name-face)))
        (error nil))
      t)
     (t nil))))

;;;###autoload
(defun pharo-smalltalk-capf-install ()
  "Install completion and eldoc in the current buffer."
  (add-hook 'completion-at-point-functions #'pharo-smalltalk-capf--completion nil t)
  (add-hook 'eldoc-documentation-functions #'pharo-smalltalk-capf--eldoc nil t))

(add-hook 'pharo-smalltalk-mode-hook #'pharo-smalltalk-capf-install)

(provide 'pharo-smalltalk-capf)
;;; pharo-smalltalk-capf.el ends here
