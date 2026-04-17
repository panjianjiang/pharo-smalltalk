;;; pharo-smalltalk-browser.el --- System browser for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; A Pharo-style System Browser built on `tabulated-list-mode'.
;; Drill-down navigation: packages, classes, methods, source.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-browser nil
  "System browser for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-browser-buffer-name "*Pharo Browser*"
  "Buffer name used by the Pharo system browser."
  :type 'string
  :group 'pharo-smalltalk-browser)

;; ------------- Common scaffolding -------------

(defvar-local pharo-smalltalk-browser--stack nil
  "Stack of (VIEW-SPEC . CURSOR) frames for back-navigation.")

(defvar-local pharo-smalltalk-browser--current nil
  "Current view spec (KIND . ARG-PLIST).")

(defun pharo-smalltalk-browser--push ()
  "Push current cursor position onto the navigation stack."
  (when pharo-smalltalk-browser--current
    (push (cons pharo-smalltalk-browser--current
                (line-number-at-pos))
          pharo-smalltalk-browser--stack)))

(defun pharo-smalltalk-browser-back ()
  "Go back one level in the browser."
  (interactive)
  (if-let* ((frame (pop pharo-smalltalk-browser--stack)))
      (progn
        (pharo-smalltalk-browser--render (car frame))
        (goto-char (point-min))
        (forward-line (1- (cdr frame))))
    (user-error "Already at top of browser")))

(defun pharo-smalltalk-browser-refresh ()
  "Re-render the current view from the server, bypassing local caches."
  (interactive)
  (pharo-smalltalk--invalidate-browser-caches)
  (when pharo-smalltalk-browser--current
    (pharo-smalltalk-browser--render pharo-smalltalk-browser--current)))

(defvar pharo-smalltalk-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pharo-smalltalk-browser-activate)
    (define-key map (kbd "u")   #'pharo-smalltalk-browser-back)
    (define-key map (kbd "^")   #'pharo-smalltalk-browser-back)
    (define-key map (kbd "g")   #'pharo-smalltalk-browser-refresh)
    (define-key map (kbd "c")   #'pharo-smalltalk-browser-toggle-side)
    (define-key map (kbd "D")   #'pharo-smalltalk-browser-remove-at-point)
    (define-key map (kbd "q")   #'quit-window)
    map))

(define-derived-mode pharo-smalltalk-browser-mode tabulated-list-mode "Pharo-Browser"
  "Major mode for browsing Pharo packages, classes, and methods."
  (setq tabulated-list-padding 1))

;; ------------- Views -------------

(defun pharo-smalltalk-browser--render (spec)
  "Render view SPEC into the browser buffer."
  (pcase spec
    (`(packages) (pharo-smalltalk-browser--render-packages))
    (`(classes ,pkg) (pharo-smalltalk-browser--render-classes pkg))
    (`(methods ,class ,side) (pharo-smalltalk-browser--render-methods class side))
    (`(source ,class ,selector ,side ,category)
     (pharo-smalltalk-browser--render-source class selector side category))
    (_ (user-error "Unknown browser view spec: %S" spec))))

(defun pharo-smalltalk-browser--render-packages ()
  (let ((buf (get-buffer-create pharo-smalltalk-browser-buffer-name))
        (packages (sort (copy-sequence (pharo-smalltalk-list-packages)) #'string<)))
    (with-current-buffer buf
      (pharo-smalltalk-browser-mode)
      (setq tabulated-list-format [("Package" 60 t)])
      (setq tabulated-list-entries
            (mapcar (lambda (p) (list p (vector p))) packages))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (setq pharo-smalltalk-browser--current '(packages))
      (setq header-line-format
            (format " Packages (%d)   RET=open  u=back  g=refresh  q=quit"
                    (length packages))))
    (display-buffer buf)
    (pop-to-buffer buf)))

(defun pharo-smalltalk-browser--render-classes (package)
  (let ((buf (get-buffer-create pharo-smalltalk-browser-buffer-name))
        (classes (sort (copy-sequence (pharo-smalltalk-list-classes package))
                       #'string<))
        (extended (condition-case _
                      (pharo-smalltalk-list-extended-classes package)
                    (error nil))))
    (with-current-buffer buf
      (pharo-smalltalk-browser-mode)
      (setq tabulated-list-format [("Class" 50 t) ("Kind" 12 t)])
      (setq tabulated-list-entries
            (append
             (mapcar (lambda (c) (list c (vector c "owned"))) classes)
             (mapcar (lambda (c) (list (format "ext:%s" c) (vector c "extension")))
                     extended)))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (setq pharo-smalltalk-browser--current `(classes ,package))
      (setq header-line-format
            (format " Package: %s (%d classes, %d extensions)   RET=open  u=back  g=refresh  q=quit"
                    package (length classes) (length extended))))))

