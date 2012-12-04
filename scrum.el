;;; scrum.el --- Helper functions for scrum planning and reporting

;; Copyright (C) 2012 Ian Martins

;; Version: 0.0.1
;; Keywords: scrum burndown
;; Author: Ian Martins <ianxm@jhu.edu>
;; URL: http://github.com/ianxm/emacs-scrum

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Commentary

;; provides functions that extend org-mode which allow it to generate
;; some reports.

(require 'cl)
(require 'gnuplot)

(defun get-developers ()
  "get list of developer (name . wpd)"
  (let (ret)
    (setq ret (org-entry-properties (point) 'standard))
    (setq ret (remove-if (lambda (ii)                  ;; filter out non-developer properties
                           (or 
                            (< (length (car ii)) 5)
                            (not (string= (substring (car ii) 0 4) "wpd-"))))
                         ret))
    (setq ret (mapcar (function (lambda (ii) (cons     ;; remove the 'wpd-' prefix to get the name
                                              (substring (car ii) 4 (length (car ii)))
                                              (string-to-number (cdr ii)))))
                      ret))
    ret))

(defun get-prop-value (match prop)
  "sum property values for given match"
  (let ((val 0)
        ret)
    (setq ret (org-map-entries (lambda () (org-entry-get (point) prop)) match))
    (setq ret (remove-if (lambda (ii) (= (length ii) 0)) ret))
    (while ret 
      (setq val (+ val (string-to-number (pop ret)))))
    val))

(defun get-finish-date (hours wpd)
  "count off the days to get the work done, skipping weekends"
  (let ((ret (current-time))
        (hoursleft hours)
        ctime)
    (while (> hoursleft 0)
      (setq ret (time-add ret (seconds-to-time 86400)))
      (setq ctime (decode-time ret))
      (if (and (> (nth 6 ctime) 0) (< (nth 6 ctime) 6))
          (setq hoursleft (- hoursleft wpd))))
    ret))

(defun get-work-left (cdate closed tot)
  "get the actual work todo for the date cdate"
  (let (toremove)
    (dolist (item closed)
      ;; (message "item %s" (format-time-string "%Y-%m-%d %H:%M:%S" (car item)))
      (unless (time-less-p cdate (nth 0 item))
        (setq tot (- tot (nth 1 item)))
        (push item toremove)))
    (cons toremove tot)))

(defun draw-progress-bar (est done)
  "draw a progress bar in the summary table"
  (let ((width 10)
        (blocksdone 5))
    (setq blocksdone (round (* (/ (* done 1.0) est) width)))
    (concat
     (apply 'concat (make-list blocksdone "#"))
     (apply 'concat (make-list (- width blocksdone) "-")))))

(defun org-dblock-write:block-update-summary (params)
  "generate scrum summary table"
  (let ((developers nil)
        (est  0)                ;; hours estimated
        (act  0)                ;; actual hours spent
        (done 0)                ;; hours of estimates that are done
        (rem  0))               ;; hours of estimates that are left
    (setq developers (car (org-map-entries 'get-developers "ID=\"TASKS\"")))
    (if (= 0 (length developers))
        (error "no developers found (they must have WPD property)"))
    (insert "| NAME | ESTIMATED | ACTUAL | DONE | REMAINING | PENCILS DOWN | PROGRESS |\n|-")
    (dolist (developer developers)
      (setq est  (get-prop-value (concat "OWNER={^" (car developer) ".*}") "ESTIMATED"))
      (setq act  (get-prop-value (concat "OWNER={^" (car developer) ".*}") "ACTUAL"))
      (setq done (get-prop-value (concat "OWNER={^" (car developer) ".*}+TODO=\"DONE\"") "ESTIMATED"))
      (setq rem  (get-prop-value (concat "OWNER={^" (car developer) ".*}+TODO=\"TODO\"|" "OWNER={^" (car developer) ".*}+TODO=\"STARTED\"") "ESTIMATED"))

      (insert "\n| " (car developer)
              " | " (number-to-string est)
              " | " (number-to-string act)
              " | " (number-to-string done)
              " | " (number-to-string rem)
              " | " (format-time-string "%Y-%m-%d" (get-finish-date rem (cdr developer)))
              " | " (draw-progress-bar est done)
              " |"))
    (org-ctrl-c-ctrl-c)))

(defun org-dblock-write:block-update-burndown (params)
  "generate burndown table"
  (insert "| DAY | DATE | IDEAL | ACTUAL | TASKS COMPLETED |\n|-")
  (let ((day 1)               ;; day index
        (today (current-time))
        tot                   ;; total hours of estimates
        totleft               ;; total left
        sprintlength          ;; number of calendar days in the sprint
        closed                ;; list of (date est num) for each task that was completed
        toremove              ;; list of (date est num) for each task that has been counted and can be removed
        cdate)                ;; current date for iterating

    (setq tot (get-prop-value nil "ESTIMATED"))
    (setq totleft tot)
    (org-map-entries (lambda ()
                       (setq cdate (apply 'encode-time (org-fix-decoded-time (parse-time-string (org-entry-get (point) "SPRINTSTART")))))
                       (setq sprintlength (string-to-number (org-entry-get (point) "SPRINTLENGTH")))) "ID=\"TASKS\"")
    (if (or (null cdate) (null sprintlength))
        (error "couldn't find node with ID=\"TASKS\" containing \"SPRINTLENGTH\" and \"SPRINTSTART\" properties"))
    (setq closed (org-map-entries (lambda ()
                                    (let ((closetime (parse-time-string (org-entry-get (point) "CLOSED")))
                                          (n 0))
                                      (setq closetime (mapcar (function (lambda (x) (if (< (setq n (1+ n)) 4) 0 x))) closetime)) ;; clear time of day
                                      (list
                                       (apply 'encode-time closetime)
                                       (string-to-number (org-entry-get (point) "ESTIMATED"))
                                       (org-entry-get (point) "TASKID"))))
                                  "TODO=\"DONE\""))
    (while (<= day sprintlength)
      ;; (message "cdate %d %s" day (format-time-string "%Y-%m-%d %H:%M:%S" cdate))
      (setq cdate (time-add cdate (seconds-to-time 86400))) ;; increment current day
      (setq toremove nil)
      (insert "\n| " (number-to-string day)
              " | " (format-time-string "%Y-%m-%d" cdate)
              " | " (number-to-string (round (- totleft (* totleft (/ day (* 1.0 sprintlength))))))
              " | " (if (time-less-p cdate today)
                      (let ((ret (get-work-left cdate closed tot)))
                        (setq toremove (car ret))                   ;; save list of completed tasks
                        (setq tot (cdr ret))                        ;; save new total
                        (if (not (null toremove))                   ;; remove completed from master list
                            (dolist (item toremove)
                              (setq closed (delq item closed))))
                        (number-to-string tot))
                      "")
              " | " (mapconcat (function (lambda (ii) (nth 2 ii))) toremove " ")
              " | " )
      (setq day (1+ day)))
    (org-ctrl-c-ctrl-c))
)

(defun org-dblock-write:block-update-graph (params)
  "generate burndown chart"
  (save-excursion
    (let ((fname "burndown.plt")
          pt found)
      (goto-char (point-min))
      (setq found (re-search-forward "#\\+PLOT: title:\"Burndown\".*" nil t))
      (if (not found)
          (error "PLOT block not found"))
      (org-plot/gnuplot)
      (when (file-exists-p fname)
        (goto-char (point-min))
        (re-search-forward "#\\+BEGIN: .*block-update-graph")   ;; must exist
        (forward-line 1)              ;; move into dynamic block
        (setq pt (point))
        (insert-file-contents fname)
        (delete-file fname)           ;; del temp file
        (delete-char 1)               ;; form feed
        (while (not (looking-at "#\\+END"))
          (insert "'")
          (forward-line 1))
        (save-restriction
          (narrow-to-region pt (point))
          (goto-char pt)
          (while (re-search-forward "\*" nil t)
            (replace-match "\.")))))))

(defun scrum-update ()
  "update dynamic blocks in a scrum org file"
  (interactive)
  (save-excursion
    (let (found)
      (goto-char (point-min))
      (setq found (re-search-forward "#\\+BEGIN: columnview .* :id \"TASKS\"" nil t))
      (if (not found)
          (error "columnview with \"TASKS\" id not found"))
      (org-ctrl-c-ctrl-c)
      (goto-char (point-min))
      (setq found (re-search-forward "#\\+BEGIN: block-update-summary" nil t))
      (if (not found)
          (error "block-update-summary not found"))
      (org-ctrl-c-ctrl-c)
      (goto-char (point-min))
      (setq found (re-search-forward "#\\+BEGIN: block-update-burndown" nil t))
      (if (not found)
          (error "block-update-burndown not found"))
      (org-ctrl-c-ctrl-c)
      (goto-char (point-min))
      (setq found (re-search-forward "#\\+BEGIN: block-update-graph" nil t))
      (if (not found)
          (error "block-update-graph not found"))
      (org-ctrl-c-ctrl-c))))

(provide 'scrum)