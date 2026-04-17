;;; pharo-smalltalk-xref.el --- xref backend for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; Plugs Pharo into Emacs' xref infrastructure so M-. / M-? and
;; `xref-find-apropos' work in `pharo-smalltalk-mode' buffers.

;;; Code:

(require 'xref)
(require 'cl-lib)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-xref nil
  "xref backend for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defun pharo-smalltalk-xref--identifier-at-point ()
  "Return a string identifier at point (class name or selector)."
  (let ((sym (thing-at-point 'symbol t)))
    (cond
     ((null sym) nil)
     ;; Keyword message fragment ending in `:' — strip and treat as selector.
     ((string-match-p ":\\'" sym) sym)
     (t sym))))

(defun pharo-smalltalk-xref--looks-like-class (id)
  (and id (string-match-p "\\`[A-Z][A-Za-z0-9_]*\\'" id)))

(defun pharo-smalltalk-xref--looks-like-selector (id)
  (and id (or (string-match-p ":" id)
              (string-match-p "\\`[a-z][A-Za-z0-9_]*\\'" id)
              (string-match-p "\\`[-+*/<>=~@%&|?!,]+\\'" id))))

;;;###autoload
(defun pharo-smalltalk-xref-backend ()
  "Return the Pharo xref backend identifier for this buffer."
  'pharo-smalltalk)

(cl-defmethod xref-backend-identifier-at-point ((_ (eql pharo-smalltalk)))
  (pharo-smalltalk-xref--identifier-at-point))

(cl-defmethod xref-backend-identifier-completion-table ((_ (eql pharo-smalltalk)))
  ;; Completion table for M-. prompts — class names suffice for jumps.
  (condition-case nil
      (pharo-smalltalk-all-class-names)
    (error nil)))

(cl-defstruct (pharo-smalltalk-xref-class-location
               (:constructor pharo-smalltalk-xref-class-location-make))
  class-name group)

(cl-defmethod xref-location-group ((l pharo-smalltalk-xref-class-location))
  (or (pharo-smalltalk-xref-class-location-group l)
      (pharo-smalltalk-xref-class-location-class-name l)))

(cl-defmethod xref-location-marker ((l pharo-smalltalk-xref-class-location))
  (let* ((name (pharo-smalltalk-xref-class-location-class-name l))
         (src (pharo-smalltalk-get-class-source name))
         (dir (expand-file-name "pharo-xref" temporary-file-directory))
         (path (expand-file-name (concat name ".st") dir)))
    (make-directory dir t)
    (with-temp-file path (insert src))
    (let ((buf (find-file-noselect path)))
      (with-current-buffer buf
        (save-excursion (goto-char (point-min)) (point-marker))))))

(cl-defstruct (pharo-smalltalk-xref-method-location
               (:constructor pharo-smalltalk-xref-method-location-make))
  class-name selector class-side-p group)

(cl-defmethod xref-location-group ((l pharo-smalltalk-xref-method-location))
  (or (pharo-smalltalk-xref-method-location-group l)
      (format "%s%s"
              (pharo-smalltalk-xref-method-location-class-name l)
              (if (pharo-smalltalk-xref-method-location-class-side-p l) " class" ""))))

(cl-defmethod xref-location-marker ((l pharo-smalltalk-xref-method-location))
  (let* ((cls (pharo-smalltalk-xref-method-location-class-name l))
         (sel (pharo-smalltalk-xref-method-location-selector l))
         (side (pharo-smalltalk-xref-method-location-class-side-p l))
         (src (condition-case err
                  (pharo-smalltalk-get-method-source cls sel side)
                (error
                 (if side
                     (signal (car err) (cdr err))
                   ;; Instance-side failed; try class-side and remember.
                   (condition-case _
                       (prog1 (pharo-smalltalk-get-method-source cls sel t)
                         (setf (pharo-smalltalk-xref-method-location-class-side-p l) t))
                     (error (signal (car err) (cdr err))))))))
         (side* (pharo-smalltalk-xref-method-location-class-side-p l))
         (dir (expand-file-name "pharo-xref" temporary-file-directory))
         (filename (format "%s%s_%s.st"
                           cls (if side* "_class" "")
                           (replace-regexp-in-string "[^A-Za-z0-9_]" "_" sel)))
         (path (expand-file-name filename dir)))
    (make-directory dir t)
    (with-temp-file path (insert src))
    (let ((buf (find-file-noselect path)))
      (with-current-buffer buf
        (save-excursion (goto-char (point-min)) (point-marker))))))

(defun pharo-smalltalk-xref--class-definition (class-name)
  (xref-make (format "class %s" class-name)
             (pharo-smalltalk-xref-class-location-make
              :class-name class-name
              :group (pharo-smalltalk-xref--group-label class-name))))

(defun pharo-smalltalk-xref--method-ref (class-name selector &optional class-side-p)
  (pharo-smalltalk-xref--method-ref-from-spec
   (pharo-smalltalk-method-spec-create
    :class-name class-name
    :selector selector
    :class-side-p (and class-side-p t))))

(defun pharo-smalltalk-xref--method-ref-from-spec (spec)
  "Build an xref item from method SPEC."
  (xref-make
   (pharo-smalltalk-method-spec-display-name spec)
   (pharo-smalltalk-xref-method-location-make
    :class-name (pharo-smalltalk-method-spec-class-name spec)
    :selector (pharo-smalltalk-method-spec-selector spec)
    :class-side-p (and (pharo-smalltalk-method-spec-class-side-p spec) t))))

(defun pharo-smalltalk-xref--group-label (class-name)
  "Return a user-facing group label for CLASS-NAME in the current context."
  (let ((current-class pharo-smalltalk-buffer-class-name)
        (distance (pharo-smalltalk-xref--lineage-distance
                   pharo-smalltalk-buffer-class-name class-name)))
    (cond
     ((and current-class (equal class-name current-class))
      "Current class")
     ((numberp distance)
      "Superclass chain")
     (t
      "Other classes"))))

(defun pharo-smalltalk-xref--normalize-method-hit (class-name selector)
  "Normalize CLASS-NAME and SELECTOR from a server result into a method spec."
  (let ((class-side-p (and class-name
                           (string-match-p " class\\'" class-name)
                           t)))
    (pharo-smalltalk-method-spec-create
     :class-name (if class-side-p
                     (string-remove-suffix " class" class-name)
                   class-name)
     :selector selector
     :class-side-p class-side-p)))

(defvar pharo-smalltalk-xref--lineage-cache (make-hash-table :test 'equal)
  "Cache of class lineage lists keyed by class name.")

(defun pharo-smalltalk-xref--invalidate-lineage-cache ()
  "Drop cached class lineage information."
  (clrhash pharo-smalltalk-xref--lineage-cache))

(add-hook 'pharo-smalltalk-after-mutation-hook
          #'pharo-smalltalk-xref--invalidate-lineage-cache)

(defun pharo-smalltalk-xref--direct-superclass (class-name)
  "Return the direct superclass name of CLASS-NAME, or nil."
  (condition-case nil
      (alist-get 'superclass
                 (pharo-smalltalk-parse-class-definition
                  (pharo-smalltalk-get-class-source class-name)))
    (error nil)))

(defun pharo-smalltalk-xref--class-lineage (class-name)
  "Return CLASS-NAME followed by its superclass chain."
  (when class-name
    (or (gethash class-name pharo-smalltalk-xref--lineage-cache)
        (let ((seen nil)
              (current class-name)
              lineage)
          (while (and current (not (member current seen)))
            (push current seen)
            (push current lineage)
            (setq current (pharo-smalltalk-xref--direct-superclass current)))
          (setq lineage (nreverse lineage))
          (puthash class-name lineage pharo-smalltalk-xref--lineage-cache)
          lineage))))

(defun pharo-smalltalk-xref--lineage-distance (current-class class-name)
  "Return superclass-chain distance from CURRENT-CLASS to CLASS-NAME, or nil."
  (when (and current-class class-name)
    (cl-position class-name
                 (pharo-smalltalk-xref--class-lineage current-class)
                 :test #'equal)))

(defun pharo-smalltalk-xref--item-rank (item)
  "Return a sort key for xref ITEM in the current buffer context.
Smaller keys rank earlier. Prefer exact current class matches, then the
current superclass chain, then other methods, then shorter summaries."
  (let* ((loc (xref-item-location item))
         (current-class pharo-smalltalk-buffer-class-name)
         (current-side pharo-smalltalk-buffer-class-side-p)
         (summary (xref-item-summary item))
         (is-method (pharo-smalltalk-xref-method-location-p loc))
         (class-name (and is-method
                          (pharo-smalltalk-xref-method-location-class-name loc)))
         (class-side-p (and is-method
                            (pharo-smalltalk-xref-method-location-class-side-p loc)))
         (distance (and is-method
                        (pharo-smalltalk-xref--lineage-distance current-class class-name))))
    (list
     (cond
      ((and current-class is-method (equal class-name current-class)) 0)
      ((numberp distance) 1)
      (is-method 2)
      (t 3))
     (if (and current-class is-method (equal class-name current-class)
              (eq class-side-p current-side))
         0
       1)
     (or distance 999)
     (length summary)
     summary)))

(defun pharo-smalltalk-xref--sort-items (items)
  "Sort xref ITEMS by current buffer relevance."
  (sort items
        (lambda (a b)
          (let ((ra (pharo-smalltalk-xref--item-rank a))
                (rb (pharo-smalltalk-xref--item-rank b)))
            (cond
             ((equal ra rb) nil)
             (t
              (catch 'done
                (while (and ra rb)
                  (let ((xa (pop ra))
                        (xb (pop rb)))
                    (unless (equal xa xb)
                      (throw 'done
                             (if (and (numberp xa) (numberp xb))
                                 (< xa xb)
                               (string< (format "%s" xa) (format "%s" xb)))))))
                (< (length ra) (length rb)))))))))

(cl-defmethod xref-backend-definitions ((_ (eql pharo-smalltalk)) identifier)
  (let (locs)
    ;; If it looks like a class, jump directly to that class source.
    (when (pharo-smalltalk-xref--looks-like-class identifier)
      (condition-case err
          (push (pharo-smalltalk-xref--class-definition identifier) locs)
        (error (message "pharo xref: no class %s (%s)"
                        identifier (error-message-string err)))))
    ;; Then try implementors for anything selector-shaped.
    (when (pharo-smalltalk-xref--looks-like-selector identifier)
      (condition-case err
          (let* ((resp (pharo-smalltalk--request
                        "/search-implementors"
                        :params `((method_name . ,identifier))))
                 (impls (alist-get 'result resp)))
            (dolist (impl impls)
              (let ((spec (pharo-smalltalk-xref--normalize-method-hit
                           (alist-get 'class impl)
                           (alist-get 'method impl))))
                (when (and (pharo-smalltalk-method-spec-class-name spec)
                           (pharo-smalltalk-method-spec-selector spec))
                  (let ((item (pharo-smalltalk-xref--method-ref-from-spec spec)))
                    (setf (pharo-smalltalk-xref-method-location-group
                           (xref-item-location item))
                          (pharo-smalltalk-xref--group-label
                           (pharo-smalltalk-method-spec-class-name spec)))
                    (push item locs))))))
        (error (message "pharo xref: search-implementors failed (%s)"
                        (error-message-string err)))))
    (pharo-smalltalk-xref--sort-items
     (cl-remove-duplicates (delq nil (nreverse locs))
                           :test (lambda (a b)
                                   (equal (xref-item-summary a)
                                          (xref-item-summary b)))))))

(cl-defmethod xref-backend-references ((_ (eql pharo-smalltalk)) identifier)
  (let (locs)
    (when (pharo-smalltalk-xref--looks-like-class identifier)
      (condition-case err
          (let* ((resp (pharo-smalltalk--request
                        "/search-references-to-class"
                        :params `((class_name . ,identifier))))
                 (refs (alist-get 'result resp)))
            (dolist (ref refs)
              (let ((spec (pharo-smalltalk-xref--normalize-method-hit
                           (alist-get 'class ref)
                           (alist-get 'method ref))))
                (when (and (pharo-smalltalk-method-spec-class-name spec)
                           (pharo-smalltalk-method-spec-selector spec))
                  (let ((item (pharo-smalltalk-xref--method-ref-from-spec spec)))
                    (setf (pharo-smalltalk-xref-method-location-group
                           (xref-item-location item))
                          (pharo-smalltalk-xref--group-label
                           (pharo-smalltalk-method-spec-class-name spec)))
                    (push item locs))))))
        (error (message "pharo xref: search-references-to-class failed (%s)"
                        (error-message-string err)))))
    (when (pharo-smalltalk-xref--looks-like-selector identifier)
      (condition-case err
          (let* ((resp (pharo-smalltalk--request
                        "/search-references"
                        :params `((program_symbol . ,identifier))))
                 (refs (alist-get 'result resp)))
            (dolist (ref refs)
              (let ((spec (pharo-smalltalk-xref--normalize-method-hit
                           (alist-get 'class ref)
                           (alist-get 'method ref))))
                (when (and (pharo-smalltalk-method-spec-class-name spec)
                           (pharo-smalltalk-method-spec-selector spec))
                  (let ((item (pharo-smalltalk-xref--method-ref-from-spec spec)))
                    (setf (pharo-smalltalk-xref-method-location-group
                           (xref-item-location item))
                          (pharo-smalltalk-xref--group-label
                           (pharo-smalltalk-method-spec-class-name spec)))
                    (push item locs))))))
        (error (message "pharo xref: search-references failed (%s)"
                        (error-message-string err)))))
    (pharo-smalltalk-xref--sort-items
     (cl-remove-duplicates (delq nil (nreverse locs))
                           :test (lambda (a b)
                                   (equal (xref-item-summary a)
                                          (xref-item-summary b)))))))

(cl-defmethod xref-backend-apropos ((_ (eql pharo-smalltalk)) pattern)
  (let (locs)
    (condition-case _
        (dolist (class-name (pharo-smalltalk-search-classes-like pattern))
          (push (pharo-smalltalk-xref--class-definition class-name) locs))
      (error nil))
    (condition-case _
        (let* ((resp (pharo-smalltalk--request "/search-methods-like"
                                               :params `((method_name_query . ,pattern))))
               (hits (alist-get 'result resp)))
          (dolist (hit hits)
            (condition-case nil
                (let* ((impl-resp (pharo-smalltalk--request
                                   "/search-implementors"
                                   :params `((method_name . ,hit))))
                       (impls (alist-get 'result impl-resp)))
                  (dolist (impl impls)
                    (let ((spec (pharo-smalltalk-xref--normalize-method-hit
                                 (alist-get 'class impl)
                                 (alist-get 'method impl))))
                      (when (and (pharo-smalltalk-method-spec-class-name spec)
                                 (pharo-smalltalk-method-spec-selector spec))
                        (let ((item (pharo-smalltalk-xref--method-ref-from-spec spec)))
                          (setf (pharo-smalltalk-xref-method-location-group
                                 (xref-item-location item))
                                (pharo-smalltalk-xref--group-label
                                 (pharo-smalltalk-method-spec-class-name spec)))
                          (push item locs))))))
              (error nil))))
      (error nil))
    (pharo-smalltalk-xref--sort-items
     (cl-remove-duplicates (delq nil (nreverse locs))
                           :test (lambda (a b)
                                   (equal (xref-item-summary a)
                                          (xref-item-summary b)))))))

;;;###autoload
(defun pharo-smalltalk-xref-install ()
  "Install the Pharo xref backend for `pharo-smalltalk-mode' buffers."
  (add-hook 'xref-backend-functions #'pharo-smalltalk-xref-backend nil t))

(add-hook 'pharo-smalltalk-mode-hook #'pharo-smalltalk-xref-install)

(provide 'pharo-smalltalk-xref)
;;; pharo-smalltalk-xref.el ends here
