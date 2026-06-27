;;; org-markgraf.el --- Render markgraf diagrams in Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mark Eibes
;; Author: Mark Eibes <mark.eibes@gmail.com>
;; URL: https://github.com/markgrafhq/org-markgraf
;; Package-Requires: ((emacs "27.1") (org "9.5"))
;; Version: 0.1.0
;; Keywords: outlines, hypermedia, diagrams

;;; Commentary:

;; Org integration for markgraf diagrams.

;;; Code:

(require 'cl-lib)
(require 'ob)
(require 'org)
(require 'ox)
(require 'org-element)
(require 'subr-x)

(defgroup org-markgraf nil
  "Render markgraf diagrams in Org."
  :group 'org
  :prefix "org-markgraf-")

(defcustom org-markgraf-css-url
  "https://unpkg.com/@markgrafhq/markgraf-embed/dist/markgraf-embed.css"
  "Stylesheet loaded by HTML exports containing markgraf blocks."
  :type 'string
  :group 'org-markgraf)

(defcustom org-markgraf-script-url
  "https://unpkg.com/@markgrafhq/markgraf-embed/dist/markgraf-embed.js"
  "Script loaded by HTML exports containing markgraf blocks."
  :type 'string
  :group 'org-markgraf)

(defcustom org-markgraf-preview-browser-function #'browse-url
  "Function used by `org-markgraf-preview-at-point'."
  :type 'function
  :group 'org-markgraf)

(defun org-markgraf-setup ()
  "Enable Org export and Babel support for markgraf source blocks."
  (add-to-list 'org-babel-load-languages '(markgraf . t))
  (if (boundp 'org-export-before-processing-functions)
      (add-hook 'org-export-before-processing-functions #'org-markgraf-export-blocks)
    (with-no-warnings
      (add-hook 'org-export-before-processing-hook #'org-markgraf-export-blocks))))

(defun org-markgraf-html (source &optional params)
  "Return a markgraf embed element for SOURCE using PARAMS."
  (format "<div data-markgraf data-markgraf-src-b64=\"%s\"%s></div>"
          (org-markgraf--source-b64 source)
          (org-markgraf--style-attribute params)))

(defun org-markgraf-html-assets ()
  "Return HTML tags needed by markgraf embeds."
  (format "<link rel=\"stylesheet\" href=\"%s\">\n<script src=\"%s\"></script>"
          (org-markgraf--html-escape org-markgraf-css-url)
          (org-markgraf--html-escape org-markgraf-script-url)))

(defun org-markgraf-html-document (source &optional params)
  "Return a complete HTML document rendering SOURCE using PARAMS."
  (format "<!doctype html>\n<meta charset=\"utf-8\">\n%s\n%s\n"
          (org-markgraf-html-assets)
          (org-markgraf-html source params)))

(defun org-markgraf-preview-at-point ()
  "Render the markgraf block at point in a temporary browser page."
  (interactive)
  (let* ((block (org-markgraf--src-block-at-point))
         (source (org-element-property :value block))
         (params (org-babel-parse-header-arguments
                  (or (org-element-property :parameters block) "")))
         (file (make-temp-file "org-markgraf-" nil ".html")))
    (write-region (org-markgraf-html-document source params) nil file nil 'silent)
    (funcall org-markgraf-preview-browser-function (concat "file://" file))))

(defun org-babel-execute:markgraf (body params)
  "Execute a markgraf source block by returning its HTML embed for BODY and PARAMS."
  (org-markgraf-html-document body params))

(defun org-markgraf-export-blocks (backend)
  "Replace markgraf source blocks before exporting to BACKEND."
  (when (org-export-derived-backend-p backend 'html)
    (let ((replacements (org-markgraf--collect-export-replacements)))
      (when replacements
        (dolist (replacement replacements)
          (pcase-let ((`(,begin ,end ,html) replacement))
            (delete-region begin end)
            (goto-char begin)
            (insert html)))
        (goto-char (point-min))
        (insert (org-markgraf--html-head-lines))))))

(defun org-markgraf--html-head-lines ()
  "Return Org HTML_HEAD lines needed by markgraf embeds."
  (format "#+HTML_HEAD: <link rel=\"stylesheet\" href=\"%s\">\n#+HTML_HEAD: <script src=\"%s\"></script>\n"
          (org-markgraf--html-escape org-markgraf-css-url)
          (org-markgraf--html-escape org-markgraf-script-url)))

(defun org-markgraf--collect-export-replacements ()
  "Return markgraf block replacements in reverse buffer order."
  (let (replacements)
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (block)
        (when (string= (org-element-property :language block) "markgraf")
          (push (list (org-element-property :begin block)
                      (org-element-property :end block)
                      (org-markgraf--export-block
                       (org-markgraf-html
                        (org-element-property :value block)
                        (org-babel-parse-header-arguments
                         (or (org-element-property :parameters block) "")))))
                replacements))))
    (sort replacements (lambda (left right) (> (car left) (car right))))))

(defun org-markgraf--export-block (html)
  "Return an Org raw HTML export block containing HTML."
  (concat "#+begin_export html\n" html "\n#+end_export\n"))

(defun org-markgraf--src-block-at-point ()
  "Return the markgraf source block at point, or signal an error."
  (let ((element (org-element-context)))
    (unless (and (eq (org-element-type element) 'src-block)
                 (string= (org-element-property :language element) "markgraf"))
      (user-error "Point is not in a markgraf source block"))
    element))

(defun org-markgraf--source-b64 (source)
  "Return SOURCE encoded as unwrapped UTF-8 base64."
  (base64-encode-string (encode-coding-string source 'utf-8) t))

(defun org-markgraf--style-attribute (params)
  "Return a style attribute built from PARAMS."
  (let* ((height (org-markgraf--dimension-param :height params))
         (width (org-markgraf--dimension-param :width params))
         (style (string-join (delq nil (list
                                        (when height (concat "--mg-max-height: " height))
                                        (when width (concat "max-width: " width))))
                             "; ")))
    (if (string-empty-p style)
        ""
      (format " style=\"%s\"" (org-markgraf--html-escape style)))))

(defun org-markgraf--dimension-param (key params)
  "Return normalized dimension KEY from PARAMS, or nil."
  (when-let* ((value (cdr (assq key params)))
              (text (string-trim (format "%s" value))))
    (cond
     ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)
      (concat text "px"))
     ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\(?:px\\|%\\|svh\\|vh\\|dvh\\|em\\|rem\\)\\'" text)
      text))))

(defun org-markgraf--html-escape (text)
  "Return TEXT escaped for HTML attributes."
  (replace-regexp-in-string
   "'" "&#39;"
   (replace-regexp-in-string
    "\"" "&quot;"
    (replace-regexp-in-string
     ">" "&gt;"
     (replace-regexp-in-string
      "<" "&lt;"
      (replace-regexp-in-string "&" "&amp;" text t t) t t) t t) t t) t t))

(provide 'org-markgraf)
;;; org-markgraf.el ends here
