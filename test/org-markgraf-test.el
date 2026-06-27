;;; org-markgraf-test.el --- Tests for org-markgraf -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'ox-html)
(require 'org-markgraf)

(ert-deftest org-markgraf-encodes-source-as-utf8-base64 ()
  (should (string= (org-markgraf--source-b64 "node π") "bm9kZSDPgA==")))

(ert-deftest org-markgraf-renders-embed-html ()
  (let ((html (org-markgraf-html "seed 1" '((:height . "320") (:width . "80svh")))))
    (should (string-match-p "data-markgraf" html))
    (should (string-match-p "data-markgraf-src-b64=\"c2VlZCAx\"" html))
    (should (string-match-p "--mg-max-height: 320px" html))
    (should (string-match-p "max-width: 80svh" html))))

(ert-deftest org-markgraf-html-export-replaces-markgraf-src-block ()
  (let* ((org "#+begin_src markgraf :height 320\nseed 1\n#+end_src\n")
         (org-export-before-processing-functions '(org-markgraf-export-blocks))
         (html (with-temp-buffer
                 (insert org)
                 (org-export-as 'html nil nil nil))))
    (should (string-match-p "markgraf-embed.js" html))
    (should (string-match-p "data-markgraf-src-b64=\"c2VlZCAxCg==\"" html))
    (should-not (string-match-p "src src-markgraf" html))))

(ert-deftest org-markgraf-leaves-non-html-export-alone ()
  (with-temp-buffer
    (insert "#+begin_src markgraf\nseed 1\n#+end_src\n")
    (org-markgraf-export-blocks 'ascii)
    (should (string-match-p "#\\+begin_src markgraf" (buffer-string)))))

(ert-deftest org-markgraf-inline-preview-reports-missing-xwidgets ()
  (cl-letf (((symbol-function 'org-markgraf--xwidgets-available-p) (lambda () nil)))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src markgraf\nseed 1\n#+end_src\n")
      (goto-char (point-min))
      (should-error (org-markgraf-preview-inline-at-point) :type 'user-error))))

(ert-deftest org-markgraf-inline-preview-hides-controls-by-default ()
  (let ((html (org-markgraf-inline-html-document "seed 1")))
    (should (string-match-p "data-mg=\"bar\"" html))
    (should (string-match-p "data-mg=\"scrub\"" html))
    (should (string-match-p "data-mg=\"play\"" html))
    (should (string-match-p "display: none" html))))

(ert-deftest org-markgraf-inline-preview-centres-and-frames-output ()
  (let ((html (org-markgraf-inline-html-document "seed 1")))
    (should (string-match-p "justify-content: center" html))
    (should (string-match-p "border: 1px solid" html))))

(ert-deftest org-markgraf-inline-preview-hides-frame-titles-by-default ()
  (let ((html (org-markgraf-inline-html-document "seed 1")))
    (should (string-match-p "data-markgraf-titles=\"false\"" html))))

(ert-deftest org-markgraf-inline-preview-uses-pixel-dimensions ()
  (should (equal (org-markgraf--inline-preview-size '((:height . "320") (:width . "760")))
                 '(760 . 320))))

(ert-deftest org-markgraf-preview-button-mode-adds-buttons-for-markgraf-blocks ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src markgraf\nseed 1\n#+end_src\n\n#+begin_src emacs-lisp\nt\n#+end_src\n")
    (org-markgraf-preview-button-mode 1)
    (should (= (length org-markgraf--preview-button-overlays) 1))
    (should (string-match-p "Preview Markgraf"
                            (overlay-get (car org-markgraf--preview-button-overlays)
                                         'before-string)))))

(ert-deftest org-markgraf-preview-button-overlay-is-clickable-at-block-start ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src markgraf\nseed 1\n#+end_src\n")
    (org-markgraf-preview-button-mode 1)
    (goto-char (point-min))
    (should (cl-some (lambda (overlay)
                       (overlay-get overlay 'org-markgraf-block-begin))
                     (overlays-at (point))))))

(ert-deftest org-markgraf-preview-button-string-can-show-hide-state ()
  (should (string-match-p "Preview Markgraf" (org-markgraf--preview-button-string)))
  (should (string-match-p "Hide Markgraf" (org-markgraf--preview-button-string t))))

(ert-deftest org-markgraf-side-preview-mode-has-evil-style-controls ()
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "h"))
              #'org-markgraf-side-preview-scrub-backward))
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "l"))
              #'org-markgraf-side-preview-scrub-forward))
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "H"))
              #'org-markgraf-side-preview-scrub-backward-fast))
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "L"))
              #'org-markgraf-side-preview-scrub-forward-fast))
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "SPC"))
              #'org-markgraf-side-preview-toggle-play))
  (should (eq (lookup-key org-markgraf-side-preview-mode-map (kbd "q"))
              #'org-markgraf-close-side-preview)))

;;; org-markgraf-test.el ends here
