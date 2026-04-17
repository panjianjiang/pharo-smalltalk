;;; pharo-smalltalk-inspector.el --- Inspector UI for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; Inspector UI that renders the `SisInspector' JSON tree from the
;; live Pharo image.  Entry point: `pharo-smalltalk-inspect-expression'
;; (bound to `C-c s j' when the command prefix is installed).
;;
;; In the buffer:
;;   RET — drill into the row under point (opens a child view)
;;   u   — pop back to the previous view
;;   g   — refresh the current view from the image
;;   q   — quit the inspector buffer

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-inspector nil
  "Inspector UI for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-inspector-buffer-name "*Pharo Inspector*"
  "Buffer name used by `pharo-smalltalk-inspect-expression'."
  :type 'string
  :group 'pharo-smalltalk-inspector)

(defface pharo-smalltalk-inspector-class-face
  '((t :inherit font-lock-type-face))
  "Face for the class name column."
  :group 'pharo-smalltalk-inspector)

(defface pharo-smalltalk-inspector-name-face
  '((t :inherit font-lock-variable-name-face))
  "Face for inst-var or index labels."
  :group 'pharo-smalltalk-inspector)

(defface pharo-smalltalk-inspector-print-face
  '((t :inherit font-lock-string-face))
  "Face for printString values."
  :group 'pharo-smalltalk-inspector)

(defvar-local pharo-smalltalk-inspector--stack nil
  "List of previously-rendered trees, newest first (for `u').")

(defvar-local pharo-smalltalk-inspector--current nil
  "The tree alist currently rendered in the buffer.")

(defvar-local pharo-smalltalk-inspector--origin-expression nil
  "The original Smalltalk expression the inspector started from.
Used by `g' to refresh the root tree.")

(defun pharo-smalltalk-inspector--fetch-expression (expression)
  "Ask Pharo to inspect EXPRESSION and return the resulting tree alist."
  (pharo-smalltalk-eval
   (format "SisInspector inspectExpression: %s"
           (pharo-smalltalk--smalltalk-string expression))))

(defun pharo-smalltalk-inspector--fetch-ref (ref)
  "Ask Pharo to re-render the object stored under REF."
  (pharo-smalltalk-eval
   (format "SisInspector inspectRef: %d" ref)))

(defvar pharo-smalltalk-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pharo-smalltalk-inspector-drill)
    (define-key map (kbd "TAB") #'pharo-smalltalk-inspector-drill)
    (define-key map (kbd "u")   #'pharo-smalltalk-inspector-back)
    (define-key map (kbd "^")   #'pharo-smalltalk-inspector-back)
    (define-key map (kbd "g")   #'pharo-smalltalk-inspector-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    map)
  "Keymap for `pharo-smalltalk-inspector-mode'.")

(define-derived-mode pharo-smalltalk-inspector-mode special-mode "Pharo-Inspector"
  "Major mode for the Pharo object inspector."
  (setq truncate-lines t)
  (hl-line-mode 1))

(defun pharo-smalltalk-inspector--insert-row (label row)
  "Insert one LABEL + ROW line and attach the ROW alist as a text property.
ROW must have `ref', `class', `print', and `has_children' keys."
  (let* ((class (alist-get 'class row))
         (print (alist-get 'print row))
         (children (alist-get 'has_children row))
         (marker (if children "▸ " "  "))
         (start (point)))
    (insert marker)
    (when label
      (insert (propertize label 'face 'pharo-smalltalk-inspector-name-face))
      (insert " = "))
    (insert (propertize (or print "")
                        'face 'pharo-smalltalk-inspector-print-face))
    (insert "  ")
    (insert (propertize (format "(%s)" (or class "?"))
                        'face 'pharo-smalltalk-inspector-class-face))
    (insert "\n")
    (add-text-properties start (point) `(pharo-smalltalk-inspector-row ,row))))

(defun pharo-smalltalk-inspector--render (tree)
  "Render the TREE alist into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "%s\n"
                                (or (alist-get 'print tree) "<unknown>"))
                        'face 'bold))
    (insert (format "class : %s   identity_hash : %s\n"
                    (or (alist-get 'class tree) "?")
                    (or (alist-get 'identity_hash tree) "?")))
    (when (alist-get 'size tree)
      (insert (format "size  : %d\n" (alist-get 'size tree))))
    (insert (make-string 60 ?─) "\n")
    (let ((inst-vars (alist-get 'inst_vars tree)))
      (when (and inst-vars (> (length inst-vars) 0))
        (insert (propertize "Instance variables\n" 'face 'bold))
        (dolist (row inst-vars)
          (pharo-smalltalk-inspector--insert-row
           (alist-get 'name row) row))
        (insert "\n")))
    (let ((indexable (alist-get 'indexable tree)))
      (when (and indexable (> (length indexable) 0))
        (insert (propertize "Indexable\n" 'face 'bold))
        (dolist (row indexable)
          (pharo-smalltalk-inspector--insert-row
           (alist-get 'name row) row))))
    (goto-char (point-min))
    (forward-line 4)
    (setq pharo-smalltalk-inspector--current tree)))

(defun pharo-smalltalk-inspector--open (tree &optional reset-stack origin)
  "Display TREE in the inspector buffer.
When RESET-STACK is non-nil, clear the navigation stack.
When ORIGIN is non-nil, remember it as the root expression for refresh."
  (let ((buf (get-buffer-create pharo-smalltalk-inspector-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'pharo-smalltalk-inspector-mode)
        (pharo-smalltalk-inspector-mode))
      (when reset-stack
        (setq pharo-smalltalk-inspector--stack nil
              pharo-smalltalk-inspector--origin-expression nil))
      (when origin
        (setq pharo-smalltalk-inspector--origin-expression origin))
      (pharo-smalltalk-inspector--render tree))
    (display-buffer buf)
    (pop-to-buffer buf)))

(defun pharo-smalltalk-inspector-drill ()
  "Drill into the row at point."
  (interactive)
  (let ((row (get-text-property (point) 'pharo-smalltalk-inspector-row)))
    (unless row (user-error "No inspectable row at point"))
    (let ((ref (alist-get 'ref row)))
      (unless (integerp ref) (user-error "Row has no ref to drill into"))
      (push pharo-smalltalk-inspector--current
            pharo-smalltalk-inspector--stack)
      (pharo-smalltalk-inspector--render
       (pharo-smalltalk-inspector--fetch-ref ref)))))

(defun pharo-smalltalk-inspector-back ()
  "Pop back to the previously-inspected object."
  (interactive)
  (let ((prev (pop pharo-smalltalk-inspector--stack)))
    (unless prev (user-error "Already at inspector root"))
    (pharo-smalltalk-inspector--render prev)))

(defun pharo-smalltalk-inspector-refresh ()
  "Re-fetch the current view from Pharo.
If the buffer was opened from an expression, re-evaluate that
expression (resetting the navigation stack).  Otherwise refresh the
current ref in place."
  (interactive)
  (cond
   (pharo-smalltalk-inspector--origin-expression
    (setq pharo-smalltalk-inspector--stack nil)
    (pharo-smalltalk-inspector--render
     (pharo-smalltalk-inspector--fetch-expression
      pharo-smalltalk-inspector--origin-expression)))
   ((and pharo-smalltalk-inspector--current
         (integerp (alist-get 'ref pharo-smalltalk-inspector--current)))
    (pharo-smalltalk-inspector--render
     (pharo-smalltalk-inspector--fetch-ref
      (alist-get 'ref pharo-smalltalk-inspector--current))))
   (t (user-error "Nothing to refresh"))))

;;;###autoload
(defun pharo-smalltalk-inspect-expression (expression)
  "Evaluate EXPRESSION in Pharo and open the inspector on the result."
  (interactive "sInspect Smalltalk expression: ")
  (pharo-smalltalk-inspector--open
   (pharo-smalltalk-inspector--fetch-expression expression)
   t expression))

;;;###autoload
(defun pharo-smalltalk-inspect-last-result ()
  "Open the inspector on the server-side tree for the most recent eval.
Requires that the last eval went through with `:inspect' truthy (for
example via `pharo-smalltalk-eval-region-or-line').  Refresh/back/drill
work as normal; the root can be refreshed because its ref is still
registered server-side."
  (interactive)
  (unless (bound-and-true-p pharo-smalltalk-last-result-tree)
    (user-error "No inspectable result captured — evaluate a line with C-c s e first"))
  (pharo-smalltalk-inspector--open pharo-smalltalk-last-result-tree t nil))

;;;###autoload
(defun pharo-smalltalk-inspect-class-at-point-with-inspector ()
  "Inspect the class named at point by instantiating it with `new'."
  (interactive)
  (let ((class (pharo-smalltalk--class-name-at-point)))
    (unless class (user-error "No class name at point"))
    (pharo-smalltalk-inspect-expression (concat class " new"))))

(provide 'pharo-smalltalk-inspector)
;;; pharo-smalltalk-inspector.el ends here
