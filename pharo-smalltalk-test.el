;;; pharo-smalltalk-test.el --- Test runner for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs Pharo TestCase classes and packages through the bridge and
;; renders the parsed summary in a `*Pharo Tests*' buffer.  Also
;; offers `pharo-smalltalk-test-run-smoke' and
;; `pharo-smalltalk-test-run-integration' for fixed live checks against
;; the running interop server.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-test nil
  "Test runner integration for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-test-buffer-name "*Pharo Tests*"
  "Buffer name used to display test results."
  :type 'string
  :group 'pharo-smalltalk-test)

(defvar-local pharo-smalltalk-test--rerun-args nil
  "List of (KIND NAME) used to rerun tests with `g'.")

(defface pharo-smalltalk-test-pass-face
  '((t :foreground "#5fd75f" :weight bold))
  "Face for passing test totals.")

(defface pharo-smalltalk-test-fail-face
  '((t :foreground "#ff5f5f" :weight bold))
  "Face for failing test totals.")

(defun pharo-smalltalk-test--parse-summary (text)
  "Extract (ran passed skipped expected-failures failures errors) from TEXT.
Pharo pluralizes its summary tokens, so each label is matched as either
its singular or plural form (e.g., `1 failure' vs `2 failures')."
  (when (string-match
         (concat "\\([0-9]+\\) ran, "
                 "\\([0-9]+\\) passed, "
                 "\\([0-9]+\\) skipped, "
                 "\\([0-9]+\\) expected failures?, "
                 "\\([0-9]+\\) failures?, "
                 "\\([0-9]+\\) errors?")
         text)
    (mapcar #'string-to-number
            (list (match-string 1 text) (match-string 2 text)
                  (match-string 3 text) (match-string 4 text)
                  (match-string 5 text) (match-string 6 text)))))

(defvar pharo-smalltalk-test-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'pharo-smalltalk-test-rerun)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "c") #'pharo-smalltalk-test-run-class)
    (define-key map (kbd "p") #'pharo-smalltalk-test-run-package)
    (define-key map (kbd "s") #'pharo-smalltalk-test-run-smoke)
    (define-key map (kbd "i") #'pharo-smalltalk-test-run-integration)
    map)
  "Keymap for `pharo-smalltalk-test-mode'.")

(define-derived-mode pharo-smalltalk-test-mode special-mode "Pharo-Tests"
  "Mode for Pharo test results."
  (setq truncate-lines nil))

(defun pharo-smalltalk-test--render (kind name result)
  "Render RESULT of running KIND (class/package) NAME into the test buffer."
  (let ((buf (get-buffer-create pharo-smalltalk-test-buffer-name))
        (counts (pharo-smalltalk-test--parse-summary (or result ""))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pharo-smalltalk-test-mode)
        (setq pharo-smalltalk-test--rerun-args (list kind name))
        (insert (propertize (format "Pharo tests — %s %s\n"
                                    (capitalize (symbol-name kind)) name)
                            'face 'bold))
        (insert (format "Ran at %s\n\n" (current-time-string)))
        (when counts
          (cl-destructuring-bind (ran passed skipped efail fail err) counts
            (let ((ok (and (zerop fail) (zerop err))))
              (insert (propertize
                       (format "%d ran · %d passed · %d skipped · %d expected-fail · %d failures · %d errors\n\n"
                               ran passed skipped efail fail err)
                       'face (if ok 'pharo-smalltalk-test-pass-face
                               'pharo-smalltalk-test-fail-face))))))
        (insert "Raw output\n----------\n")
        (insert (or result "(no output)") "\n")
        (goto-char (point-min))))
    (display-buffer buf)))

(defun pharo-smalltalk-test--smoke-checks ()
  "Run a small fixed set of live integration checks."
  (let ((checks
         (list
          (cons "ping"
                (lambda () (equal (pharo-smalltalk-ping) 42)))
          (cons "eval"
                (lambda () (equal (pharo-smalltalk-eval "3 + 4") 7)))
          (cons "transcript"
                (lambda ()
                  (stringp
                   (pharo-smalltalk-eval
                    "Transcript show: 'Smoke'; cr."))))
          (cons "class-source"
                (lambda ()
                  (string-match-p
                   "\\`Class[[:space:]]*{"
                   (pharo-smalltalk-get-class-source "SisServer"))))
          (cons "method-source"
                (lambda ()
                  (string-match-p
                   "\\`handleEval:"
                   (pharo-smalltalk-get-method-source
                    "SisServer" "handleEval:"))))))
        results)
    (dolist (check checks)
      (let ((name (car check))
            (fn (cdr check)))
        (push (list name
                    (condition-case err
                        (if (funcall fn) 'pass 'fail)
                      (error (error-message-string err))))
              results)))
    (nreverse results)))

(defun pharo-smalltalk-test--integration-checks ()
  "Run a higher-level live integration suite against the current bridge."
  (let ((class-name "CodexTmpIntegration")
        results)
    (unwind-protect
        (progn
          (push (list "class-compile"
                      (condition-case err
                          (if (equal (pharo-smalltalk-compile-class-definition
                                      "Class {\n\t#name : 'CodexTmpIntegration',\n\t#superclass : 'Object',\n\t#instVars : [ 'value' ],\n\t#category : 'Codex-Integration'\n}")
                                     class-name)
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results)
          (push (list "instance-method"
                      (condition-case err
                          (if (equal (pharo-smalltalk-compile-method
                                      class-name "instance" "accessing"
                                      "value\n\t^ value ifNil: [ 0 ]")
                                     "value")
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results)
          (push (list "class-method"
                      (condition-case err
                          (if (equal (pharo-smalltalk-compile-method
                                      class-name "class" "instance creation"
                                      "answer\n\t^ 42")
                                     "answer")
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results)
          (push (list "instance-call"
                      (condition-case err
                          (if (equal (pharo-smalltalk-eval
                                      "CodexTmpIntegration new value")
                                     0)
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results)
          (push (list "class-call"
                      (condition-case err
                          (if (equal (pharo-smalltalk-eval
                                      "CodexTmpIntegration answer")
                                     42)
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results)
          (push (list "source-roundtrip"
                      (condition-case err
                          (if (string-match-p
                               "\\`answer"
                               (pharo-smalltalk-get-method-source
                                class-name "answer" t))
                              'pass
                            'fail)
                        (error (error-message-string err))))
                results))
      (ignore-errors
        (pharo-smalltalk-eval
         "Smalltalk globals removeKey: #CodexTmpIntegration ifAbsent: [ ]. 'ok'")))
    (nreverse results)))

(defun pharo-smalltalk-test--render-smoke (results)
  "Render smoke RESULTS in the test buffer."
  (let ((buf (get-buffer-create pharo-smalltalk-test-buffer-name))
        (passed 0)
        (failed 0))
    (dolist (entry results)
      (if (eq (cadr entry) 'pass)
          (setq passed (1+ passed))
        (setq failed (1+ failed))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pharo-smalltalk-test-mode)
        (setq pharo-smalltalk-test--rerun-args '(smoke nil))
        (insert (propertize "Pharo tests — Smoke\n" 'face 'bold))
        (insert (format "Ran at %s\n\n" (current-time-string)))
        (insert (propertize
                 (format "%d checks · %d passed · %d failed\n\n"
                         (+ passed failed) passed failed)
                 'face (if (zerop failed)
                           'pharo-smalltalk-test-pass-face
                         'pharo-smalltalk-test-fail-face)))
        (insert "Checks\n------\n")
        (dolist (entry results)
          (pcase-let ((`(,name ,status) entry))
            (insert (format "%-16s %s\n"
                            name
                            (if (eq status 'pass) "PASS" status)))))
        (goto-char (point-min))))
    (display-buffer buf)))

;;;###autoload
(defun pharo-smalltalk-test-run-class (class-name)
  "Run TestCase CLASS-NAME and show results."
  (interactive
   (list (pharo-smalltalk--read-class-name
          "Test class: "
          (or pharo-smalltalk-buffer-class-name
              (and (pharo-smalltalk--class-name-at-point))))))
  (message "Running %s tests..." class-name)
  (let ((result (pharo-smalltalk--result
                 (pharo-smalltalk--request "/run-class-test"
                                           :params `((class_name . ,class-name))))))
    (pharo-smalltalk-test--render 'class class-name result)))

;;;###autoload
(defun pharo-smalltalk-test-run-package (package-name)
  "Run all tests in PACKAGE-NAME and show results."
  (interactive
   (list (let ((candidates (condition-case nil
                               (pharo-smalltalk-list-packages)
                             (error nil))))
           (if candidates
               (completing-read "Test package: " candidates nil 'confirm)
             (read-string "Test package: ")))))
  (message "Running %s tests..." package-name)
  (let ((result (pharo-smalltalk--result
                 (pharo-smalltalk--request "/run-package-test"
                                           :params `((package_name . ,package-name))))))
    (pharo-smalltalk-test--render 'package package-name result)))

;;;###autoload
(defun pharo-smalltalk-test-rerun ()
  "Re-run the last displayed test target."
  (interactive)
  (pcase pharo-smalltalk-test--rerun-args
    (`(class ,name) (pharo-smalltalk-test-run-class name))
    (`(package ,name) (pharo-smalltalk-test-run-package name))
    (`(smoke nil) (pharo-smalltalk-test-run-smoke))
    (`(integration nil) (pharo-smalltalk-test-run-integration))
    (_ (user-error "No previous Pharo test run to rerun"))))

;;;###autoload
(defun pharo-smalltalk-test-run-smoke ()
  "Run a fixed live smoke test suite against the current Pharo bridge."
  (interactive)
  (message "Running Pharo smoke tests...")
  (pharo-smalltalk-test--render-smoke
   (pharo-smalltalk-test--smoke-checks)))

;;;###autoload
(defun pharo-smalltalk-test-run-integration ()
  "Run a higher-level live integration suite against the current bridge."
  (interactive)
  (message "Running Pharo integration tests...")
  (let ((results (pharo-smalltalk-test--integration-checks)))
    (with-current-buffer (get-buffer-create pharo-smalltalk-test-buffer-name)
      (setq pharo-smalltalk-test--rerun-args '(integration nil)))
    (pharo-smalltalk-test--render-smoke results)))

(provide 'pharo-smalltalk-test)
;;; pharo-smalltalk-test.el ends here
