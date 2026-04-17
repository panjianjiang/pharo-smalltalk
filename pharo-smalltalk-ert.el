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