(defun pharo-smalltalk-browser--render-methods (class side)
  (let* ((buf (get-buffer-create pharo-smalltalk-browser-buffer-name))
         (protocols (pharo-smalltalk--class-protocols class))
         (bucket (alist-get side protocols))
         (rows
          (cl-loop for proto in bucket
                   for cat = (alist-get 'category proto)
                   nconc
                   (mapcar (lambda (sel)
                             (let ((spec (pharo-smalltalk-method-spec-create
                                          :class-name class
                                          :selector sel
                                          :class-side-p (eq side 'class)
                                          :category cat)))
                               (list spec (vector sel (or cat "")))))
                           (alist-get 'methods proto)))))
    (with-current-buffer buf
      (pharo-smalltalk-browser-mode)
      (setq tabulated-list-format [("Selector" 40 t) ("Category" 40 t)])
      (setq tabulated-list-entries rows)
      (tabulated-list-init-header)
      (tabulated-list-print)
      (setq pharo-smalltalk-browser--current `(methods ,class ,side))
      (setq header-line-format
            (format " %s (%s side) — %d methods   RET=source  c=toggle side  u=back  g=refresh  q=quit"
                    class side (length rows))))))

(defun pharo-smalltalk-browser--render-source (class selector side &optional category)
  (let* ((class-side-p (eq side 'class))
         (src (pharo-smalltalk-get-method-source class selector class-side-p))
         (buf (get-buffer-create pharo-smalltalk-browser-buffer-name)))
    (with-current-buffer buf
      (fundamental-mode)  ; leave tabulated mode
      (pharo-smalltalk-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert src))
      (setq-local pharo-smalltalk-buffer-class-name class)
      (setq-local pharo-smalltalk-buffer-class-side-p class-side-p)
      (setq-local pharo-smalltalk-buffer-source-kind 'method)
      (setq-local pharo-smalltalk-buffer-method-category
                  (or category pharo-smalltalk-default-method-category))
      (goto-char (point-min))
      (setq pharo-smalltalk-browser--current
            `(source ,class ,selector ,side ,category))
      (setq header-line-format
            (format " %s%s>>%s   u=back to method list"
                    class (if class-side-p " class" "") selector))
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map (current-local-map))
        (define-key map (kbd "u") #'pharo-smalltalk-browser-back)
        (use-local-map map)))))

;; ------------- Row activation -------------

(defun pharo-smalltalk-browser-activate ()
  "Drill into the entry at point."
  (interactive)
  (let* ((entry (tabulated-list-get-entry))
         (spec pharo-smalltalk-browser--current))
    (unless entry (user-error "Nothing at point"))
    (pharo-smalltalk-browser--push)
    (pcase spec
      (`(packages)
       (pharo-smalltalk-browser--render-classes (aref entry 0)))
      (`(classes ,_pkg)
       (pharo-smalltalk-browser--render-methods (aref entry 0) 'instance))
      (`(methods ,_class ,_side)
       (let ((spec (tabulated-list-get-id)))
         (pharo-smalltalk-browser--render-source
          (pharo-smalltalk-method-spec-class-name spec)
          (pharo-smalltalk-method-spec-selector spec)
          (pharo-smalltalk-method-spec-side-symbol spec)
          (pharo-smalltalk-method-spec-category spec))))
      (_ (user-error "Nothing to activate in this view")))))

(defun pharo-smalltalk-browser-toggle-side ()
  "Toggle between instance/class side in the method view."
  (interactive)
  (pcase pharo-smalltalk-browser--current
    (`(methods ,class ,side)
     (pharo-smalltalk-browser--render-methods
      class (if (eq side 'instance) 'class 'instance)))
    (_ (user-error "Toggle only available in the method view"))))

(defun pharo-smalltalk-browser-remove-at-point ()
  "Remove the browser item at point when the current view supports it."
  (interactive)
  (pcase pharo-smalltalk-browser--current
    (`(classes ,_package)
     (let ((class-name (aref (tabulated-list-get-entry) 0)))
       (unless class-name
         (user-error "Nothing at point"))
       (unless (y-or-n-p (format "Remove class %s? " class-name))
         (user-error "Aborted"))
       (pharo-smalltalk-remove-class class-name)
       (pharo-smalltalk-browser-refresh)))
    (`(methods ,_class ,_side)
     (let ((spec (tabulated-list-get-id)))
       (unless spec
         (user-error "Nothing at point"))
       (unless (y-or-n-p
                (format "Remove %s%s>>%s? "
                        (pharo-smalltalk-method-spec-class-name spec)
                        (if (pharo-smalltalk-method-spec-class-side-p spec) " class" "")
                        (pharo-smalltalk-method-spec-selector spec)))
         (user-error "Aborted"))
       (pharo-smalltalk-remove-method
        (pharo-smalltalk-method-spec-class-name spec)
        (pharo-smalltalk-method-spec-selector spec)
        (pharo-smalltalk-method-spec-class-side-p spec))
       (pharo-smalltalk-browser-refresh)))
    (_
     (user-error "Remove is available in class and method browser views only"))))

;;;###autoload
(defun pharo-smalltalk-browse ()
  "Open the Pharo System Browser at the package level."
  (interactive)
  (let ((buf (get-buffer-create pharo-smalltalk-browser-buffer-name)))
    (with-current-buffer buf
      (setq pharo-smalltalk-browser--stack nil))
    (pharo-smalltalk-browser--render '(packages))))

;;;###autoload
(defun pharo-smalltalk-browse-class-in-browser (class-name)
  "Open the browser directly at CLASS-NAME's instance methods."
  (interactive (list (pharo-smalltalk--read-class-name)))
  (let ((buf (get-buffer-create pharo-smalltalk-browser-buffer-name)))
    (with-current-buffer buf
      (setq pharo-smalltalk-browser--stack nil))
    (pharo-smalltalk-browser--render `(methods ,class-name instance))))

(provide 'pharo-smalltalk-browser)
;;; pharo-smalltalk-browser.el ends here
