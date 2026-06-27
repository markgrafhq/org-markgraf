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

(declare-function xwidget-insert "xwidget" (pos type title width height &optional args related))
(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))

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

(defcustom org-markgraf-inline-preview-width 900
  "Width in pixels for inline markgraf previews."
  :type 'integer
  :group 'org-markgraf)

(defcustom org-markgraf-inline-preview-height 360
  "Height in pixels for inline markgraf previews."
  :type 'integer
  :group 'org-markgraf)

(defcustom org-markgraf-inline-preview-show-controls nil
  "When non-nil, show markgraf player controls in inline previews."
  :type 'boolean
  :group 'org-markgraf)

(defvar-local org-markgraf--inline-previews nil
  "Inline markgraf preview records in the current buffer.")

(defvar-local org-markgraf--preview-button-overlays nil
  "Preview button overlays in the current buffer.")

(defvar org-markgraf--preview-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'org-markgraf-preview-button-click)
    (define-key map (kbd "RET") #'org-markgraf-preview-button-activate)
    map)
  "Keymap used by inline markgraf preview buttons.")

(defun org-markgraf-setup ()
  "Enable Org export and Babel support for markgraf source blocks."
  (add-to-list 'org-babel-load-languages '(markgraf . t))
  (add-hook 'org-mode-hook #'org-markgraf-preview-button-mode)
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

(defun org-markgraf-inline-html-document (source &optional params)
  "Return a complete HTML document for an inline Emacs preview."
  (format "<!doctype html>\n<meta charset=\"utf-8\">\n%s\n<style>\n%s\n</style>\n%s\n"
          (org-markgraf-html-assets)
          (org-markgraf--inline-css)
          (org-markgraf-html source params)))

(define-minor-mode org-markgraf-preview-button-mode
  "Show clickable inline preview buttons for markgraf source blocks."
  :lighter " Markgraf"
  (if org-markgraf-preview-button-mode
      (progn
        (add-hook 'after-change-functions #'org-markgraf--refresh-preview-buttons-after-change nil t)
        (org-markgraf-refresh-preview-buttons))
    (remove-hook 'after-change-functions #'org-markgraf--refresh-preview-buttons-after-change t)
    (org-markgraf-clear-preview-buttons)))

(defun org-markgraf-refresh-preview-buttons ()
  "Refresh clickable preview buttons in the current Org buffer."
  (interactive)
  (org-markgraf-clear-preview-buttons)
  (save-excursion
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (block)
        (when (string= (org-element-property :language block) "markgraf")
          (org-markgraf--add-preview-button block))))))

(defun org-markgraf-clear-preview-buttons ()
  "Remove clickable preview buttons in the current buffer."
  (interactive)
  (mapc #'delete-overlay org-markgraf--preview-button-overlays)
  (setq org-markgraf--preview-button-overlays nil))

(defun org-markgraf-preview-button-click (event)
  "Preview the markgraf source block for clicked EVENT."
  (interactive "e")
  (let* ((pos (posn-point (event-end event)))
         (overlay (cl-find-if (lambda (candidate)
                                (overlay-get candidate 'org-markgraf-block-begin))
                              (overlays-at pos))))
    (org-markgraf--preview-button-overlay overlay)))

(defun org-markgraf-preview-button-activate ()
  "Preview the markgraf source block for the button at point."
  (interactive)
  (let ((overlay (cl-find-if (lambda (candidate)
                               (overlay-get candidate 'org-markgraf-block-begin))
                             (overlays-at (point)))))
    (org-markgraf--preview-button-overlay overlay)))

(defun org-markgraf-preview-at-point ()
  "Render the markgraf block at point in a temporary browser page."
  (interactive)
  (let* ((block (org-markgraf--src-block-at-point))
         (file (org-markgraf--preview-file block)))
    (funcall org-markgraf-preview-browser-function (concat "file://" file))))

(defun org-markgraf-preview-inline-at-point ()
  "Render the markgraf block at point inline with an Emacs WebKit xwidget."
  (interactive)
  (unless (org-markgraf--xwidgets-available-p)
    (user-error "This Emacs was not built with xwidget-webkit support"))
  (let* ((block (org-markgraf--src-block-at-point))
         (begin (copy-marker (org-element-property :begin block)))
         (end (copy-marker (org-element-property :end block) t))
         (params (org-markgraf--src-block-params block))
         (file (org-markgraf--preview-file block t))
         (url (concat "file://" file))
         (size (org-markgraf--inline-preview-size params)))
    (org-markgraf-clear-inline-preview-at-point)
    (goto-char end)
    (unless (bolp)
      (insert "\n"))
    (let* ((insert-begin (copy-marker (point)))
           (xwidget (xwidget-insert (point) 'webkit "markgraf"
                                    (car size)
                                    (cdr size)))
           (insert-end (copy-marker (point) t)))
      (xwidget-webkit-goto-uri xwidget url)
      (push (list begin end insert-begin insert-end xwidget file)
            org-markgraf--inline-previews))))

(defun org-markgraf-clear-inline-preview-at-point ()
  "Clear the inline markgraf preview for the block at point."
  (interactive)
  (let* ((block (org-markgraf--src-block-at-point))
         (block-begin (org-element-property :begin block)))
    (setq org-markgraf--inline-previews
          (cl-remove-if
           (lambda (preview)
             (when (= (marker-position (nth 0 preview)) block-begin)
               (delete-region (marker-position (nth 2 preview))
                              (marker-position (nth 3 preview)))
               (when-let* ((file (nth 5 preview)))
                 (ignore-errors (delete-file file)))
               t))
           org-markgraf--inline-previews))))

(defun org-markgraf-clear-inline-previews ()
  "Clear all inline markgraf previews in the current buffer."
  (interactive)
  (dolist (preview org-markgraf--inline-previews)
    (delete-region (marker-position (nth 2 preview))
                   (marker-position (nth 3 preview)))
    (when-let* ((file (nth 5 preview)))
      (ignore-errors (delete-file file))))
  (setq org-markgraf--inline-previews nil))

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

(defun org-markgraf--add-preview-button (block)
  "Add a clickable preview button for BLOCK."
  (let* ((begin (org-element-property :begin block))
         (overlay (make-overlay begin begin nil t nil)))
    (overlay-put overlay 'org-markgraf-block-begin begin)
    (overlay-put overlay 'before-string (org-markgraf--preview-button-string))
    (push overlay org-markgraf--preview-button-overlays)))

(defun org-markgraf--preview-button-string ()
  "Return the clickable preview button display string."
  (concat
   (propertize "▶ Preview Markgraf"
               'face 'button
               'mouse-face 'highlight
               'help-echo "mouse-1 or RET: preview markgraf inline"
               'keymap org-markgraf--preview-button-map)
   "\n"))

(defun org-markgraf--preview-button-overlay (overlay)
  "Preview the markgraf source block associated with OVERLAY."
  (unless overlay
    (user-error "No markgraf preview button here"))
  (let ((begin (overlay-get overlay 'org-markgraf-block-begin)))
    (goto-char begin)
    (org-markgraf-preview-inline-at-point)))

(defun org-markgraf--refresh-preview-buttons-after-change (&rest _)
  "Refresh markgraf preview buttons after a buffer change."
  (when org-markgraf-preview-button-mode
    (org-markgraf-refresh-preview-buttons)))

(defun org-markgraf--preview-file (block &optional inline)
  "Write BLOCK to a temporary HTML file and return the file path.
When INLINE is non-nil, write an Emacs inline preview document."
  (let* ((source (org-element-property :value block))
         (params (org-markgraf--src-block-params block))
         (file (make-temp-file "org-markgraf-" nil ".html")))
    (write-region (if inline
                      (org-markgraf-inline-html-document source params)
                    (org-markgraf-html-document source params))
                  nil file nil 'silent)
    file))

(defun org-markgraf--src-block-params (block)
  "Return parsed header arguments for BLOCK."
  (org-babel-parse-header-arguments
   (or (org-element-property :parameters block) "")))

(defun org-markgraf--inline-preview-size (params)
  "Return the xwidget size for PARAMS as WIDTH . HEIGHT."
  (cons (org-markgraf--dimension-pixels :width params org-markgraf-inline-preview-width)
        (org-markgraf--dimension-pixels :height params org-markgraf-inline-preview-height)))

(defun org-markgraf--inline-css ()
  "Return CSS overrides for an inline Emacs preview."
  (concat "html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }\n"
          "body { box-sizing: border-box; }\n"
          ".markgraf-embed { border-radius: 6px; }\n"
          ".markgraf-embed canvas[data-mg=\"stage\"] { max-height: calc(100vh - 2px); }\n"
          (unless org-markgraf-inline-preview-show-controls
            ".markgraf-embed [data-mg=\"bar\"], .markgraf-embed [data-mg=\"play-overlay\"] { display: none !important; }\n")))

(defun org-markgraf--xwidgets-available-p ()
  "Return non-nil when inline WebKit previews can be created."
  (and (require 'xwidget nil t)
       (fboundp 'xwidget-insert)
       (fboundp 'xwidget-webkit-goto-uri)))

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

(defun org-markgraf--dimension-pixels (key params default)
  "Return KEY from PARAMS as pixels, falling back to DEFAULT."
  (if-let* ((dimension (org-markgraf--dimension-param key params))
            ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)px\\'" dimension)))
      (string-to-number (match-string 1 dimension))
    default))

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
