;;; comment-translator.el --- Translate Chinese comments to English -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026  c0ptr

;; Author: c0ptr
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, languages, tools
;; URL: https://github.com/c0ptr/comment-translator

;;; Commentary:

;; comment-translator 自动把代码注释里的中文翻译成英文。
;;
;; It works with every programming language Emacs supports, because
;; comments are located through each major mode's own syntax table
;; (no language-specific parser is needed).  String literals are never
;; touched, only comments.
;;
;; 手动模式 (Manual mode):
;;
;;     (global-set-key (kbd "C-c C-t") #'comment-translator-translate-comment)
;;
;;     M-x comment-translator-translate-comment     翻译光标所在的注释
;;     M-x comment-translator-translate-region      翻译选区内的注释
;;     M-x comment-translator-translate-buffer      翻译整个缓冲区
;;     C-u M-x comment-translator-translate-buffer  反向：英文 -> 中文
;;     M-x comment-translator-revert-comment        撤销：恢复本次会话内翻译的原文
;;
;; 自动模式 (Automatic mode):
;;
;;     (add-hook 'prog-mode-hook #'comment-translator-auto-mode)
;;     ;; 或全局启用（仅编程模式）：
;;     ;; (comment-translator-global-auto-mode 1)
;;
;; Translation backends (`comment-translator-backend'):
;;     google   -- translate.googleapis.com 免费端点，无需 API key
;;     mymemory -- MyMemory 免费接口，无需 API key
;;     openai   -- 任意 OpenAI 兼容接口（DeepSeek / OpenAI / Ollama ...）
;;     自定义函数
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup comment-translator nil
  "Translate Chinese code comments into English."
  :group 'convenience
  :prefix "comment-translator-")

;;; Options ----------------------------------------------------------------

(defcustom comment-translator-backend 'google
  "Translation backend to use.
`google'    -- free endpoint of Google Translate, no API key required.
`mymemory'  -- free MyMemory API (api.mymemory.translated.net), no key.
`openai'    -- any OpenAI-compatible chat completions API (needs
               `comment-translator-openai-api-key').
a function  -- called with one string argument; must return the translation."
  :type '(choice (const :tag "Google Translate (free)" google)
           (const :tag "MyMemory (free)" mymemory)
           (const :tag "OpenAI-compatible API" openai)
           (function :tag "Custom function")))

(defcustom comment-translator-source-language "zh-CN"
  "Source language, as expected by the active backend.
For the google and mymemory backends use codes such as \"zh-CN\", \"en\"."
  :type 'string)

(defcustom comment-translator-target-language "en"
  "Target language, as expected by the active backend."
  :type 'string)

(defcustom comment-translator-glossary nil
  "Alist of (CHINESE-TERM . ENGLISH-TERM) pairs that must be kept unchanged.
Terms are substituted before the text is sent to the translator, so the
backend never gets a chance to mistranslate them.  Example:

    (setq comment-translator-glossary
          \\='((\"服务器\" . \"server\") (\"数据库\" . \"database\")))"
  :type '(alist :key-type string :value-type string))

(defcustom comment-translator-excluded-modes nil
  "Major modes in which comment translation is disabled."
  :type '(repeat symbol))

(defcustom comment-translator-enabled-modes nil
  "Whitelist of major modes.  nil means every mode that has comments."
  :type '(repeat symbol))

(defcustom comment-translator-skip-regexp nil
  "Comments whose content matches this regexp are left alone.
Useful for preserving e.g. license headers or generated blocks."
  :type '(choice (const :tag "None" nil) regexp))

(defcustom comment-translator-bilingual nil
  "When non-nil, keep the original Chinese line under the English line.
The added line is marked with `comment-translator-bilingual-marker' so
repeated runs do not duplicate it.  Only single-line, whole-line comments
are handled; other comments are replaced in place."
  :type 'boolean)

(defcustom comment-translator-bilingual-marker "[en]"
  "Marker placed at the start of the added bilingual translation line."
  :type 'string)

(defcustom comment-translator-cache-enabled t
  "When non-nil, remember translations on disk to avoid repeated requests."
  :type 'boolean)

(defcustom comment-translator-cache-file
  (locate-user-emacs-file "comment-translator-cache.el")
  "File used to persist the translation cache between sessions."
  :type 'file)

(defcustom comment-translator-auto-on-write t
  "When non-nil, translate a comment as soon as you finish typing it.
`comment-translator-auto-mode' watches for the moment you edit a comment
and then move point out of it."
  :type 'boolean)

(defcustom comment-translator-auto-on-idle t
  "When non-nil, translate Chinese comments while Emacs is idle.
Only buffers that are already modified are touched."
  :type 'boolean)

(defcustom comment-translator-auto-idle-delay 5
  "Seconds of idle time before automatic translation kicks in."
  :type 'number)

(defcustom comment-translator-auto-on-save t
  "When non-nil, translate all Chinese comments just before each save."
  :type 'boolean)

(defcustom comment-translator-auto-confirm nil
  "When non-nil, automatic translation asks for confirmation first."
  :type 'boolean)

(defcustom comment-translator-openai-api-key nil
  "API key for the `openai' backend.
Works with any OpenAI-compatible provider: OpenAI, DeepSeek, Ollama, ..."
  :type '(choice (const :tag "Unset" nil) string))

(defcustom comment-translator-openai-base-url "https://api.deepseek.com/v1"
  "Base URL of the OpenAI-compatible API used by the `openai' backend."
  :type 'string)

(defcustom comment-translator-openai-model "deepseek-chat"
  "Model name for the `openai' backend."
  :type 'string)

(defcustom comment-translator-openai-extra-args nil
  "Extra alist of JSON fields merged into the chat-completions request.
For example: ((temperature . 0.2)).  Entries override built-in ones."
  :type 'alist)

(defcustom comment-translator-mymemory-email nil
  "Optional MyMemory account email; raises the free quota to 50k chars/day."
  :type '(choice (const :tag "None" nil) string))

(defvar-local comment-translator-disabled nil
  "Non-nil disables translation in this buffer.
Set it per-project with a .dir-locals.el entry:

    ((prog-mode . ((comment-translator-disabled . t))))")

(put 'comment-translator-disabled 'safe-local-variable #'booleanp)

;;; Internal state ---------------------------------------------------------

(defvar ct--reverse nil
  "Non-nil while translating in the reverse direction (en -> zh).")

(defvar ct--cache (make-hash-table :test #'equal)
  "Translation cache: key -> translated text.")

(defvar ct--cache-loaded nil
  "Non-nil once the on-disk cache has been read.")

(defvar-local ct--history nil
  "Alist (TRANSLATED . ORIGINAL) for comments translated this session.
Used by `comment-translator-revert-comment'.")

(defvar-local ct--current-comment nil
  "Cons (BEG . END) of the comment containing point, while inside one.")

(defvar-local ct--edit-tick-in-comment nil
  "Buffer modification tick recorded while point is inside a comment.")

(defvar-local ct--idle-timer nil
  "Idle timer of `comment-translator-auto-mode' for this buffer.")

;;; Utilities ----------------------------------------------------------------

(defconst ct--chinese-regexp "\\cc\\|[，。！？、；：“”‘’（）《》【】—…]"
  "Regexp matching Chinese characters and common fullwidth punctuation.")

(defun ct-chinese-p (text)
  "Return non-nil when TEXT contains Chinese characters."
  (and (stringp text) (string-match-p ct--chinese-regexp text)))

(defun ct-disabled-p ()
  "Return non-nil when translation is disabled in the current buffer."
  (or (and comment-translator-enabled-modes
        (not (memq major-mode comment-translator-enabled-modes)))
    (memq major-mode comment-translator-excluded-modes)
    (bound-and-true-p comment-translator-disabled)))

(defun ct--apply-glossary (text)
  "Replace glossary terms in TEXT before translation.
In reverse mode the glossary pairs are swapped."
  (let ((pairs (if ct--reverse
                 (mapcar (lambda (pair) (cons (cdr pair) (car pair)))
                   comment-translator-glossary)
                 comment-translator-glossary)))
    (dolist (pair pairs text)
      (setq text (replace-regexp-in-string
                   (regexp-quote (car pair)) (cdr pair) text t t)))))

(defun ct--unescape-entities (text)
  "Decode the few HTML entities the MyMemory backend returns."
  (let ((entities '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
                     ("&quot;" . "\"") ("&apos;" . "'") ("&#39;" . "'")
                     ("&#039;" . "'") ("&nbsp;" . " "))))
    (dolist (entity entities text)
      (setq text (replace-regexp-in-string
                   (regexp-quote (car entity)) (cdr entity) text t t)))))

;;; Cache -------------------------------------------------------------------

(defun ct--cache-key (text)
  "Return the cache key for TEXT under the current settings."
  (format "%S|%s>%s|%s"
    comment-translator-backend
    comment-translator-source-language
    comment-translator-target-language
    text))

(defun ct--cache-load ()
  "Load the persisted translation cache."
  (when (and comment-translator-cache-enabled
          comment-translator-cache-file
          (file-readable-p comment-translator-cache-file)
          (not ct--cache-loaded))
    (setq ct--cache-loaded t)
    (condition-case err
      (with-temp-buffer
        (insert-file-contents comment-translator-cache-file)
        (goto-char (point-min))
        (let ((pairs (read (current-buffer))))
          (when (listp pairs)
            (dolist (pair pairs)
              (when (and (consp pair)
                      (stringp (car pair))
                      (stringp (cdr pair)))
                (puthash (car pair) (cdr pair) ct--cache))))))
      (error (message "comment-translator: could not read cache: %S" err)))))

(defun ct--cache-save ()
  "Persist the translation cache."
  (when (and comment-translator-cache-enabled
          comment-translator-cache-file)
    (condition-case err
      (let (pairs)
        (maphash (lambda (key value) (push (cons key value) pairs)) ct--cache)
        (with-temp-buffer
          (insert ";; -*- emacs-lisp -*- comment-translator cache\n")
          (prin1 (nreverse pairs) (current-buffer))
          (insert "\n")
          (write-region (point-min) (point-max) comment-translator-cache-file)))
      (error (message "comment-translator: could not save cache: %S" err)))))

;;; HTTP and translation backends --------------------------------------------

(defun ct--request-json (url method headers data)
  "Fetch URL with METHOD, extra HEADERS and request body DATA.
Return the JSON-decoded response body, or signal an error."
  (let ((url-request-method method)
         (url-request-extra-headers headers)
         (url-request-data data)
         (url-show-status nil))
    (let ((buf (url-retrieve-synchronously url)))
      (unless buf
        (error "comment-translator: request to %s failed" url))
      (with-current-buffer buf
        (goto-char (point-min))
        (if (re-search-forward "^\r?$" nil t)
          (condition-case nil
            (prog1 (if enable-multibyte-characters
                     (json-parse-buffer :object-type 'alist
                       :array-type 'list)
                     (json-parse-string
                       (decode-coding-string
                         (buffer-substring-no-properties (point) (point-max))
                         'utf-8)
                       :object-type 'alist :array-type 'list))
              (kill-buffer buf))
            (error
              (let ((body (buffer-substring-no-properties (point) (point-max))))
                (kill-buffer buf)
                (error "comment-translator: bad JSON from %s: %s"
                  url (string-trim (truncate-string-to-width body 200))))))
          (let ((body (buffer-substring-no-properties (point-min) (point-max))))
            (kill-buffer buf)
            (error "comment-translator: HTTP failure for %s: %s"
              url (string-trim (truncate-string-to-width body 200)))))))))

(defun ct--google-translate (text)
  "Translate TEXT with the free Google Translate endpoint."
  (let* ((url (concat "https://translate.googleapis.com/translate_a/single"
                "?client=gtx"
                "&sl=" (url-hexify-string comment-translator-source-language)
                "&tl=" (url-hexify-string comment-translator-target-language)
                "&dt=t&q=" (url-hexify-string text)))
          (json (ct--request-json url "GET"
                  '(("Accept-Encoding" . "identity")
                     ("Accept" . "application/json"))
                  nil)))
    (unless (listp json)
      (error "comment-translator: unexpected Google response %S" json))
    (mapconcat (lambda (seg) (if (listp seg) (or (car seg) "") ""))
      (car json) "")))

(defun ct--mymemory-translate (text)
  "Translate TEXT with the free MyMemory API."
  (let* ((pair (concat comment-translator-source-language "|"
                 comment-translator-target-language))
          (url (concat "https://api.mymemory.translated.net/get"
                 "?q=" (url-hexify-string text)
                 "&langpair=" (url-hexify-string pair)
                 (when comment-translator-mymemory-email
                   (concat "&de="
                     (url-hexify-string comment-translator-mymemory-email)))))
          (json (ct--request-json url "GET"
                  '(("Accept-Encoding" . "identity"))
                  nil))
          (data (cdr (assoc 'responseData json)))
          (result (cdr (assoc 'translatedText data))))
    (unless (and result (not (string-empty-p result)))
      (error "comment-translator: MyMemory error: %S"
        (or (cdr (assoc 'responseDetails json)) json)))
    (ct--unescape-entities result)))

(defun ct--merge-alists (base extra)
  "Merge alists BASE and EXTRA; entries of EXTRA win on duplicate keys."
  (let ((result (copy-sequence base)))
    (dolist (pair extra)
      (setq result (cl-remove (car pair) result :key #'car))
      (push pair result))
    (nreverse result)))

(defun ct--openai-translate (text)
  "Translate TEXT with an OpenAI-compatible chat completions API."
  (unless comment-translator-openai-api-key
    (user-error "comment-translator: set `comment-translator-openai-api-key' first"))
  (let* ((url (concat (string-remove-suffix "/" comment-translator-openai-base-url)
                "/chat/completions"))
          (system-prompt
            (format (concat "You are a code-comment translator. "
                      "Translate the user's comment from %s to %s. "
                      "Reply with ONLY the translation. "
                      "Keep code identifiers, URLs and markers such as "
                      "TODO/FIXME/NOTE/param unchanged. "
                      "Keep the line structure when the input has several lines. "
                      "Never add explanations, quotes or a language tag.")
              comment-translator-source-language
              comment-translator-target-language))
          (base-alist `((model . ,comment-translator-openai-model)
                         (messages . ,(vector `((role . "system") (content . ,system-prompt))
                                        `((role . "user") (content . ,text))))))
          (alist (ct--merge-alists base-alist comment-translator-openai-extra-args))
          (payload (json-encode alist))
          (json (ct--request-json url "POST"
                  `(("Content-Type" . "application/json")
                     ("Authorization" . ,(concat "Bearer " comment-translator-openai-api-key)))
                  payload))
          (choices (cdr (assoc 'choices json)))
          (message (cdr (assoc 'message (car choices)))))
    (unless message
      (error "comment-translator: OpenAI API error: %S" json))
    (let ((content (cdr (assoc 'content message))))
      (unless content
        (error "comment-translator: OpenAI returned no content: %S" json))
      content)))

(defun ct-translate (text)
  "Translate TEXT with the configured backend, using the cache.
Return nil when the backend produced nothing useful."
  (let* ((glossed (ct--apply-glossary text))
          (key (ct--cache-key glossed))
          (cached (gethash key ct--cache))
          (translated (or cached
                        (pcase comment-translator-backend
                          ('google (ct--google-translate glossed))
                          ('mymemory (ct--mymemory-translate glossed))
                          ('openai (ct--openai-translate glossed))
                          ((pred functionp)
                            (funcall comment-translator-backend glossed))
                          (_ (error "comment-translator: unknown backend: %S"
                               comment-translator-backend))))))
    (when (and (stringp translated)
            (not (string-empty-p (string-trim translated))))
      (setq translated (string-trim translated "[ \t\r]+" "[ \t\r]+"))
      (unless cached
        (puthash key translated ct--cache))
      translated)))

;;; Comment scanning ---------------------------------------------------------

(defun ct-comment-regions (&optional beg end)
  "Return the list of (BEG . END) spans of comments between BEG and END.
END is exclusive and never includes the terminating newline of a line
comment; the terminator of a block comment is included.  Comments are
found with the current major mode's syntax table, so this works for
every language Emacs supports."
  (save-excursion
    (goto-char (or beg (point-min)))
    (let* ((limit (or end (point-max)))
            (pos (point))
            (state (syntax-ppss))
            in-comment start regions)
      ;; NB: `parse-partial-sexp' moves point to its TO argument in some
      ;; Emacs versions, so the loop tracks position explicitly.
      (while (< pos limit)
        (setq state (parse-partial-sexp pos (1+ pos) nil nil state))
        (let ((now (nth 4 state)))
          (cond
            ((and now (not in-comment))
              (setq in-comment t
                start (or (nth 8 state) pos)))
            ((and (not now) in-comment)
              (setq in-comment nil)
              (push (cons start
                      (if (memq (char-after pos) '(?\n ?\r))
                        pos          ; line comment: newline excluded
                        (1+ pos)))    ; block comment: terminator included
                regions))))
        (setq pos (1+ pos)))
      (when in-comment
        ;; Comment runs to the end of the scanned region (unterminated
        ;; block comment or a line comment at end of buffer).
        (push (cons start limit) regions))
      (nreverse regions))))

(defun ct-comment-at-point ()
  "Return (BEG . END) of the comment containing point, or nil."
  (when (nth 4 (syntax-ppss))
    (let ((start (or (nth 8 (syntax-ppss)) (point))))
      (save-excursion
        (let ((pos (point))
               (limit (point-max))
               (state (syntax-ppss)))
          (while (and (< pos limit) (nth 4 state))
            (setq state (parse-partial-sexp pos (1+ pos) nil nil state))
            (setq pos (1+ pos)))
          (if (and (< pos limit) (not (nth 4 state)))
            (cons start (if (memq (char-after (1- pos)) '(?\n ?\r))
                          (1- pos)
                          pos))
            (cons start limit)))))))

(defun ct--buffer-has-chinese-comment-p ()
  "Return non-nil when the current buffer contains a Chinese comment."
  (when (ct-chinese-p (buffer-string))
    (cl-some (lambda (region)
               (ct-chinese-p (buffer-substring-no-properties
                               (car region) (cdr region))))
      (ct-comment-regions))))

;;; Comment analysis and rendering --------------------------------------------

(defun ct--analyze-comment (beg end)
  "Analyze the comment between BEG and END.
Return a plist with keys :prefix, :suffix, :decor and :lines.
:prefix is the comment-start marker, :suffix the comment-end marker,
:decor is the list of per-line decorations (indentation, \" * \"), and
:lines is the list of content lines with markers and decorations removed."
  (let* ((text (buffer-substring-no-properties beg end))
          (lines (split-string text "\n"))
          (start-skip (or comment-start-skip
                        (concat (regexp-quote (or comment-start "//")) "+")))
          (comment-end (or comment-end ""))
          (block-p (and (not (string-empty-p comment-end))
                     (string-match-p
                       (regexp-quote (string-trim (or comment-start "/*")))
                       text)))
          (prefix "") (suffix ""))
    (when (string-match (concat "\\`" start-skip) (car lines))
      (setq prefix (match-string 0 (car lines))
        lines (cons (substring (car lines) (match-end 0)) (cdr lines))))
    (when block-p
      (let ((last (car (last lines))))
        (when (string-match (concat "[ \t]*" (regexp-quote comment-end)
                              "[ \t]*\\'")
                last)
          (setq suffix (match-string 0 last))
          (setcar (last lines) (substring last 0 (match-beginning 0))))))
    (let (decors contents)
      (dolist (line lines)
        (let ((decor ""))
          (when (string-match "\\`[ \t]*\\(\\*+[ \t]*\\)?" line)
            (setq decor (match-string 0 line)
              line (substring line (match-end 0))))
          (push decor decors)
          (push line contents)))
      (list :prefix prefix :suffix suffix
        :decor (nreverse decors) :lines (nreverse contents)))))

(defun ct--render (analysis translated)
  "Rebuild the comment text from ANALYSIS and TRANSLATED content.
TRANSLATED contains one string per content line, separated by newlines."
  (let* ((prefix (or (plist-get analysis :prefix) ""))
          (suffix (or (plist-get analysis :suffix) ""))
          (decors (plist-get analysis :decor))
          (orig-lines (plist-get analysis :lines))
          (tlines (split-string translated "\n"))
          ;; The original first line was empty (the opener "/*" sat alone)
          ;; but the translation dropped it: put the opener on its own
          ;; line and shift the decoration alignment by one.
          (empty-first (and orig-lines
                         (string-empty-p (car orig-lines))
                         tlines
                         (not (string-empty-p (car tlines)))))
          ;; Symmetric case: the original last line was empty (the closer
          ;; "*/" sat alone) but the translation dropped it.
          (empty-last (and orig-lines
                        (> (length orig-lines) 1)
                        (not (string-empty-p suffix))
                        (string-empty-p (car (last orig-lines)))
                        tlines
                        (not (string-empty-p (car (last tlines))))))
          (last-decor (or (car (last decors)) ""))
          (rendered nil)
          (i 0))
    (dolist (tline tlines)
      (let ((idx (if empty-first (1+ i) i)))
        (push (concat (if (< idx (length decors)) (nth idx decors) last-decor)
                tline)
          rendered))
      (cl-incf i))
    (setq rendered (nreverse rendered))
    (when rendered
      (if empty-first
        (push prefix rendered)
        (setcar rendered (concat prefix (car rendered))))
      (if empty-last
        (setq rendered (nconc rendered (list (concat last-decor suffix))))
        (setcar (last rendered) (concat (car (last rendered)) suffix))))
    (mapconcat #'identity rendered "\n")))

;;; Translation of one comment -----------------------------------------------

(defun ct-translate-region (region)
  "Translate the comment REGION (BEG . END) in place.
Return non-nil when the buffer text changed."
  (let* ((beg (car region)) (end (cdr region))
          (analysis (ct--analyze-comment beg end))
          (content (mapconcat #'identity (plist-get analysis :lines) "\n"))
          (original (buffer-substring-no-properties beg end)))
    (when-let* ((translated (ct-translate content)))
      (let ((replacement (ct--render analysis translated)))
        (when (and comment-translator-bilingual
                (not ct--reverse)
                (string-empty-p (plist-get analysis :suffix))
                (not (string-match-p "\n" original)))
          (let ((indent (save-excursion
                          (goto-char beg)
                          (buffer-substring-no-properties
                            (line-beginning-position) beg))))
            (when (string-match-p "\\`[ \t]*\\'" indent)
              (setq replacement
                (concat original "\n" indent
                  (plist-get analysis :prefix)
                  comment-translator-bilingual-marker " "
                  translated)))))
        (unless (string= replacement original)
          (goto-char beg)
          (delete-region beg end)
          (insert replacement)
          (push (cons replacement original) ct--history)
          t)))))

(defun ct--needs-translation-p (region reverse)
  "Return non-nil when the comment REGION should be translated.
With REVERSE non-nil, detect English comments instead of Chinese ones."
  (let* ((analysis (ct--analyze-comment (car region) (cdr region)))
          (content (mapconcat #'identity (plist-get analysis :lines) "\n")))
    (and (not (and comment-translator-skip-regexp
                (string-match-p comment-translator-skip-regexp content)))
      (if reverse
        (string-match-p "[A-Za-z]{2,}" content)
        (ct-chinese-p content)))))

(defun ct--next-line-comment-content ()
  "Return the content of the comment on the next line, or nil."
  (save-excursion
    (forward-line 1)
    (when-let* ((span (car (ct-comment-regions
                             (line-beginning-position) (line-end-position)))))
      (let ((a (ct--analyze-comment (car span) (cdr span))))
        (string-trim (mapconcat #'identity (plist-get a :lines) "\n"))))))

(defun ct--bilingual-already-translated-p (region)
  "Non-nil when REGION is a Chinese comment already followed by its [en] line."
  (when comment-translator-bilingual
    (save-excursion
      (goto-char (cdr region))
      (let ((next (ct--next-line-comment-content)))
        (and next (string-prefix-p comment-translator-bilingual-marker next))))))

;;; Batch translation ----------------------------------------------------------

(defun ct-translate-comments-in-region (beg end &optional reverse)
  "Translate the comments between BEG and END.
With REVERSE non-nil, translate English comments back to Chinese.
Return the number of translated comments."
  (when (ct-disabled-p)
    (user-error "comment-translator: disabled in `%s'" major-mode))
  (let* ((ct--reverse (and reverse t))
          (comment-translator-source-language
            (if reverse comment-translator-target-language
              comment-translator-source-language))
          (comment-translator-target-language
            (if reverse comment-translator-source-language
              comment-translator-target-language))
          (has-chinese (or reverse
                         (ct-chinese-p (buffer-substring-no-properties
                                         beg end))))
          (regions (when has-chinese (ct-comment-regions beg end)))
          (total (length regions))
          (count 0) (failed 0))
    (when (> total 1)
      (message "comment-translator: translating %d comments..." total))
    ;; Translate from the bottom up so earlier region positions stay valid.
    (dolist (region (nreverse regions))
      (condition-case err
        (when (and (ct--needs-translation-p region reverse)
                (not (ct--bilingual-already-translated-p region)))
          (when (ct-translate-region region)
            (setq count (1+ count))))
        (error
          (setq failed (1+ failed))
          (message "comment-translator: %s" (error-message-string err)))))
    (ct--cache-save)
    (when (or (> count 0) (> failed 0))
      (message "comment-translator: %d translated, %d failed%s"
        count failed
        (if (> failed 0) " (see *Messages*)" "")))
    count))

;;; Interactive commands -------------------------------------------------------

;;;###autoload
(defun comment-translator-translate-comment (&optional arg)
  "Translate the comment at point from Chinese to English.
With a prefix ARG, translate in the opposite direction (English -> Chinese)."
  (interactive "P")
  (let ((reverse (and arg t)))
    (if-let* ((region (ct-comment-at-point)))
      (if (ct--needs-translation-p region reverse)
        (let ((ct--reverse reverse)
               (comment-translator-source-language
                 (if reverse comment-translator-target-language
                   comment-translator-source-language))
               (comment-translator-target-language
                 (if reverse comment-translator-source-language
                   comment-translator-target-language)))
          (if (ct-translate-region region)
            (message "comment-translator: translated")
            (message "comment-translator: unchanged")))
        (message "comment-translator: nothing to translate here"))
      (message "comment-translator: no comment at point"))))

;;;###autoload
(defun comment-translator-translate-region (beg end &optional arg)
  "Translate the Chinese comments overlapping the region BEG..END.
With a prefix ARG, translate in the reverse direction (English -> Chinese)."
  (interactive "r\nP")
  (ct-translate-comments-in-region beg end arg))

;;;###autoload
(defun comment-translator-translate-buffer (&optional arg)
  "Translate all Chinese comments in the current buffer.
With a prefix ARG, translate English comments back to Chinese."
  (interactive "P")
  (ct-translate-comments-in-region (point-min) (point-max) arg))

;;;###autoload
(defun comment-translator-revert-comment ()
  "Restore the original Chinese text of the comment at point.
Works for comments translated in this Emacs session."
  (interactive)
  (if-let* ((region (ct-comment-at-point))
             (current (buffer-substring-no-properties (car region) (cdr region)))
             (entry (cl-find current ct--history :key #'car :test #'string=)))
    (progn
      (goto-char (car region))
      (delete-region (car region) (cdr region))
      (insert (cdr entry))
      (setq ct--history (cl-remove entry ct--history))
      (message "comment-translator: original comment restored"))
    (message "comment-translator: nothing to revert here")))

;;;###autoload
(defun comment-translator-clear-cache ()
  "Clear the translation cache, both in memory and on disk."
  (interactive)
  (clrhash ct--cache)
  (when (and comment-translator-cache-file
          (file-exists-p comment-translator-cache-file))
    (delete-file comment-translator-cache-file))
  (message "comment-translator: cache cleared"))

;;; Automatic mode ---------------------------------------------------------------

(defvar comment-translator-auto-mode nil
  "Non-nil when `comment-translator-auto-mode' is enabled.
Declared early so hook functions defined below can reference it.")

(defun ct--on-post-command ()
  "Translate a comment the user just finished typing and left.
Only fires when the comment text changed while point was inside it."
  (when (and comment-translator-auto-mode
          comment-translator-auto-on-write
          (not (ct-disabled-p)))
    (if (nth 4 (syntax-ppss))
      (progn
        (setq ct--edit-tick-in-comment (buffer-chars-modified-tick))
        (setq ct--current-comment (ct-comment-at-point)))
      (when (and ct--current-comment
              (not (equal ct--edit-tick-in-comment
                     (buffer-chars-modified-tick))))
        (let* ((old-region ct--current-comment)
                ;; Re-scan from the recorded start: if the opener survived,
                ;; we get a fresh span that reflects any edits.
                (span (car (ct-comment-regions (car old-region) (point-max)))))
          (setq ct--current-comment nil)
          (when (and span (= (car span) (car old-region)))
            (condition-case err
              (when (and (not (ct--bilingual-already-translated-p span))
                      (ct--needs-translation-p span nil))
                (ct-translate-region span))
              (error
                (message "comment-translator: %s" (error-message-string err))))))))))

(defun ct--on-save ()
  "Translate Chinese comments before the buffer is written to disk."
  (when (and comment-translator-auto-mode
          comment-translator-auto-on-save
          (not (ct-disabled-p)))
    (ct--translate-buffer-quietly)))

(defun ct--translate-buffer-quietly ()
  "Translate all Chinese comments in the current buffer, never signaling."
  (condition-case err
    (if comment-translator-auto-confirm
      (when (ct--buffer-has-chinese-comment-p)
        (if (y-or-n-p "comment-translator: translate Chinese comments? ")
          (ct-translate-comments-in-region (point-min) (point-max))
          (message "comment-translator: skipped")))
      (ct-translate-comments-in-region (point-min) (point-max)))
    (error (message "comment-translator: %s" (error-message-string err)))))

(defun ct--idle-tick (buffer)
  "Idle-timer function: translate BUFFER's Chinese comments, if any."
  (when (and (buffer-live-p buffer)
          (buffer-local-value 'comment-translator-auto-mode buffer))
    (with-current-buffer buffer
      (when (and (not (ct-disabled-p))
              (buffer-modified-p)
              (ct--buffer-has-chinese-comment-p))
        (ct--translate-buffer-quietly)))))

(defun ct--on-kill ()
  "Cancel the buffer's idle timer when the buffer is killed."
  (when (timerp ct--idle-timer)
    (cancel-timer ct--idle-timer)
    (setq ct--idle-timer nil)))

;;;###autoload
(define-minor-mode comment-translator-auto-mode
  "Automatically translate Chinese code comments into English.
When enabled:
- a comment is translated as soon as you finish typing it and move
  point out of it (`comment-translator-auto-on-write');
- Chinese comments are translated while Emacs is idle
  (`comment-translator-auto-on-idle');
- all Chinese comments are translated just before each save
  (`comment-translator-auto-on-save')."
  :lighter " CTrans"
  :group 'comment-translator
  (cond
    (comment-translator-auto-mode
      (add-hook 'post-command-hook #'ct--on-post-command nil t)
      (add-hook 'before-save-hook #'ct--on-save nil t)
      (add-hook 'kill-buffer-hook #'ct--on-kill nil t)
      (when (and comment-translator-auto-on-idle
              (> comment-translator-auto-idle-delay 0))
        (when (timerp ct--idle-timer)
          (cancel-timer ct--idle-timer))
        (setq ct--idle-timer
          (run-with-idle-timer comment-translator-auto-idle-delay t
            #'ct--idle-tick (current-buffer)))))
    (t
      (remove-hook 'post-command-hook #'ct--on-post-command t)
      (remove-hook 'before-save-hook #'ct--on-save t)
      (remove-hook 'kill-buffer-hook #'ct--on-kill t)
      (when (timerp ct--idle-timer)
        (cancel-timer ct--idle-timer)
        (setq ct--idle-timer nil)))))

(defun ct--turn-on-auto ()
  "Enable `comment-translator-auto-mode' for the current buffer."
  (when (and (not (minibufferp))
          (derived-mode-p 'prog-mode))
    (comment-translator-auto-mode 1)))

;;;###autoload
(define-globalized-minor-mode comment-translator-global-auto-mode
  comment-translator-auto-mode ct--turn-on-auto
  :group 'comment-translator)

;;; Setup -----------------------------------------------------------------------

(ct--cache-load)
(add-hook 'kill-emacs-hook #'ct--cache-save)

(provide 'comment-translator)
;;; comment-translator.el ends here
