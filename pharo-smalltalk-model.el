;;; pharo-smalltalk-model.el --- Shared model and cache helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared internal data structures and cache helpers used by the core
;; bridge, browser, xref, and completion layers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (pharo-smalltalk-method-spec
               (:constructor pharo-smalltalk-method-spec-create))
  class-name
  selector
  class-side-p
  category)

(defun pharo-smalltalk-method-spec-side-symbol (spec)
  "Return SPEC's side as `class' or `instance'."
  (if (pharo-smalltalk-method-spec-class-side-p spec) 'class 'instance))

(defun pharo-smalltalk-method-spec-key (spec)
  "Return SPEC's cache key."
  (list (pharo-smalltalk-method-spec-class-name spec)
        (pharo-smalltalk-method-spec-selector spec)
        (and (pharo-smalltalk-method-spec-class-side-p spec) t)))

(defun pharo-smalltalk-method-spec-display-name (spec)
  "Return a human-readable CLASS>>SELECTOR name for SPEC."
  (format "%s%s>>%s"
          (pharo-smalltalk-method-spec-class-name spec)
          (if (pharo-smalltalk-method-spec-class-side-p spec) " class" "")
          (pharo-smalltalk-method-spec-selector spec)))

(defun pharo-smalltalk-method-spec-from-server-hit (class-name selector &optional category)
  "Normalize a server HIT into a method spec.
CLASS-NAME may include a trailing \" class\" suffix."
  (let ((class-side-p (and class-name
                           (string-match-p " class\\'" class-name)
                           t)))
    (pharo-smalltalk-method-spec-create
     :class-name (if class-side-p
                     (string-remove-suffix " class" class-name)
                   class-name)
     :selector selector
     :class-side-p class-side-p
     :category category)))

(defun pharo-smalltalk--cache-fresh-p (timestamp ttl)
  "Non-nil when TIMESTAMP is within TTL seconds."
  (and (numberp timestamp)
       (< (- (float-time) timestamp) ttl)))

(defun pharo-smalltalk--cache-get (table key ttl compute)
  "Return cached value for KEY in TABLE; otherwise call COMPUTE and store it.
TTL controls freshness."
  (let ((entry (gethash key table)))
    (if (and entry (pharo-smalltalk--cache-fresh-p (cdr entry) ttl))
        (car entry)
      (let ((fresh (funcall compute)))
        (puthash key (cons fresh (float-time)) table)
        fresh))))

(defun pharo-smalltalk--source-cache-lookup (table key ttl)
  "Return fresh cached value for KEY in TABLE, or nil when missing/stale.
TTL controls freshness."
  (let ((entry (gethash key table)))
    (when (and entry (pharo-smalltalk--cache-fresh-p (cdr entry) ttl))
      (car entry))))

(defun pharo-smalltalk--source-cache-store (table key value)
  "Store VALUE under KEY in TABLE with the current timestamp."
  (puthash key (cons value (float-time)) table)
  value)

(defun pharo-smalltalk--cached-source-value (table key ttl fetcher)
  "Return cached value from TABLE for KEY, or compute it with FETCHER.
TTL controls freshness."
  (or (pharo-smalltalk--source-cache-lookup table key ttl)
      (pharo-smalltalk--source-cache-store table key (funcall fetcher))))

(provide 'pharo-smalltalk-model)
;;; pharo-smalltalk-model.el ends here
