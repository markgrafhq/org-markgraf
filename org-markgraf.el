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
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional fun))
(declare-function evil-define-key "evil-core" (state keymap key def &rest bindings))

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

(defcustom org-markgraf-inline-preview-show-titles nil
  "When non-nil, show markgraf frame titles in inline previews."
  :type 'boolean
  :group 'org-markgraf)

(defcustom org-markgraf-side-preview-buffer-name "*markgraf preview*"
  "Singleton buffer name for side-window markgraf previews."
  :type 'string
  :group 'org-markgraf)

(defcustom org-markgraf-side-preview-width 0.42
  "Width used by the singleton side preview window."
  :type 'number
  :group 'org-markgraf)

(defvar org-markgraf--side-preview-file nil
  "Temporary file currently shown in the singleton side preview.")

(defvar org-markgraf--side-preview-block-begin nil
  "Source block position currently shown in the singleton side preview.")

(defvar org-markgraf--side-preview-xwidget nil
  "Xwidget currently shown in the singleton side preview.")

(defvar org-markgraf-side-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "h") #'org-markgraf-side-preview-scrub-backward)
    (define-key map (kbd "l") #'org-markgraf-side-preview-scrub-forward)
    (define-key map (kbd "<left>") #'org-markgraf-side-preview-scrub-backward)
    (define-key map (kbd "<right>") #'org-markgraf-side-preview-scrub-forward)
    (define-key map (kbd "SPC") #'org-markgraf-side-preview-toggle-play)
    (define-key map (kbd "p") #'org-markgraf-side-preview-toggle-play)
    (define-key map (kbd "q") #'org-markgraf-close-side-preview)
    map)
  "Keymap for `org-markgraf-side-preview-mode'.")

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

(define-derived-mode org-markgraf-side-preview-mode special-mode "Markgraf Preview"
  "Mode for the singleton markgraf side preview buffer."
  (setq-local kill-buffer-query-functions nil))

(with-eval-after-load 'evil
  (evil-define-key 'normal org-markgraf-side-preview-mode-map
    (kbd "h") #'org-markgraf-side-preview-scrub-backward
    (kbd "l") #'org-markgraf-side-preview-scrub-forward
    (kbd "SPC") #'org-markgraf-side-preview-toggle-play
    (kbd "p") #'org-markgraf-side-preview-toggle-play
    (kbd "q") #'org-markgraf-close-side-preview))

(defun org-markgraf-setup ()
  "Enable Org export and Babel support for markgraf source blocks."
  (add-to-list 'org-babel-load-languages '(markgraf . t))
  (add-hook 'org-mode-hook #'org-markgraf-preview-button-mode)
  (if (boundp 'org-export-before-processing-functions)
      (add-hook 'org-export-before-processing-functions #'org-markgraf-export-blocks)
    (with-no-warnings
      (add-hook 'org-export-before-processing-hook #'org-markgraf-export-blocks))))

(defun org-markgraf-html (source &optional params attributes)
  "Return a markgraf embed element for SOURCE using PARAMS and ATTRIBUTES."
  (format "<div data-markgraf data-markgraf-src-b64=\"%s\"%s%s></div>"
          (org-markgraf--source-b64 source)
          (org-markgraf--attributes attributes)
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
          (org-markgraf-html source params (org-markgraf--inline-attributes))))

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

(defun org-markgraf-preview-side-at-point ()
  "Render the markgraf block at point in a singleton side preview buffer."
  (interactive)
  (unless (org-markgraf--xwidgets-available-p)
    (user-error "This Emacs was not built with xwidget-webkit support"))
  (let* ((block (org-markgraf--src-block-at-point))
         (params (org-markgraf--src-block-params block))
         (block-begin (org-element-property :begin block))
         (file (org-markgraf--preview-file block t))
         (url (concat "file://" file))
         (size (org-markgraf--side-preview-size params))
         (buffer (get-buffer-create org-markgraf-side-preview-buffer-name)))
    (when org-markgraf--side-preview-file
      (ignore-errors (delete-file org-markgraf--side-preview-file)))
    (setq org-markgraf--side-preview-file file
          org-markgraf--side-preview-block-begin block-begin)
    (with-current-buffer buffer
      (org-markgraf-side-preview-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n")
        (goto-char (point-min))
        (let ((xwidget (xwidget-insert (point) 'webkit "markgraf"
                                       (car size)
                                       (cdr size))))
          (setq org-markgraf--side-preview-xwidget xwidget)
          (xwidget-webkit-goto-uri xwidget url))))
    (display-buffer-in-side-window
     buffer `((side . right)
              (slot . 1)
              (window-width . ,org-markgraf-side-preview-width)))
    buffer))

(defun org-markgraf-close-side-preview ()
  "Close the singleton side preview buffer and delete its temp file."
  (interactive)
  (when-let* ((buffer (get-buffer org-markgraf-side-preview-buffer-name)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer)))
  (when org-markgraf--side-preview-file
    (ignore-errors (delete-file org-markgraf--side-preview-file))
    (setq org-markgraf--side-preview-file nil
          org-markgraf--side-preview-block-begin nil
          org-markgraf--side-preview-xwidget nil))
  (dolist (overlay org-markgraf--preview-button-overlays)
    (overlay-put overlay 'before-string (org-markgraf--preview-button-string))))

(defun org-markgraf-side-preview-scrub-backward ()
  "Scrub the singleton side preview backward."
  (interactive)
  (org-markgraf--side-preview-scrub -1))

(defun org-markgraf-side-preview-scrub-forward ()
  "Scrub the singleton side preview forward."
  (interactive)
  (org-markgraf--side-preview-scrub 1))

(defun org-markgraf-side-preview-toggle-play ()
  "Toggle play/pause in the singleton side preview."
  (interactive)
  (org-markgraf--side-preview-execute
   "(() => {
  const play = document.querySelector('[data-mg=\"play\"]');
  if (!play) return null;
  play.click();
  return play.getAttribute('data-mg-playing');
})()"))

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
    (let ((insert-begin (copy-marker (point))))
      (insert "\n")
      (goto-char insert-begin)
      (let* ((xwidget (xwidget-insert (point) 'webkit "markgraf"
                                      (car size)
                                      (cdr size)))
             (insert-end (copy-marker (1+ (marker-position insert-begin)) t)))
        (xwidget-webkit-goto-uri xwidget url)
        (push (list begin end insert-begin insert-end xwidget file)
              org-markgraf--inline-previews)))))

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
           org-markgraf--inline-previews))
    (org-markgraf--set-preview-button-state block-begin nil)))

(defun org-markgraf-clear-inline-previews ()
  "Clear all inline markgraf previews in the current buffer."
  (interactive)
  (dolist (preview org-markgraf--inline-previews)
    (delete-region (marker-position (nth 2 preview))
                   (marker-position (nth 3 preview)))
    (when-let* ((file (nth 5 preview)))
      (ignore-errors (delete-file file))))
  (setq org-markgraf--inline-previews nil)
  (dolist (overlay org-markgraf--preview-button-overlays)
    (overlay-put overlay 'before-string (org-markgraf--preview-button-string))))

(defun org-babel-execute:markgraf (_body _params)
  "Preview a markgraf source block in the singleton side preview."
  (org-markgraf-preview-side-at-point)
  "")

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
         (end (org-element-property :end block))
         (overlay (make-overlay begin (min (1+ begin) end) nil t nil)))
    (overlay-put overlay 'org-markgraf-block-begin begin)
    (overlay-put overlay 'before-string (org-markgraf--preview-button-string))
    (push overlay org-markgraf--preview-button-overlays)))

(defun org-markgraf--preview-button-string (&optional shown)
  "Return the clickable preview button display string.
When SHOWN is non-nil, render the button as a hide action."
  (concat
   (propertize (if shown "▼ Hide Markgraf" "▶ Preview Markgraf")
               'face 'button
               'mouse-face 'highlight
               'help-echo "mouse-1 or RET: toggle markgraf side preview"
               'keymap org-markgraf--preview-button-map)
   "\n"))

(defun org-markgraf--side-preview-scrub (direction)
  "Scrub the singleton side preview in DIRECTION."
  (org-markgraf--side-preview-execute
   (format "(() => {
  const scrub = document.querySelector('[data-mg=\"scrub\"]');
  if (!scrub) return null;
  const max = Number(scrub.max || 1000);
  const step = max / 20;
  const value = Math.max(0, Math.min(max, Number(scrub.value || 0) + (%d * step)));
  scrub.value = value;
  scrub.dispatchEvent(new Event('input', { bubbles: true }));
  return value;
})()" direction)))

(defun org-markgraf--side-preview-execute (script)
  "Execute SCRIPT in the singleton side preview."
  (unless org-markgraf--side-preview-xwidget
    (user-error "No markgraf side preview is open"))
  (xwidget-webkit-execute-script org-markgraf--side-preview-xwidget script))

(defun org-markgraf--inline-preview-shown-p (block-begin)
  "Return non-nil when BLOCK-BEGIN has an inline preview."
  (cl-some (lambda (preview)
             (= (marker-position (nth 0 preview)) block-begin))
           org-markgraf--inline-previews))

(defun org-markgraf--set-preview-button-state (block-begin shown)
  "Set the preview button for BLOCK-BEGIN to SHOWN state."
  (when-let* ((overlay (cl-find-if
                        (lambda (candidate)
                          (= (overlay-get candidate 'org-markgraf-block-begin) block-begin))
                        org-markgraf--preview-button-overlays)))
    (overlay-put overlay 'before-string (org-markgraf--preview-button-string shown))))

(defun org-markgraf--preview-button-overlay (overlay)
  "Toggle the markgraf source block preview associated with OVERLAY."
  (unless overlay
    (user-error "No markgraf preview button here"))
  (let ((begin (overlay-get overlay 'org-markgraf-block-begin)))
    (goto-char begin)
    (if (and (equal org-markgraf--side-preview-block-begin begin)
             (get-buffer org-markgraf-side-preview-buffer-name))
        (org-markgraf-close-side-preview)
      (org-markgraf-preview-side-at-point)
      (dolist (candidate org-markgraf--preview-button-overlays)
        (overlay-put candidate 'before-string (org-markgraf--preview-button-string)))
      (overlay-put overlay 'before-string (org-markgraf--preview-button-string t)))))

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

(defun org-markgraf--side-preview-size (params)
  "Return the singleton side preview xwidget size for PARAMS."
  (cons (org-markgraf--dimension-pixels :width params org-markgraf-inline-preview-width)
        (org-markgraf--dimension-pixels :height params org-markgraf-inline-preview-height)))

(defun org-markgraf--inline-css ()
  "Return CSS overrides for an inline Emacs preview."
  (concat "html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; width: 100%; height: 100%; }\n"
          "body { box-sizing: border-box; display: flex; align-items: center; justify-content: center; padding: 10px; }\n"
          ".markgraf-embed { box-sizing: border-box; width: 100%; max-width: calc(100vw - 20px); max-height: calc(100vh - 20px); border: 1px solid rgba(128, 128, 128, 0.45); border-radius: 8px; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.18); }\n"
          ".markgraf-embed canvas[data-mg=\"stage\"] { max-height: calc(100vh - 22px); }\n"
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

(defun org-markgraf--inline-attributes ()
  "Return HTML attributes for inline Emacs previews."
  (unless org-markgraf-inline-preview-show-titles
    '(("data-markgraf-titles" . "false"))))

(defun org-markgraf--attributes (attributes)
  "Return ATTRIBUTES formatted for an HTML tag."
  (mapconcat (lambda (attribute)
               (format " %s=\"%s\""
                       (org-markgraf--html-escape (format "%s" (car attribute)))
                       (org-markgraf--html-escape (cdr attribute))))
             attributes
             ""))

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
