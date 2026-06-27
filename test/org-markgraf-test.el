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

;;; org-markgraf-test.el ends here
