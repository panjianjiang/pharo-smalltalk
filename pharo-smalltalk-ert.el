;;; pharo-smalltalk-ert.el --- ERT tests for Pharo Smalltalk integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'xref)
(require 'pharo-smalltalk)
(require 'pharo-smalltalk-xref)
(require 'pharo-smalltalk-capf)

(ert-deftest pharo-smalltalk-package-metadata-is-available ()
  (should (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\'"
                          pharo-smalltalk-version))
  (let ((pkg-file (locate-library "pharo-smalltalk-pkg.el")))
    (should pkg-file)
    (with-temp-buffer
      (insert-file-contents pkg-file)
      (goto-char (point-min))
      (should (search-forward "\"pharo-smalltalk\"" nil t))
      (goto-char (point-min))
      (should (search-forward "\"0.1.0\"" nil t))
      (goto-char (point-min))
      (should (search-forward "define-package" nil t)))))

(ert-deftest pharo-smalltalk-package-doc-files-exist ()
  (should (file-exists-p "/home/panjj/.emacs.d/lisp/CHANGELOG.md"))
  (should (file-exists-p "/home/panjj/.emacs.d/lisp/LICENSE")))

(ert-deftest pharo-smalltalk-install-registers-package-defaults ()
  (let ((pharo-smalltalk--installed-p nil)
        (pharo-smalltalk-package-modules '(browser))
        (pharo-smalltalk-global-command-key "C-c s")
        (pharo-smalltalk-auto-mode-patterns '("\\.st\\'" "\\.tonel\\'"))
        (auto-mode-alist nil)
        (previous-binding (lookup-key global-map (kbd "C-c s"))))
    (unwind-protect
        (progn
          (pharo-smalltalk-install)
          (should pharo-smalltalk--installed-p)
          (should (featurep 'pharo-smalltalk-browser))
          (should (eq (cdr (assoc "\\.st\\'" auto-mode-alist))
                      #'pharo-smalltalk-mode))
          (should (eq (cdr (assoc "\\.tonel\\'" auto-mode-alist))
                      #'pharo-smalltalk-mode))
          (should (eq (lookup-key global-map (kbd "C-c s"))
                      pharo-smalltalk-command-map)))
      (if previous-binding
          (define-key global-map (kbd "C-c s") previous-binding)
        (global-unset-key (kbd "C-c s"))))))

(ert-deftest pharo-smalltalk-store-and-display-extracts-transcript ()
  (let ((pharo-smalltalk-last-transcript nil)
        (pharo-smalltalk-last-result nil)
        (pharo-smalltalk-last-response nil))
    (should
     (equal
      (pharo-smalltalk--store-and-display
       '((success . t) (result . 7) (transcript . "hello"))
       "Result"
       "eval")
      7))
    (should (equal pharo-smalltalk-last-transcript "hello"))
    (should (equal pharo-smalltalk-last-result 7))))

(ert-deftest pharo-smalltalk-xref-normalizes-class-side-hits ()
  (should
   (equal
    (pharo-smalltalk-xref--normalize-method-hit "CodexTmpIntegration class" "answer")
    '("CodexTmpIntegration" "answer" t)))
  (should
   (equal
    (pharo-smalltalk-xref--normalize-method-hit "CodexTmpIntegration" "value")
    '("CodexTmpIntegration" "value" nil))))

(ert-deftest pharo-smalltalk-xref-apropos-expands-selectors-via-implementors ()
  (cl-letf (((symbol-function 'pharo-smalltalk-search-classes-like)
             (lambda (_pattern) '("CodexTmpIntegration")))
            ((symbol-function 'pharo-smalltalk--request)
             (lambda (endpoint &rest args)
               (pcase endpoint
                 ("/search-methods-like"
                  '((success . t) (result . ("answer"))))
                 ("/search-implementors"
                  (let ((selector (alist-get 'method_name (plist-get args :params) nil nil #'equal)))
                    (if (equal selector "answer")
                        '((success . t)
                          (result . (((class . "CodexTmpIntegration class")
                                      (method . "answer")))))
                      '((success . t) (result . nil)))))
                 (_ '((success . t) (result . nil)))))))
    (let ((items (xref-backend-apropos 'pharo-smalltalk "ans")))
      (should (= (length items) 2))
      (should (member "class CodexTmpIntegration"
                      (mapcar #'xref-item-summary items)))
      (should (member "CodexTmpIntegration class>>answer"
                      (mapcar #'xref-item-summary items))))))

(ert-deftest pharo-smalltalk-capf-cache-invalidates-after-mutation ()
  (let ((pharo-smalltalk-capf--method-cache (make-hash-table :test 'equal))
        (pharo-smalltalk-capf--method-source-cache (make-hash-table :test 'equal)))
    (puthash "foo" (cons '("foo:") (float-time)) pharo-smalltalk-capf--method-cache)
    (puthash '("Class" "foo:" nil) (cons "foo: x" (float-time))
             pharo-smalltalk-capf--method-source-cache)
    (run-hooks 'pharo-smalltalk-after-mutation-hook)
    (should (= (hash-table-count pharo-smalltalk-capf--method-cache) 0))
    (should (= (hash-table-count pharo-smalltalk-capf--method-source-cache) 0))))

(ert-deftest pharo-smalltalk-capf-cache-prunes-oldest-entries ()
  (let ((table (make-hash-table :test 'equal)))
    (puthash "a" (cons 1 10) table)
    (puthash "b" (cons 2 20) table)
    (puthash "c" (cons 3 30) table)
    (pharo-smalltalk-capf--cache-prune table 2)
    (should (= (hash-table-count table) 2))
    (should-not (gethash "a" table))
    (should (gethash "b" table))
    (should (gethash "c" table))))

(ert-deftest pharo-smalltalk-format-transcript-and-result-combines-both ()
  (let ((pharo-smalltalk-last-transcript "hello\n"))
    (should (equal (pharo-smalltalk--format-transcript-and-result 7)
                   "Transcript\n----------\nhello\n\nResult\n------\n7"))))

(ert-deftest pharo-smalltalk-xref-sort-prefers-current-class-and-side ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "CodexTmpIntegration")
    (setq-local pharo-smalltalk-buffer-class-side-p nil)
    (let* ((preferred (pharo-smalltalk-xref--method-ref "CodexTmpIntegration" "value" nil))
           (same-class-class-side (pharo-smalltalk-xref--method-ref "CodexTmpIntegration" "value" t))
           (other-class (pharo-smalltalk-xref--method-ref "OtherClass" "value" nil))
           (sorted (pharo-smalltalk-xref--sort-items
                    (list other-class same-class-class-side preferred))))
      (should (equal (mapcar #'xref-item-summary sorted)
                     '("CodexTmpIntegration>>value"
                       "CodexTmpIntegration class>>value"
                       "OtherClass>>value"))))))

(ert-deftest pharo-smalltalk-xref-sort-prefers-superclass-chain-before-others ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "Child")
    (setq-local pharo-smalltalk-buffer-class-side-p nil)
    (cl-letf (((symbol-function 'pharo-smalltalk-xref--class-lineage)
               (lambda (_class-name) '("Child" "Parent" "Grandparent" "Object"))))
      (let* ((child (pharo-smalltalk-xref--method-ref "Child" "value" nil))
             (parent (pharo-smalltalk-xref--method-ref "Parent" "value" nil))
             (grandparent (pharo-smalltalk-xref--method-ref "Grandparent" "value" nil))
             (other (pharo-smalltalk-xref--method-ref "OtherClass" "value" nil))
             (sorted (pharo-smalltalk-xref--sort-items
                      (list other grandparent parent child))))
        (should (equal (mapcar #'xref-item-summary sorted)
                       '("Child>>value"
                         "Parent>>value"
                         "Grandparent>>value"
                         "OtherClass>>value")))))))

(ert-deftest pharo-smalltalk-xref-group-labels-follow-current-lineage ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "Child")
    (cl-letf (((symbol-function 'pharo-smalltalk-xref--class-lineage)
               (lambda (_class-name) '("Child" "Parent" "Grandparent" "Object"))))
      (should (equal (pharo-smalltalk-xref--group-label "Child") "Current class"))
      (should (equal (pharo-smalltalk-xref--group-label "Parent") "Superclass chain"))
      (should (equal (pharo-smalltalk-xref--group-label "OtherClass") "Other classes")))))

(ert-deftest pharo-smalltalk-xref-method-items-carry-group-metadata ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "Child")
    (cl-letf (((symbol-function 'pharo-smalltalk-xref--class-lineage)
               (lambda (_class-name) '("Child" "Parent" "Object"))))
      (let ((item (pharo-smalltalk-xref--method-ref "Parent" "value" nil)))
        (setf (pharo-smalltalk-xref-method-location-group
               (xref-item-location item))
              (pharo-smalltalk-xref--group-label "Parent"))
        (should (equal (xref-location-group (xref-item-location item))
                       "Superclass chain"))))))

(ert-deftest pharo-smalltalk-xref-class-items-carry-group-metadata ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "Child")
    (cl-letf (((symbol-function 'pharo-smalltalk-xref--class-lineage)
               (lambda (_class-name) '("Child" "Parent" "Object"))))
      (let ((item (pharo-smalltalk-xref--class-definition "Parent")))
        (should (equal (xref-location-group (xref-item-location item))
                       "Superclass chain"))))))

;;;###autoload
(defun pharo-smalltalk-run-ert-tests ()
  "Run the local ERT suite for the Pharo Smalltalk Emacs integration."
  (interactive)
  (ert '(or (tag pharo-smalltalk) t)))

(provide 'pharo-smalltalk-ert)
;;; pharo-smalltalk-ert.el ends here
