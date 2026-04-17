;;; pharo-smalltalk-transcript.el --- Live Transcript buffer for Pharo Smalltalk -*- lexical-binding: t; -*-

;;; Commentary:

;; Opens a buffer that tails the Pharo image's Transcript in real time
;; by polling the `/transcript/poll' endpoint asynchronously.  Catches
;; output from background processes, Morphic `step' methods, event
;; callbacks — anything that writes to Transcript outside a single
;; `/eval' round-trip.
;;
;; Entry point: `pharo-smalltalk-transcript-open' (bound to `C-c s o'
;; when the package prefix is installed).  Inside the buffer:
;;
;;   g — force a poll right now
;;   c — clear both the buffer and the server-side tee
;;   t — toggle auto-follow (pause / resume polling)
;;   q — quit the window (also stops the timer)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pharo-smalltalk)

(defgroup pharo-smalltalk-transcript nil
  "Live Transcript tail for Pharo Smalltalk."
  :group 'pharo-smalltalk)

(defcustom pharo-smalltalk-transcript-buffer-name "*Pharo Transcript*"
  "Buffer name used for the live Transcript tail."
  :type 'string
  :group 'pharo-smalltalk-transcript)

(defcustom pharo-smalltalk-transcript-poll-interval 1.0
  "Seconds between automatic polls of `/transcript/poll' when following.
Polling is asynchronous, so a slower cadence is mostly a tradeoff in
latency rather than responsiveness."
  :type 'number
  :group 'pharo-smalltalk-transcript)

(defface pharo-smalltalk-transcript-dropped-face
  '((t :inherit shadow :slant italic))
  "Face for the drop-notice line inserted when the server-side ring
  buffer wrapped past our last-seen sequence."
  :group 'pharo-smalltalk-transcript)

(defvar-local pharo-smalltalk-transcript--seq 0
  "Last sequence cursor acknowledged by the server.")

(defvar-local pharo-smalltalk-transcript--timer nil
  "Active poll timer, or nil when following is paused or quit.")

(defvar-local pharo-smalltalk-transcript--inflight nil
  "Non-nil while an async poll is in flight; suppresses overlapping requests.")

(defvar-local pharo-smalltalk-transcript--follow t
  "When non-nil, the poll timer is running; toggled by `t'.")

(defun pharo-smalltalk-transcript--append (buffer payload)
  "Append PAYLOAD's text into BUFFER and advance the sequence cursor.
PAYLOAD is the decoded alist from `/transcript/poll'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((text (alist-get 'text payload))
            (newseq (alist-get 'seq payload))
            (dropped (alist-get 'dropped payload))
            (inhibit-read-only t)
            (at-end (eobp)))
        (when (and (integerp dropped) (> dropped 0))
          (goto-char (point-max))
          (insert (propertize (format "[… %d transcript entries dropped …]\n" dropped)
                              'face 'pharo-smalltalk-transcript-dropped-face)))
        (when (and text (stringp text) (> (length text) 0))
          (goto-char (point-max))
          (insert (pharo-smalltalk--normalize-newlines text))
          (when at-end
            (dolist (win (get-buffer-window-list buffer nil t))
              (set-window-point win (point-max)))))
        (when (integerp newseq)
          (setq pharo-smalltalk-transcript--seq newseq))))))

(defun pharo-smalltalk-transcript--poll-once (&optional buffer)
  "Dispatch one async poll for BUFFER (defaults to the transcript buffer).
Returns t when a request was sent, nil when one was already in flight."
  (let ((buf (or buffer (get-buffer pharo-smalltalk-transcript-buffer-name))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (cond
         (pharo-smalltalk-transcript--inflight nil)
         (t
          (setq pharo-smalltalk-transcript--inflight t)
          (let ((seq pharo-smalltalk-transcript--seq))
            (pharo-smalltalk--request-async
             "/transcript/poll"
             (pharo-smalltalk--unwrap-async
              (lambda (result error)
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (setq pharo-smalltalk-transcript--inflight nil))
                  (cond
                   (error
                    (pharo-smalltalk--warn-once
                     'transcript-poll
                     "transcript poll failed: %s" error))
                   (result
                    (pharo-smalltalk-transcript--append buf result))))))
             :params `((since . ,(number-to-string seq)))))
          t))))))

(defun pharo-smalltalk-transcript-refresh ()
  "Force an immediate poll without waiting for the timer."
  (interactive)
  (pharo-smalltalk-transcript--poll-once))

(defun pharo-smalltalk-transcript-clear ()
  "Clear both the buffer and the server-side transcript tee."
  (interactive)
  (pharo-smalltalk--result
   (pharo-smalltalk--request "/transcript/clear" :type "POST"))
  (setq pharo-smalltalk-transcript--seq 0)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (message "Pharo transcript cleared"))

(defun pharo-smalltalk-transcript--start-timer ()
  "Start the poll timer if it isn't already running."
  (unless (timerp pharo-smalltalk-transcript--timer)
    (setq pharo-smalltalk-transcript--timer
          (run-at-time 0
                       pharo-smalltalk-transcript-poll-interval
                       #'pharo-smalltalk-transcript--poll-once
                       (current-buffer)))))

(defun pharo-smalltalk-transcript--stop-timer ()
  "Stop the poll timer if it is running."
  (when (timerp pharo-smalltalk-transcript--timer)
    (cancel-timer pharo-smalltalk-transcript--timer)
    (setq pharo-smalltalk-transcript--timer nil)))

(defun pharo-smalltalk-transcript-toggle-follow ()
  "Pause or resume automatic polling."
  (interactive)
  (setq pharo-smalltalk-transcript--follow
        (not pharo-smalltalk-transcript--follow))
  (if pharo-smalltalk-transcript--follow
      (progn (pharo-smalltalk-transcript--start-timer)
             (message "Pharo transcript: following (every %.1fs)"
                      pharo-smalltalk-transcript-poll-interval))
    (pharo-smalltalk-transcript--stop-timer)
    (message "Pharo transcript: paused (press t to resume)")))

(defvar pharo-smalltalk-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'pharo-smalltalk-transcript-refresh)
    (define-key map (kbd "c") #'pharo-smalltalk-transcript-clear)
    (define-key map (kbd "t") #'pharo-smalltalk-transcript-toggle-follow)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `pharo-smalltalk-transcript-mode'.")

(define-derived-mode pharo-smalltalk-transcript-mode special-mode "Pharo-Transcript"
  "Major mode tailing the Pharo image's Transcript in real time."
  (setq truncate-lines nil)
  (setq pharo-smalltalk-transcript--seq 0)
  (setq pharo-smalltalk-transcript--inflight nil)
  (setq pharo-smalltalk-transcript--follow t)
  (pharo-smalltalk-transcript--start-timer)
  (add-hook 'kill-buffer-hook #'pharo-smalltalk-transcript--stop-timer nil t))

;;;###autoload
(defun pharo-smalltalk-transcript-open ()
  "Open the live Pharo Transcript buffer and start following."
  (interactive)
  (let ((buf (get-buffer-create pharo-smalltalk-transcript-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'pharo-smalltalk-transcript-mode)
        (pharo-smalltalk-transcript-mode)))
    (pop-to-buffer buf)))

(provide 'pharo-smalltalk-transcript)
;;; pharo-smalltalk-transcript.el ends here
