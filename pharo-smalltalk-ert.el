;;; pharo-smalltalk-ert.el --- ERT tests for Pharo Smalltalk integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Hermetic ERT suite for the `pharo-smalltalk' bridge.  Stubs out
;; HTTP via `cl-letf' so the suite can run under `emacs --batch'
;; without a live Pharo image.

;;; Code:

(require 'ert)
(require 'xref)
(require 'pharo-smalltalk)
(require 'pharo-smalltalk-xref)
(require 'pharo-smalltalk-capf)
(require 'pharo-smalltalk-test)
(require 'pharo-smalltalk-browser)
(require 'pharo-smalltalk-inspector)
(require 'pharo-smalltalk-transcript)

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
  (let* ((lib (locate-library "pharo-smalltalk"))
         (dir (and lib (file-name-directory lib))))
    (should dir)
    (should (file-exists-p (expand-file-name "CHANGELOG.md" dir)))
    (should (file-exists-p (expand-file-name "LICENSE" dir)))))

(ert-deftest pharo-smalltalk-method-spec-normalizers-work ()
  (let ((hit (pharo-smalltalk-method-spec-from-server-hit
              "DemoClass class" "answer" "accessing")))
    (should (equal (pharo-smalltalk-method-spec-class-name hit) "DemoClass"))
    (should (equal (pharo-smalltalk-method-spec-selector hit) "answer"))
    (should (pharo-smalltalk-method-spec-class-side-p hit))
    (should (equal (pharo-smalltalk-method-spec-category hit) "accessing"))
    (should (equal (pharo-smalltalk-method-spec-key hit)
                   '("DemoClass" "answer" t)))
    (should (equal (pharo-smalltalk-method-spec-display-name hit)
                   "DemoClass class>>answer"))))

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
  (let ((class-side (pharo-smalltalk-xref--normalize-method-hit
                     "CodexTmpIntegration class" "answer"))
        (instance-side (pharo-smalltalk-xref--normalize-method-hit
                        "CodexTmpIntegration" "value")))
    (should (equal (pharo-smalltalk-method-spec-class-name class-side)
                   "CodexTmpIntegration"))
    (should (equal (pharo-smalltalk-method-spec-selector class-side)
                   "answer"))
    (should (pharo-smalltalk-method-spec-class-side-p class-side))
    (should (equal (pharo-smalltalk-method-spec-class-name instance-side)
                   "CodexTmpIntegration"))
    (should (equal (pharo-smalltalk-method-spec-selector instance-side)
                   "value"))
    (should-not (pharo-smalltalk-method-spec-class-side-p instance-side))))

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
        (pharo-smalltalk--method-source-cache (make-hash-table :test 'equal))
        (pharo-smalltalk--class-comment-cache (make-hash-table :test 'equal)))
    (puthash "foo" (cons '("foo:") (float-time)) pharo-smalltalk-capf--method-cache)
    (puthash '("Class" "foo:" nil) (cons "foo: x" (float-time))
             pharo-smalltalk--method-source-cache)
    (puthash "Class" (cons "the comment" (float-time))
             pharo-smalltalk--class-comment-cache)
    (run-hooks 'pharo-smalltalk-after-mutation-hook)
    (should (= (hash-table-count pharo-smalltalk-capf--method-cache) 0))
    (should (= (hash-table-count pharo-smalltalk--method-source-cache) 0))
    (should (= (hash-table-count pharo-smalltalk--class-comment-cache) 0))))

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

(ert-deftest pharo-smalltalk-capf-prefetch-error-does-not-cache-nil ()
  (let ((pharo-smalltalk-capf--method-cache (make-hash-table :test 'equal))
        (pharo-smalltalk-capf--in-flight-prefetch (make-hash-table :test 'equal))
        captured-cb
        (calls 0))
    (cl-letf (((symbol-function 'pharo-smalltalk--request-async)
               (lambda (_endpoint callback &rest _params)
                 (cl-incf calls)
                 (setq captured-cb callback)))
              ((symbol-function 'pharo-smalltalk--warn-once)
               (lambda (&rest _) nil)))
      (should-not (pharo-smalltalk-capf--methods-like "va"))
      (should (= calls 1))
      (funcall captured-cb nil "boom")
      (should-not (gethash "va" pharo-smalltalk-capf--method-cache))
      (should-not (gethash "va" pharo-smalltalk-capf--in-flight-prefetch))
      (should-not (pharo-smalltalk-capf--methods-like "va"))
      (should (= calls 2)))))

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

(ert-deftest pharo-smalltalk-xref-sort-uses-numeric-rank-fields ()
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name nil)
    (let* ((short (pharo-smalltalk-xref--method-ref "OtherClass" "tiny" nil))
           (long (pharo-smalltalk-xref--method-ref
                  "OtherClass"
                  (make-string 120 ?a)
                  nil))
           (sorted (pharo-smalltalk-xref--sort-items (list long short))))
      (should (equal (mapcar #'xref-item-summary sorted)
                     (list "OtherClass>>tiny"
                           (format "OtherClass>>%s" (make-string 120 ?a))))))))

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

(ert-deftest pharo-smalltalk-browser-source-keeps-method-category ()
  (let ((pharo-smalltalk-browser-buffer-name "*Pharo Browser Test*"))
    (cl-letf (((symbol-function 'pharo-smalltalk-get-method-source)
               (lambda (&rest _) "value ^ 1")))
      (unwind-protect
          (progn
            (pharo-smalltalk-browser--render-source
             "DemoClass" "value" 'instance "accessing")
            (with-current-buffer pharo-smalltalk-browser-buffer-name
              (should (equal pharo-smalltalk-buffer-method-category
                             "accessing"))
              (should (equal pharo-smalltalk-browser--current
                             '(source "DemoClass" "value" instance "accessing")))))
        (when (get-buffer pharo-smalltalk-browser-buffer-name)
          (kill-buffer pharo-smalltalk-browser-buffer-name))))))

(ert-deftest pharo-smalltalk-browser-method-rows-use-method-spec-ids ()
  (let ((pharo-smalltalk-browser-buffer-name "*Pharo Browser Test*"))
    (cl-letf (((symbol-function 'pharo-smalltalk--class-protocols)
               (lambda (_class)
                 '((instance . (((category . "accessing")
                                 (methods . ("value")))))
                   (class . nil)))))
      (unwind-protect
          (progn
            (pharo-smalltalk-browser--render-methods "DemoClass" 'instance)
            (with-current-buffer pharo-smalltalk-browser-buffer-name
              (let ((spec (tabulated-list-get-id)))
                (should (pharo-smalltalk-method-spec-p spec))
                (should (equal (pharo-smalltalk-method-spec-class-name spec)
                               "DemoClass"))
                (should (equal (pharo-smalltalk-method-spec-selector spec)
                               "value"))
                (should (equal (pharo-smalltalk-method-spec-category spec)
                               "accessing")))))
        (when (get-buffer pharo-smalltalk-browser-buffer-name)
          (kill-buffer pharo-smalltalk-browser-buffer-name))))))

(ert-deftest pharo-smalltalk-capf-receiver-spec-uses-buffer-context ()
  (with-temp-buffer
    (pharo-smalltalk-mode)
    (setq-local pharo-smalltalk-buffer-class-name "DemoClass")
    (setq-local pharo-smalltalk-buffer-class-side-p t)
    (insert "self value")
    (goto-char (point-max))
    (let ((spec (pharo-smalltalk-capf--receiver-spec
                 (save-excursion
                   (search-backward "value")
                   (point)))))
      (should (pharo-smalltalk-method-spec-p spec))
      (should (equal (pharo-smalltalk-method-spec-class-name spec) "DemoClass"))
      (should (pharo-smalltalk-method-spec-class-side-p spec)))))

(ert-deftest pharo-smalltalk-test-parse-summary-handles-singular-plural ()
  (should
   (equal (pharo-smalltalk-test--parse-summary
           "2 ran, 1 passed, 0 skipped, 0 expected failures, 1 failure, 0 errors")
          '(2 1 0 0 1 0)))
  (should
   (equal (pharo-smalltalk-test--parse-summary
           "5 ran, 3 passed, 0 skipped, 0 expected failures, 2 failures, 0 errors")
          '(5 3 0 0 2 0)))
  (should
   (equal (pharo-smalltalk-test--parse-summary
           "3 ran, 2 passed, 0 skipped, 0 expected failure, 0 failures, 1 error")
          '(3 2 0 0 0 1))))

(ert-deftest pharo-smalltalk-test-rerun-supports-integration ()
  (let ((pharo-smalltalk-test--rerun-args '(integration nil))
        called)
    (cl-letf (((symbol-function 'pharo-smalltalk-test-run-integration)
               (lambda () (setq called t))))
      (pharo-smalltalk-test-rerun)
      (should called))))

(ert-deftest pharo-smalltalk-success-p-handles-json-false ()
  (should (pharo-smalltalk--success-p '((success . t))))
  (should-not (pharo-smalltalk--success-p '((success . :json-false))))
  (should-not (pharo-smalltalk--success-p '((success . :false))))
  (should-not (pharo-smalltalk--success-p '((success . nil))))
  (should-not (pharo-smalltalk--success-p '())))

(ert-deftest pharo-smalltalk-result-signals-on-failure ()
  (let ((pharo-smalltalk-last-response nil)
        (pharo-smalltalk-last-result 'before)
        (pharo-smalltalk-last-transcript "leftover"))
    (should-error
     (pharo-smalltalk--result
      '((success . :json-false)
        (error . ((description . "boom")))
        (transcript . "")))
     :type 'error)
    (should (alist-get 'error pharo-smalltalk-last-response))))

(ert-deftest pharo-smalltalk-list-packages-caches-and-invalidates ()
  (let ((pharo-smalltalk--packages-cache nil)
        (calls 0))
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (&rest _)
                 (cl-incf calls)
                 '((success . t) (result . ("Sis-Core" "Kernel"))))))
      (should (equal (pharo-smalltalk-list-packages) '("Sis-Core" "Kernel")))
      (should (= calls 1))
      (should (equal (pharo-smalltalk-list-packages) '("Sis-Core" "Kernel")))
      (should (= calls 1))
      (should (equal (pharo-smalltalk-list-packages t) '("Sis-Core" "Kernel")))
      (should (= calls 2))
      (run-hooks 'pharo-smalltalk-after-mutation-hook)
      (should (equal (pharo-smalltalk-list-packages) '("Sis-Core" "Kernel")))
      (should (= calls 3)))))

(ert-deftest pharo-smalltalk-list-classes-caches-per-package ()
  (let ((pharo-smalltalk--classes-cache (make-hash-table :test 'equal))
        (calls 0))
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (&rest _)
                 (cl-incf calls)
                 '((success . t) (result . ("Foo" "Bar"))))))
      (pharo-smalltalk-list-classes "P1")
      (pharo-smalltalk-list-classes "P1")
      (should (= calls 1))
      (pharo-smalltalk-list-classes "P2")
      (should (= calls 2))
      (run-hooks 'pharo-smalltalk-after-mutation-hook)
      (pharo-smalltalk-list-classes "P1")
      (should (= calls 3)))))

(ert-deftest pharo-smalltalk-get-method-source-uses-shared-cache ()
  "Repeat fetches must hit the shared TTL cache, and the mutation
hook must clear it."
  (let ((pharo-smalltalk--method-source-cache (make-hash-table :test 'equal))
        (pharo-smalltalk--class-source-cache (make-hash-table :test 'equal))
        (pharo-smalltalk--class-comment-cache (make-hash-table :test 'equal))
        (calls 0))
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (&rest _)
                 (cl-incf calls)
                 '((success . t) (result . "doit ^ 1")))))
      (should (equal (pharo-smalltalk-get-method-source "C" "doit") "doit ^ 1"))
      (should (= calls 1))
      (should (equal (pharo-smalltalk-get-method-source "C" "doit") "doit ^ 1"))
      (should (= calls 1))
      ;; Different side -> different key, recomputes.
      (should (equal (pharo-smalltalk-get-method-source "C" "doit" t) "doit ^ 1"))
      (should (= calls 2))
      ;; Mutation hook clears it.
      (run-hooks 'pharo-smalltalk-after-mutation-hook)
      (should (equal (pharo-smalltalk-get-method-source "C" "doit") "doit ^ 1"))
      (should (= calls 3)))))

(ert-deftest pharo-smalltalk-get-method-source-async-dedups-in-flight ()
  "Two overlapping async fetches for the same key must trigger one HTTP
call and deliver the same result to both waiters."
  (let ((pharo-smalltalk--method-source-cache (make-hash-table :test 'equal))
        (pharo-smalltalk--in-flight-source nil)
        (dispatched 0)
        (received nil)
        captured-cb)
    (cl-letf (((symbol-function 'pharo-smalltalk--request-async)
               (lambda (_ep cb &rest _)
                 (cl-incf dispatched)
                 (setq captured-cb cb))))
      (pharo-smalltalk-get-method-source-async
       "C" "m" nil (lambda (s) (push (cons :a s) received)))
      (pharo-smalltalk-get-method-source-async
       "C" "m" nil (lambda (s) (push (cons :b s) received)))
      (should (= dispatched 1))
      (funcall captured-cb '((success . t) (result . "m ^ 7")) nil)
      (should (equal (sort (mapcar #'car received) #'string<) '(:a :b)))
      (should (cl-every (lambda (e) (equal (cdr e) "m ^ 7")) received)))))

(ert-deftest pharo-smalltalk-get-class-comment-async-dedups-in-flight ()
  "Two overlapping async comment fetches should collapse to one HTTP call."
  (let ((pharo-smalltalk--class-comment-cache (make-hash-table :test 'equal))
        (pharo-smalltalk--in-flight-source nil)
        (dispatched 0)
        (received nil)
        captured-cb)
    (cl-letf (((symbol-function 'pharo-smalltalk--request-async)
               (lambda (_ep cb &rest _)
                 (cl-incf dispatched)
                 (setq captured-cb cb))))
      (pharo-smalltalk-get-class-comment-async
       "C" (lambda (s) (push (cons :a s) received)))
      (pharo-smalltalk-get-class-comment-async
       "C" (lambda (s) (push (cons :b s) received)))
      (should (= dispatched 1))
      (funcall captured-cb '((success . t) (result . "A comment")) nil)
      (should (equal (sort (mapcar #'car received) #'string<) '(:a :b)))
      (should (cl-every (lambda (e) (equal (cdr e) "A comment")) received)))))

(ert-deftest pharo-smalltalk-capf-eldoc-stale-guard-discards-old-replies ()
  "Stale guard returns nil after point moves out of the original
symbol's bounds, or when the text under the bounds has changed."
  (with-temp-buffer
    (pharo-smalltalk-mode)
    (insert "OrderedCollection Other")
    (goto-char 5)                       ; inside `OrderedCollection'
    (let* ((bounds (pharo-smalltalk-capf--symbol-bounds))
           (origin-bounds (cons (car bounds) (cdr bounds)))
           (origin-buffer (current-buffer)))
      (should (pharo-smalltalk-capf--symbol-still-at-point-p
               origin-buffer origin-bounds "OrderedCollection"))
      (goto-char 20)                    ; inside `Other' (point > end)
      (should-not (pharo-smalltalk-capf--symbol-still-at-point-p
                   origin-buffer origin-bounds "OrderedCollection"))
      (goto-char 5)                     ; back inside, but rename the symbol
      (let ((inhibit-read-only t))
        (delete-region (car origin-bounds) (cdr origin-bounds))
        (goto-char (car origin-bounds))
        (insert "RenamedClassName"))
      (should-not (pharo-smalltalk-capf--symbol-still-at-point-p
                   origin-buffer origin-bounds "OrderedCollection")))))

(ert-deftest pharo-smalltalk-screenshot-strategy-respects-override ()
  "An explicit string viewer becomes a shell argv list; `buffer' stays
  `buffer'; `auto' picks `buffer' on GUI and xdg-open/open otherwise."
  (let ((pharo-smalltalk-screenshot-viewer "kitty +kitten icat"))
    (should (equal (pharo-smalltalk--pick-screenshot-strategy)
                   '("kitty" "+kitten" "icat"))))
  (let ((pharo-smalltalk-screenshot-viewer 'buffer))
    (should (eq (pharo-smalltalk--pick-screenshot-strategy) 'buffer)))
  (let ((pharo-smalltalk-screenshot-viewer 'auto))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
      (should (eq (pharo-smalltalk--pick-screenshot-strategy) 'buffer)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
              ((symbol-function 'executable-find)
               (lambda (name)
                 (when (equal name "pharo-show-image")
                   "/home/panjj/.local/bin/pharo-show-image"))))
      (should (equal (pharo-smalltalk--pick-screenshot-strategy)
                     '("pharo-show-image"))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
              ((symbol-function 'executable-find)
               (lambda (name) (when (equal name "xdg-open") "/usr/bin/xdg-open"))))
      (should (equal (pharo-smalltalk--pick-screenshot-strategy)
                     '("xdg-open"))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
              ((symbol-function 'executable-find) (lambda (_) nil)))
      (should (eq (pharo-smalltalk--pick-screenshot-strategy) 'buffer)))))

(ert-deftest pharo-smalltalk-show-screen-dispatches-external-cmd ()
  "When the viewer is a shell command, `--display-screenshot' spawns it
  and does not open a buffer."
  (let ((pharo-smalltalk-screenshot-viewer "imgcat")
        invoked)
    (cl-letf (((symbol-function 'start-process)
               (lambda (_name _buf program &rest args)
                 (setq invoked (cons program args)))))
      (pharo-smalltalk--display-screenshot "/tmp/fake.png")
      (should (equal invoked '("imgcat" "/tmp/fake.png"))))))

(ert-deftest pharo-smalltalk-inspector-render-attaches-row-properties ()
  "Rendering a tree attaches the row alist as a text property on each
line so navigation can recover the ref for drill-down."
  (with-temp-buffer
    (pharo-smalltalk-inspector-mode)
    (pharo-smalltalk-inspector--render
     '((ref . 1) (class . "OrderedCollection")
       (print . "an OrderedCollection(10 20)")
       (identity_hash . 42) (size . 2)
       (inst_vars
        ((name . "firstIndex") (ref . 3) (class . "SmallInteger")
         (print . "1") (has_children . :json-false)))
       (indexable
        ((name . "1") (ref . 5) (class . "SmallInteger")
         (print . "10") (has_children . :json-false))
        ((name . "2") (ref . 6) (class . "SmallInteger")
         (print . "20") (has_children . :json-false)))))
    (goto-char (point-min))
    ;; Header line contains the root print string.
    (should (search-forward "an OrderedCollection(10 20)" nil t))
    ;; Jump to the firstIndex line by text search.
    (goto-char (point-min))
    (should (search-forward "firstIndex" nil t))
    (let ((row (get-text-property (point) 'pharo-smalltalk-inspector-row)))
      (should row)
      (should (equal (alist-get 'ref row) 3))
      (should (equal (alist-get 'class row) "SmallInteger")))
    ;; The second indexable row carries its own ref.
    (goto-char (point-min))
    (should (search-forward "20  (SmallInteger)" nil t))
    (let ((row (get-text-property (point) 'pharo-smalltalk-inspector-row)))
      (should (equal (alist-get 'ref row) 6)))))

(ert-deftest pharo-smalltalk-result-captures-result-tree ()
  "`--result' refreshes `last-result-tree' from the server response."
  (let ((pharo-smalltalk-last-result-tree 'stale)
        (pharo-smalltalk-last-response nil)
        (pharo-smalltalk-last-result nil))
    (pharo-smalltalk--result
     '((success . t) (result . 3)
       (result_tree . ((ref . 1) (class . "SmallInteger") (print . "3")))))
    (should (equal (alist-get 'ref pharo-smalltalk-last-result-tree) 1))
    (should (equal (alist-get 'class pharo-smalltalk-last-result-tree)
                   "SmallInteger"))
    ;; A subsequent call without result_tree clears the stash.
    (pharo-smalltalk--result '((success . t) (result . 7)))
    (should-not pharo-smalltalk-last-result-tree)))

(ert-deftest pharo-smalltalk-eval-passes-inspect-param ()
  "`pharo-smalltalk-eval' only adds inspect=true when the keyword is set."
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (_endpoint &rest kwargs)
                 (setq captured kwargs)
                 '((success . t) (result . 1)))))
      (pharo-smalltalk-eval "1")
      (should-not (plist-get captured :params))
      (pharo-smalltalk-eval "1" :inspect t)
      (should (equal (plist-get captured :params)
                     '((inspect . "true")))))))

(ert-deftest pharo-smalltalk-compile-method-posts-structured-payload ()
  "`pharo-smalltalk-compile-method' should hit /compile-method with the
structured payload and return the `selector' field verbatim."
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (endpoint &rest kwargs)
                 (setq captured (cons endpoint kwargs))
                 '((success . t)
                   (result . ((selector . "doubled:")
                              (class_name . "Demo")
                              (is_class_method . :json-false)
                              (category . "math")))))))
      (should (equal (pharo-smalltalk-compile-method "Demo" "instance" "math"
                                                    "doubled: x\n\t^ x * 2")
                     "doubled:"))
      (should (equal (car captured) "/compile-method"))
      (should (equal (plist-get (cdr captured) :type) "POST"))
      (let ((data (plist-get (cdr captured) :data)))
        (should (equal (alist-get 'class_name data) "Demo"))
        (should (equal (alist-get 'is_class_method data) "false"))
        (should (equal (alist-get 'category data) "math"))
        (should (equal (alist-get 'method_source data)
                       "doubled: x\n\t^ x * 2"))))))

(ert-deftest pharo-smalltalk-compile-method-passes-class-side-flag ()
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (_endpoint &rest kwargs)
                 (setq captured kwargs)
                 '((success . t) (result . ((selector . "answer")))))))
      (pharo-smalltalk-compile-method "Demo" "class" "factory" "answer\n\t^ 42")
      (should (equal (alist-get 'is_class_method (plist-get captured :data))
                     "true")))))

(ert-deftest pharo-smalltalk-compile-method-uses-default-category-when-nil ()
  "Nil CATEGORY should fall back to `pharo-smalltalk-default-method-category'."
  (let ((pharo-smalltalk-default-method-category "custom-default")
        captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (_endpoint &rest kwargs)
                 (setq captured kwargs)
                 '((success . t) (result . ((selector . "answer")))))))
      (pharo-smalltalk-compile-method "Demo" "instance" nil "answer\n\t^ 42")
      (should (equal (alist-get 'category (plist-get captured :data))
                     "custom-default")))))

(ert-deftest pharo-smalltalk-compile-method-surfaces-structured-error-and-transcript ()
  "Compile failures should signal a formatted error while preserving transcript metadata."
  (let ((pharo-smalltalk-last-transcript nil)
        (pharo-smalltalk-last-response nil))
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (_endpoint &rest _kwargs)
                 '((success . :json-false)
                   (transcript . "compile-log")
                   (error . ((description . "OCCodeError: syntax exploded")
                             (line . 2)
                             (column . 9)
                             (location . 16)))))))
      (should-error
       (pharo-smalltalk-compile-method "Demo" "instance" "testing" "broken\n\t^ x @@@")
       :type 'error)
      (should (equal pharo-smalltalk-last-transcript "compile-log"))
      (should (equal (alist-get 'transcript pharo-smalltalk-last-response)
                     "compile-log"))
      (should (equal (alist-get 'line (alist-get 'error pharo-smalltalk-last-response))
                     2)))))

(ert-deftest pharo-smalltalk-compile-class-definition-posts-structured-payload ()
  "Tonel class source is parsed client-side and submitted as structured
JSON; arrays go through as JSON arrays, not Smalltalk string fragments."
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (endpoint &rest kwargs)
                 (setq captured (cons endpoint kwargs))
                 '((success . t) (result . ((class_name . "Demo") (created . t)))))))
      (pharo-smalltalk-compile-class-definition
       "Class {\n\t#name : 'Demo',\n\t#superclass : 'Object',\n\t#instVars : [ 'a' 'b' ],\n\t#package : 'Codex-Demo'\n}")
      (should (equal (car captured) "/compile-class"))
      (let ((data (plist-get (cdr captured) :data)))
        (should (equal (alist-get 'class_name data) "Demo"))
        (should (equal (alist-get 'superclass data) "Object"))
        (should (equal (alist-get 'package data) "Codex-Demo"))
        (should (equal (alist-get 'inst_vars data) ["a" "b"]))
        (should (vectorp (alist-get 'class_vars data)))))))

(ert-deftest pharo-smalltalk-remove-method-posts-structured-payload ()
  "Removing a method should POST to /remove-method and return the server result."
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (endpoint &rest kwargs)
                 (setq captured (cons endpoint kwargs))
                 '((success . t)
                   (result . ((class_name . "Demo")
                              (selector . "answer")
                              (is_class_method . t)
                              (existed . t)
                              (removed . t)))))))
      (should (equal (alist-get 'removed
                                (pharo-smalltalk-remove-method "Demo" "answer" t))
                     t))
      (should (equal (car captured) "/remove-method"))
      (let ((data (plist-get (cdr captured) :data)))
        (should (equal (alist-get 'class_name data) "Demo"))
        (should (equal (alist-get 'selector data) "answer"))
        (should (equal (alist-get 'is_class_method data) "true"))))))

(ert-deftest pharo-smalltalk-remove-class-posts-structured-payload ()
  "Removing a class should POST to /remove-class and return the server result."
  (let (captured)
    (cl-letf (((symbol-function 'pharo-smalltalk--request)
               (lambda (endpoint &rest kwargs)
                 (setq captured (cons endpoint kwargs))
                 '((success . t)
                   (result . ((class_name . "Demo")
                              (existed . :json-false)
                              (removed . :json-false)))))))
      (should (eq (alist-get 'removed (pharo-smalltalk-remove-class "Demo"))
                  :json-false))
      (should (equal (car captured) "/remove-class"))
      (let ((data (plist-get (cdr captured) :data)))
        (should (equal (alist-get 'class_name data) "Demo"))))))

(ert-deftest pharo-smalltalk-remove-current-method-uses-buffer-metadata ()
  "Method source buffers should remove the selector parsed from the buffer."
  (with-temp-buffer
    (insert "answer\n\t^ 42")
    (setq-local pharo-smalltalk-buffer-source-kind 'method)
    (setq-local pharo-smalltalk-buffer-class-name "Demo")
    (setq-local pharo-smalltalk-buffer-class-side-p t)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'pharo-smalltalk-remove-method)
               (lambda (class selector class-side-p)
                 (should (equal class "Demo"))
                 (should (equal selector "answer"))
                 (should class-side-p)
                 'ok)))
      (should (equal (pharo-smalltalk-remove-current-method) 'ok)))))

(ert-deftest pharo-smalltalk-remove-current-class-uses-buffer-metadata ()
  "Class source buffers should remove the current target class."
  (with-temp-buffer
    (setq-local pharo-smalltalk-buffer-class-name "Demo")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'pharo-smalltalk-remove-class)
               (lambda (class-name)
                 (should (equal class-name "Demo"))
                 'ok)))
      (should (equal (pharo-smalltalk-remove-current-class) 'ok)))))

(ert-deftest pharo-smalltalk-transcript-append-writes-text-and-seq ()
  "Appending a payload inserts its text, advances the seq cursor, and
emits a drop notice when the server reports dropped entries."
  (with-temp-buffer
    (pharo-smalltalk-transcript-mode)
    (pharo-smalltalk-transcript--stop-timer) ; don't fight the timer in ERT
    (pharo-smalltalk-transcript--append
     (current-buffer)
     '((seq . 3) (text . "hello\rworld\r") (dropped . 0)))
    (should (equal pharo-smalltalk-transcript--seq 3))
    (should (string-match-p "hello\nworld\n" (buffer-string)))
    (pharo-smalltalk-transcript--append
     (current-buffer)
     '((seq . 9) (text . "more\r") (dropped . 5)))
    (should (equal pharo-smalltalk-transcript--seq 9))
    (should (string-match-p "5 transcript entries dropped" (buffer-string)))
    (should (string-match-p "more\n" (buffer-string)))))

(ert-deftest pharo-smalltalk-transcript-append-ignores-dead-buffer ()
  "Callbacks that fire after the buffer is killed must not signal."
  (let ((buf (generate-new-buffer " *ert-transcript*")))
    (with-current-buffer buf (pharo-smalltalk-transcript-mode))
    (kill-buffer buf)
    (pharo-smalltalk-transcript--append buf '((seq . 1) (text . "x") (dropped . 0)))
    ;; No error raised is the assertion.
    (should t)))

(ert-deftest pharo-smalltalk-transcript-poll-once-uses-seq-and-appends-result ()
  "Polling should send the current cursor and append the decoded payload."
  (with-temp-buffer
    (pharo-smalltalk-transcript-mode)
    (pharo-smalltalk-transcript--stop-timer)
    (setq pharo-smalltalk-transcript--seq 4)
    (let (captured-callback captured-params)
      (cl-letf (((symbol-function 'pharo-smalltalk--request-async)
                 (lambda (_endpoint callback &rest kwargs)
                   (setq captured-callback callback
                         captured-params (plist-get kwargs :params))
                   'dispatched)))
        (should (eq (pharo-smalltalk-transcript--poll-once (current-buffer)) t))
        (should (equal captured-params '((since . "4"))))
        (funcall captured-callback '((success . t)
                                     (result . ((seq . 6)
                                                (text . "abc\r")
                                                (dropped . 0))))
                 nil)
        (should (equal pharo-smalltalk-transcript--seq 6))
        (should (string-match-p "abc\n" (buffer-string)))
        (should-not pharo-smalltalk-transcript--inflight)))))

(ert-deftest pharo-smalltalk-transcript-poll-once-skips-when-inflight ()
  "Polling again while a request is in flight should be a no-op."
  (with-temp-buffer
    (pharo-smalltalk-transcript-mode)
    (pharo-smalltalk-transcript--stop-timer)
    (setq pharo-smalltalk-transcript--inflight t)
    (cl-letf (((symbol-function 'pharo-smalltalk--request-async)
               (lambda (&rest _)
                 (should nil)
                 'unexpected)))
      (should-not (pharo-smalltalk-transcript--poll-once (current-buffer))))))

(ert-deftest pharo-smalltalk-inspector-drill-pushes-stack ()
  "Drilling from one view stashes the previous tree on the back stack."
  (with-temp-buffer
    (pharo-smalltalk-inspector-mode)
    (let ((parent '((ref . 1) (class . "C") (print . "root")
                    (inst_vars ((name . "f") (ref . 2) (class . "SmallInteger")
                                (print . "1") (has_children . :json-false)))
                    (indexable)))
          (child '((ref . 2) (class . "SmallInteger") (print . "1")
                   (inst_vars) (indexable))))
      (cl-letf (((symbol-function 'pharo-smalltalk-inspector--fetch-ref)
                 (lambda (ref) (should (equal ref 2)) child)))
        (pharo-smalltalk-inspector--render parent)
        (goto-char (point-min))
        (search-forward "f = 1")
        (pharo-smalltalk-inspector-drill)
        (should (equal (alist-get 'ref pharo-smalltalk-inspector--current) 2))
        (should (equal (length pharo-smalltalk-inspector--stack) 1))
        (pharo-smalltalk-inspector-back)
        (should (equal (alist-get 'ref pharo-smalltalk-inspector--current) 1))
        (should (equal pharo-smalltalk-inspector--stack nil))))))

(ert-deftest pharo-smalltalk-capf-eldoc-deliver-releases-empty ()
  "An empty async response must still call eldoc CALLBACK with nil
so the eldoc machinery doesn't keep showing stale text."
  (let (received)
    (pharo-smalltalk-capf--eldoc-deliver
     (lambda (text &rest _) (push text received)) nil)
    (pharo-smalltalk-capf--eldoc-deliver
     (lambda (text &rest _) (push text received))
     '("hello" :thing "X"))
    (should (equal received '("hello" nil)))))

(ert-deftest pharo-smalltalk-warn-once-throttles-by-key ()
  (let ((pharo-smalltalk--warn-suppress (make-hash-table :test 'equal))
        (pharo-smalltalk-warn-once-interval 60)
        captured)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) captured))))
      (pharo-smalltalk--warn-once 'k1 "first %s" "x")
      (pharo-smalltalk--warn-once 'k1 "second %s" "y")
      (pharo-smalltalk--warn-once 'k2 "diff key"))
    (should (= (length captured) 2))
    (should (member "[pharo-smalltalk] first x" captured))
    (should (member "[pharo-smalltalk] diff key" captured))
    (should-not (member "[pharo-smalltalk] second y" captured))))

(ert-deftest pharo-smalltalk-action-buffer-name-is-distinct ()
  (should (equal (pharo-smalltalk--action-buffer-name "search-implementors")
                 "*Pharo search-implementors*"))
  (should-not (equal (pharo-smalltalk--action-buffer-name "search-implementors")
                     (pharo-smalltalk--action-buffer-name "search-references"))))

;;;###autoload
(defun pharo-smalltalk-run-ert-tests ()
  "Run the local ERT suite for the Pharo Smalltalk Emacs integration."
  (interactive)
  (ert '(or (tag pharo-smalltalk) t)))

(provide 'pharo-smalltalk-ert)
;;; pharo-smalltalk-ert.el ends here
