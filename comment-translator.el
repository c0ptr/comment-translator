;;; comment-translator.el --- Translate code comments between languages -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026  c0ptr

;; Author: c0ptr
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, languages, tools
;; URL: https://github.com/c0ptr/comment-translator

;;; Commentary:

;; comment-translator 把代码注释从任意语言翻译成英文（source-language 默认 auto 自动识别源语言）。
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
;;     C-u M-x comment-translator-translate-buffer  反向：目标语言 -> 源语言
;;     M-x comment-translator-revert-comment        撤销：恢复本次会话内翻译的原文
;;     M-x comment-translator-setup                 配置向导：选提供商、填 key
;;
;; 自动模式 (Automatic mode):
;;
;;     (add-hook 'prog-mode-hook #'comment-translator-auto-mode)
;;     ;; 或全局启用（仅编程模式）：
;;     ;; (comment-translator-global-auto-mode 1)
;;
;; 阅读模式 (Read mode) —— 英文注释旁浮层显示中文，不改文件，关掉即恢复:
;;
;;     M-x comment-translator-read-mode      ;; 在当前 buffer 开启
;;     M-x comment-translator-read-refresh   ;; 立即翻译可见区域
;;     C-u -1 M-x comment-translator-read-mode  ;; 关闭并清除所有浮层
;;
;;     目标语言: comment-translator-read-mode-target-language（默认 "zh-CN"）
;;
;; Translation backends (`comment-translator-backend'):
;;
;; LLM API 提供商（各自需要 API key，支持环境变量）:
;;     deepseek -- DeepSeek
;;     openai   -- ChatGPT (OpenAI)
;;     qwen     -- 通义千问 (阿里云百炼 DashScope)
;;     kimi     -- Kimi (Moonshot)
;;     doubao   -- 豆包 (火山引擎 Ark)
;;     mimo     -- 小米 MiMo
;;     gemini   -- Google Gemini（原生 generateContent 协议）
;;     claude   -- Claude (Anthropic，原生 Messages 协议)
;;     auto     -- 自动选用第一家配好 key 的提供商（默认）
;;
;; 自定义函数
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup comment-translator nil
  "Translate code comments from any source language into English."
  :group 'convenience
  :prefix "comment-translator-")

;;; Options ----------------------------------------------------------------

(defcustom comment-translator-backend 'auto
  "Translation backend to use.
`auto'       -- pick the first LLM provider that has an API key
                configured (option or environment variable); when none
                has one, commands explain how to configure a key.
LLM providers (each needs its own `comment-translator-<name>-api-key'
option or the conventional environment variable):
  `deepseek'  -- DeepSeek (OpenAI-compatible).
  `openai'    -- ChatGPT by OpenAI.
  `qwen'      -- 通义千问 Qwen / Alibaba DashScope (OpenAI-compatible).
  `kimi'      -- Kimi / Moonshot (OpenAI-compatible).
  `doubao'    -- 豆包 Doubao / Volcano Engine Ark (OpenAI-compatible).
  `mimo'      -- 小米 MiMo (OpenAI-compatible).
  `gemini'    -- Google Gemini (native generateContent API).
  `claude'    -- Claude / Anthropic (native Messages API).
A function  -- called with one string argument; must return the translation."
  :type '(choice (const :tag "Auto (first provider with a key)" auto)
                 (const :tag "DeepSeek" deepseek)
                 (const :tag "ChatGPT (OpenAI)" openai)
                 (const :tag "通义千问 (Qwen)" qwen)
                 (const :tag "Kimi (Moonshot)" kimi)
                 (const :tag "豆包 (Doubao)" doubao)
                 (const :tag "小米 MiMo" mimo)
                 (const :tag "Gemini (Google)" gemini)
                 (const :tag "Claude (Anthropic)" claude)
                 (function :tag "Custom function")))

(defcustom comment-translator-source-language 'auto
  "Language of the comments to translate.
`auto' (the default) detects the source automatically: any comment whose
script is not the target language's script is translated, which covers
Chinese, Japanese, Korean, Russian, Greek, Arabic, Hebrew, Thai, Hindi
and more with no configuration.  A concrete code such as \"ja\", \"ko\",
\"ru\" or \"zh-CN\" restricts detection to that language and is passed
verbatim to the backend.  For Latin-script languages (\"fr\", \"de\",
\"es\", ...) every Latin comment is considered; LLM backends usually
leave already-English comments unchanged."
  :type '(choice (const :tag "Auto-detect" auto) string))

(defcustom comment-translator-target-language "en"
  "Target language, as expected by the active backend."
  :type 'string)

(defcustom comment-translator-glossary nil
  "Alist of (TERM . TRANSLATION) pairs that must be kept unchanged.
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
  "When non-nil, keep the original comment line under the translated one.
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

(defcustom comment-translator-cache-max-entries 5000
  "Maximum number of entries kept in the on-disk translation cache.
When the cache grows beyond this, the oldest entries are dropped."
  :type 'integer)

(defcustom comment-translator-auto-on-write t
  "When non-nil, translate a comment as soon as you finish typing it.
`comment-translator-auto-mode' watches for the moment you edit a comment
and then move point out of it."
  :type 'boolean)

(defcustom comment-translator-auto-on-idle t
  "When non-nil, translate comments while Emacs is idle.
Only buffers that are already modified are touched."
  :type 'boolean)

(defcustom comment-translator-auto-idle-delay 5
  "Seconds of idle time before automatic translation kicks in."
  :type 'number)

(defcustom comment-translator-auto-on-save t
  "When non-nil, translate all comments just before each save."
  :type 'boolean)

(defcustom comment-translator-auto-on-save-async t
  "When non-nil, saving never waits for the network.
Cached translations are applied immediately before the save; comments
without a cached translation are requested asynchronously and applied
after the save finishes (the buffer is then modified again)."
  :type 'boolean)

(defcustom comment-translator-max-buffer-size 2097152
  "Buffers larger than this many characters are skipped by automatic
translation.  Set to nil to disable the limit."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom comment-translator-error-throttle 60
  "Seconds between repeated automatic-translation error messages."
  :type 'number)

(defcustom comment-translator-auto-confirm nil
  "When non-nil, automatic translation asks for confirmation first."
  :type 'boolean)

(defcustom comment-translator-read-mode-source-language "en"
  "Source language for `comment-translator-read-mode'."
  :type 'string)

(defcustom comment-translator-read-mode-target-language "zh-CN"
  "Language that `comment-translator-read-mode' translates comments into.
Set this to your native language."
  :type 'string)

(defcustom comment-translator-read-mode-skip-regexp nil
  "Comments matching this regexp are not translated by read mode.
Read mode already skips comments written in the target language's
script; set this to an extra regexp for further exclusions."
  :type '(choice (const :tag "None" nil) regexp))

(defcustom comment-translator-read-mode-persist-cache nil
  "When non-nil, read-mode translations are written to the disk cache.
Off by default so comments from code you merely read do not end up in
your cache file."
  :type 'boolean)

(defcustom comment-translator-read-mode-idle-delay 0.6
  "Seconds of idle time before read mode translates visible comments."
  :type 'number)

(defcustom comment-translator-read-mode-max-batch 12
  "Maximum number of comments translated per read-mode request."
  :type 'integer)

(defface comment-translator-read-face
  '((t :inherit shadow :slant italic))
  "Face used for translations shown by `comment-translator-read-mode'."
  :group 'comment-translator)

(defcustom comment-translator-openai-api-key nil
  "API key for the `openai' backend (ChatGPT).
See https://platform.openai.com/api-keys"
  :type '(choice (const :tag "Unset" nil) string))

(defcustom comment-translator-openai-base-url "https://api.openai.com/v1"
  "Base URL of the OpenAI API used by the `openai' backend."
  :type 'string)

(defcustom comment-translator-openai-model "gpt-4o-mini"
  "Model name for the `openai' backend."
  :type 'string)

(define-obsolete-variable-alias 'comment-translator-openai-extra-args
  'comment-translator-llm-extra-args "0.1.0")

(defcustom comment-translator-llm-extra-args nil
  "Extra alist of JSON fields merged into the chat-completions request
of OpenAI-compatible LLM backends.
For example: ((temperature . 0.2)).  Entries override built-in ones."
  :type 'alist)

(defmacro ct--define-provider-options (provider name base-url model &optional model-note)
  "Define the three options for the LLM provider PROVIDER.
NAME is the human-readable provider name, BASE-URL and MODEL the defaults."
  (let ((key-var (intern (format "comment-translator-%s-api-key" provider)))
        (url-var (intern (format "comment-translator-%s-base-url" provider)))
        (model-var (intern (format "comment-translator-%s-model" provider)))
        (key-doc (format "API key for the `%s' backend (%s)." provider name))
        (url-doc (format "Base URL for the `%s' backend (%s)." provider name))
        (model-doc (format "Model name for the `%s' backend (%s).%s"
                           provider name (or model-note ""))))
    `(progn
       (defcustom ,key-var nil ,key-doc
         :type '(choice (const :tag "Unset" nil) string))
       (defcustom ,url-var ,base-url ,url-doc
         :type 'string)
       (defcustom ,model-var ,model ,model-doc
         :type 'string))))

(ct--define-provider-options deepseek "DeepSeek"
  "https://api.deepseek.com/v1" "deepseek-chat")

(ct--define-provider-options qwen "通义千问 Qwen"
  "https://dashscope.aliyuncs.com/compatible-mode/v1" "qwen-plus"
  "  Cheaper: qwen-turbo.")

(ct--define-provider-options kimi "Kimi / Moonshot"
  "https://api.moonshot.cn/v1" "moonshot-v1-8k")

(ct--define-provider-options doubao "豆包 Doubao"
  "https://ark.cn-beijing.volces.com/api/v3" "doubao-1-5-pro-32k-250115"
  "  Or use an Ark endpoint id.")

(ct--define-provider-options mimo "小米 MiMo"
  "https://api.xiaomimimo.com/v1" "mimo-v2.6-pro")

(ct--define-provider-options gemini "Google Gemini"
  "https://generativelanguage.googleapis.com/v1beta" "gemini-2.5-flash"
  "  See https://ai.google.dev/gemini-api/docs/models for available names.")

(ct--define-provider-options claude "Claude / Anthropic"
  "https://api.anthropic.com/v1" "claude-3-5-haiku-latest")

(defcustom comment-translator-llm-batching t
  "When non-nil, several comments are translated in a single LLM request.
Saves tokens and requests; the plugin falls back to one request per
comment when the model does not follow the expected format."
  :type 'boolean)

(defcustom comment-translator-llm-batch-limit 1200
  "Max total characters per batched LLM request.
Larger batches mean fewer requests; smaller ones are more reliable."
  :type 'integer)

(defcustom comment-translator-request-timeout 30
  "Seconds to wait for an HTTP response before giving up."
  :type 'number)

(defcustom comment-translator-max-concurrent-requests 2
  "Maximum number of simultaneous asynchronous HTTP requests."
  :type 'integer)

(defcustom comment-translator-retry-attempts 1
  "How many times to retry transient async request failures.
Transient failures include HTTP 429, HTTP 5xx and connection errors."
  :type 'integer)

(defcustom comment-translator-retry-delay 0.5
  "Seconds to wait before retrying a failed asynchronous request."
  :type 'number)

(defconst ct--batch-marker "<<<CT-END>>>"
  "Delimiter separating comments inside a batched LLM request.")

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

(defconst ct--non-latin-scripts
  '(han kana hangul cjk-misc cyrillic greek arabic hebrew thai devanagari)
  "Emacs script symbols treated as non-English by automatic detection.")

(defconst ct--cjk-punct-regexp "[，。！？、；：“”‘’（）《》【】—…]"
  "Fullwidth punctuation used by CJK comments.")

(defun ct--text-has-script-p (text scripts)
  "Return non-nil when TEXT contains a character of one of SCRIPTS.
SCRIPTS is a list of Emacs script symbols such as `han' or `cyrillic'."
  (catch 'ct-script-found
    (let ((table char-script-table))
      (seq-do (lambda (ch)
                (when (memq (aref table ch) scripts)
                  (throw 'ct-script-found t)))
              text))
    nil))

(defun ct--language-scripts (code)
  "Return the Emacs script symbols for the language CODE.
CODE may be the symbol `auto', which covers every non-Latin script, or a
string such as \"ja\" or \"ru\".  Latin-script languages return
`(latin)'."
  (cond
   ((eq code 'auto) ct--non-latin-scripts)
   ((stringp code)
    (cond
     ((string-prefix-p "zh" code) '(han cjk-misc))
     ((string-prefix-p "ja" code) '(han kana cjk-misc))
     ((string-prefix-p "ko" code) '(hangul))
     ((member code '("ru" "uk" "be" "bg" "sr" "mk" "mn" "kk")) '(cyrillic))
     ((string-prefix-p "el" code) '(greek))
     ((string-prefix-p "ar" code) '(arabic))
     ((string-prefix-p "he" code) '(hebrew))
     ((string-prefix-p "th" code) '(thai))
     ((member code '("hi" "mr" "ne" "sa")) '(devanagari))
     ((member code '("bn" "as")) '(bengali))
     ((member code '("ta" "te" "kn" "ml" "si"))
      '(tamil telugu kannada malayalam sinhala))
     (t '(latin))))
   (t '(latin))))

(defun ct-chinese-p (text)
  "Return non-nil when TEXT contains Chinese characters."
  (and (stringp text)
       (or (ct--text-has-script-p text '(han))
           (string-match-p ct--cjk-punct-regexp text))))

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

;;; Cache -------------------------------------------------------------------

(defconst ct--cache-schema "2"
  "Cache schema version.
Bump this when the prompt or the key format changes so old entries stop
matching.")

(defvar ct--cache-seq (make-hash-table :test #'equal)
  "Insertion sequence numbers for cache entries (oldest first).")
(defvar ct--cache-seq-counter 0
  "Monotonic counter for `ct--cache-seq'.")
(defvar ct--read-keys (make-hash-table :test #'equal)
  "Cache keys created by read mode.
They are kept out of the on-disk cache unless
`comment-translator-read-mode-persist-cache' is non-nil.")

(defun ct--backend-model ()
  "Return the model name of the effective backend, or an empty string."
  (let ((backend (ct--resolve-backend)))
    (cond
     ((ct--openai-backend-p backend)
      (or (plist-get (ct--openai-provider-settings backend) :model) ""))
     ((eq backend 'gemini) comment-translator-gemini-model)
     ((eq backend 'claude) comment-translator-claude-model)
     (t ""))))

(defun ct--cache-key (text)
  "Return the cache key for TEXT under the current settings."
  (format "%s|%S|%s|%s>%s|%s"
          ct--cache-schema
          (ct--resolve-backend)
          (ct--backend-model)
          comment-translator-source-language
          comment-translator-target-language
          text))

(defun ct--cache-put (key value)
  "Store VALUE under KEY and remember its insertion order."
  (puthash key value ct--cache)
  (puthash key (cl-incf ct--cache-seq-counter) ct--cache-seq))

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
                  (ct--cache-put (car pair) (cdr pair)))))))
      (error (message "comment-translator: could not read cache: %S" err)))))

(defun ct--cache-prune ()
  "Drop the oldest cache entries beyond `comment-translator-cache-max-entries'."
  (when (and (integerp comment-translator-cache-max-entries)
             (> (hash-table-count ct--cache)
                comment-translator-cache-max-entries))
    (let (entries)
      (maphash (lambda (key seq) (push (cons seq key) entries)) ct--cache-seq)
      (setq entries (sort entries (lambda (a b) (< (car a) (car b)))))
      (while (and entries
                  (> (hash-table-count ct--cache)
                     comment-translator-cache-max-entries))
        (let ((key (cdr (pop entries))))
          (remhash key ct--cache)
          (remhash key ct--read-keys))))))

(defun ct--cache-save ()
  "Persist the translation cache."
  (when (and comment-translator-cache-enabled
             comment-translator-cache-file)
    (condition-case err
        (progn
          (ct--cache-prune)
          (let (pairs)
            (maphash (lambda (key value)
                       (unless (and (not comment-translator-read-mode-persist-cache)
                                    (gethash key ct--read-keys))
                         (push (cons key value) pairs)))
                     ct--cache)
            (with-temp-buffer
              (insert ";; -*- emacs-lisp -*- comment-translator cache\n")
              (prin1 (nreverse pairs) (current-buffer))
              (insert "\n")
              (write-region (point-min) (point-max) comment-translator-cache-file))
            (ignore-errors
              (set-file-modes comment-translator-cache-file #o600))))
      (error (message "comment-translator: could not save cache: %S" err)))))

;;; HTTP and translation backends --------------------------------------------

(defun ct--json-ascii-safe (json)
  "Return JSON with every non-ASCII character escaped as \\uXXXX.
Astral characters become proper surrogate pairs.  The result is pure
ASCII, which every version of url.el accepts as an HTTP request body.
The escapes are built with `format' rather than replacement strings, so
`replace-regexp-in-string' cannot reinterpret \\u as a case operator."
  (let ((result nil)
        (len (length json))
        (i 0))
    (while (< i len)
      (let ((c (aref json i)))
        (if (< c 128)
            (push (char-to-string c) result)
          (if (< c #x10000)
              (push (format "\\u%04x" c) result)
            (let ((cp (- c #x10000)))
              (push (format "\\u%04x\\u%04x" (+ #xD800 (ash cp -10))
                            (+ #xDC00 (logand cp #x3FF)))
                    result)))))
      (setq i (1+ i)))
    (apply #'concat (nreverse result))))

(defun ct--request-json (url method headers data)
  "Fetch URL with METHOD, extra HEADERS and request body DATA.
DATA must be a JSON string (or nil).  Return the JSON-decoded response
body, or signal an error."
  ;; url.el refuses multibyte request bodies (its Bug#23750 check), so the
  ;; body is sent as pure-ASCII JSON in a unibyte UTF-8 string.
  (let ((url-request-method method)
        (url-request-extra-headers headers)
        ;; Never prompt for credentials interactively (e.g. on HTTP 401).
        (url-request-noninteractive t)
        (url-request-data (when data
                            (encode-coding-string
                             (ct--json-ascii-safe data) 'utf-8)))
        (url-show-status nil))
    (let ((buf (url-retrieve-synchronously
                url nil nil comment-translator-request-timeout)))
      (unless buf
        (error "comment-translator: no response from %s (timeout %ss)"
               url comment-translator-request-timeout))
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

(defun ct--merge-alists (base extra)
  "Merge alists BASE and EXTRA; entries of EXTRA win on duplicate keys."
  (let ((result (copy-sequence base)))
    (dolist (pair extra)
      (setq result (cl-remove (car pair) result :key #'car))
      (push pair result))
    (nreverse result)))

(defconst ct--env-key-alist
  '((openai . "OPENAI_API_KEY")
    (deepseek . "DEEPSEEK_API_KEY")
    (qwen . "DASHSCOPE_API_KEY")
    (kimi . "MOONSHOT_API_KEY")
    (doubao . "ARK_API_KEY")
    (mimo . "MIMO_API_KEY")
    (gemini . "GEMINI_API_KEY")
    (claude . "ANTHROPIC_API_KEY"))
  "Environment variables holding the API key of each LLM provider.")

(defconst ct--auto-provider-order
  '(deepseek openai qwen kimi doubao mimo gemini claude)
  "Order in which the `auto' backend looks for a configured provider.")

(defun ct--provider-key (provider)
  "Return the API key for the LLM PROVIDER.
Checks the `comment-translator-<provider>-api-key' option first, then
the conventional environment variable."
  (or (symbol-value (intern (format "comment-translator-%s-api-key" provider)))
      (let ((env (cdr (assq provider ct--env-key-alist))))
        (and env (getenv env)))))

(defun ct--resolve-backend ()
  "Return the effective backend, resolving the symbol `auto'.
With `auto', use the first LLM provider that has an API key configured
(option or environment variable); return nil when none has one."
  (if (eq comment-translator-backend 'auto)
      (cl-find-if #'ct--provider-key ct--auto-provider-order)
    comment-translator-backend))

(defun ct--no-key-message ()
  "Return the message shown when no provider has an API key."
  (concat "comment-translator: no API key configured. "
          "Run `M-x comment-translator-setup', or set an environment "
          "variable such as DEEPSEEK_API_KEY or OPENAI_API_KEY."))

(defconst ct--language-names
  '(("zh-CN" . "Chinese") ("zh-TW" . "Traditional Chinese") ("zh" . "Chinese")
    ("ja" . "Japanese") ("ko" . "Korean") ("ru" . "Russian")
    ("uk" . "Ukrainian") ("el" . "Greek") ("fr" . "French")
    ("de" . "German") ("es" . "Spanish") ("pt" . "Portuguese")
    ("it" . "Italian") ("nl" . "Dutch") ("pl" . "Polish")
    ("tr" . "Turkish") ("ar" . "Arabic") ("he" . "Hebrew")
    ("hi" . "Hindi") ("th" . "Thai") ("vi" . "Vietnamese")
    ("id" . "Indonesian") ("en" . "English"))
  "Human-readable names for common language codes in LLM prompts.")

(defun ct--language-label (code)
  "Return a human-readable label for the language CODE."
  (cond
   ((eq code 'auto) "the detected source language")
   ((cdr (assoc code ct--language-names)))
   ((stringp code) (format "\"%s\"" code))
   (t (format "%s" code))))

(defun ct--llm-system-prompt (&optional extra)
  "Return the compact system prompt shared by every LLM backend.
EXTRA, when non-nil, is appended (used by batched requests)."
  (concat (if (eq comment-translator-source-language 'auto)
              (format (concat "Translate code comments into %s. Detect the "
                              "source language automatically. ")
                      (ct--language-label comment-translator-target-language))
            (format "Translate code comments from %s to %s. "
                    (ct--language-label comment-translator-source-language)
                    (ct--language-label comment-translator-target-language)))
          "Reply with only the translation. "
          "Keep identifiers and TODO/FIXME/NOTE markers unchanged."
          (if extra (concat " " extra) "")))

(defun ct--output-limit (text)
  "Return a sensible maximum number of output tokens for translating TEXT.
Caps the reply (and its cost) while leaving generous headroom."
  (max 32 (min 2048 (* 2 (length text)))))

(defun ct--openai-provider-settings (provider)
  "Return the plist (:key :base-url :model) of the OpenAI-compatible PROVIDER."
  (pcase provider
    ('openai (list :key (ct--provider-key 'openai)
                   :base-url comment-translator-openai-base-url
                   :model comment-translator-openai-model))
    ('deepseek (list :key (ct--provider-key 'deepseek)
                     :base-url comment-translator-deepseek-base-url
                     :model comment-translator-deepseek-model))
    ('qwen (list :key (ct--provider-key 'qwen)
                 :base-url comment-translator-qwen-base-url
                 :model comment-translator-qwen-model))
    ('kimi (list :key (ct--provider-key 'kimi)
                 :base-url comment-translator-kimi-base-url
                 :model comment-translator-kimi-model))
    ('doubao (list :key (ct--provider-key 'doubao)
                   :base-url comment-translator-doubao-base-url
                   :model comment-translator-doubao-model))
    ('mimo (list :key (ct--provider-key 'mimo)
                 :base-url comment-translator-mimo-base-url
                 :model comment-translator-mimo-model))))

(defun ct--openai-backend-p (backend)
  "Return non-nil when BACKEND is an OpenAI-compatible provider."
  (memq backend '(openai deepseek qwen kimi doubao mimo)))

(defun ct--openai-provider-spec (provider text &optional system-extra)
  "Return the request plist (:url :method :headers :payload) for PROVIDER."
  (let* ((settings (ct--openai-provider-settings provider))
         (api-key (plist-get settings :key)))
    (unless api-key
      (user-error (concat "comment-translator: no API key for `%s'; set "
                          "`comment-translator-%s-api-key' or the %s "
                          "environment variable")
                  provider provider
                  (cdr (assq provider ct--env-key-alist))))
    (let* ((url (concat (string-remove-suffix "/" (plist-get settings :base-url))
                        "/chat/completions"))
           (base-alist `((model . ,(plist-get settings :model))
                         (max_tokens . ,(ct--output-limit text))
                         (messages . [((role . "system")
                                       (content . ,(ct--llm-system-prompt
                                                    system-extra)))
                                      ((role . "user") (content . ,text))])))
           (alist (ct--merge-alists base-alist comment-translator-llm-extra-args)))
      (list :url url
            :method "POST"
            :headers `(("Content-Type" . "application/json")
                       ("Authorization" . ,(concat "Bearer " api-key)))
            :payload (json-encode alist)))))

(defun ct--openai-parse (provider json)
  "Extract the translation from PROVIDER's response JSON."
  (let* ((choices (cdr (assoc 'choices json)))
         (message (cdr (assoc 'message (car choices)))))
    (unless message
      (error "comment-translator: %s API error: %S" provider json))
    (let ((content (cdr (assoc 'content message))))
      (unless content
        (error "comment-translator: %s returned no content: %S" provider json))
      content)))

(defun ct--openai-provider-translate (provider text &optional system-extra)
  "Translate TEXT with the OpenAI-compatible chat completions API of PROVIDER."
  (let ((spec (ct--openai-provider-spec provider text system-extra)))
    (ct--openai-parse provider
                      (ct--request-json (plist-get spec :url)
                                        (plist-get spec :method)
                                        (plist-get spec :headers)
                                        (plist-get spec :payload)))))

(defun ct--gemini-spec (text &optional system-extra)
  "Return the request plist for the native Gemini API."
  (let ((api-key (ct--provider-key 'gemini)))
    (unless api-key
      (user-error "comment-translator: set `comment-translator-gemini-api-key' \
or the GEMINI_API_KEY environment variable"))
    (list :url (concat (string-remove-suffix "/" comment-translator-gemini-base-url)
                       "/models/"
                       (url-hexify-string comment-translator-gemini-model)
                       ":generateContent?key="
                       (url-hexify-string api-key))
          :method "POST"
          :headers '(("Content-Type" . "application/json"))
          :payload
          (json-encode
           `((contents . [((role . "user")
                           (parts . [((text . ,text))]))])
             (systemInstruction . ((parts . [((text . ,(ct--llm-system-prompt
                                                        system-extra)))])))
             (generationConfig . ((maxOutputTokens . ,(ct--output-limit text)))))))))

(defun ct--gemini-parse (json)
  "Extract the translation from a Gemini response JSON."
  (let* ((candidates (cdr (assoc 'candidates json)))
         (content (cdr (assoc 'content (car candidates))))
         (parts (cdr (assoc 'parts content))))
    (unless parts
      (error "comment-translator: Gemini API error: %S" json))
    (mapconcat (lambda (part) (or (cdr (assoc 'text part)) "")) parts "")))

(defun ct--gemini-translate (text &optional system-extra)
  "Translate TEXT with the native Google Gemini API (generateContent)."
  (let ((spec (ct--gemini-spec text system-extra)))
    (ct--gemini-parse (ct--request-json (plist-get spec :url)
                                        (plist-get spec :method)
                                        (plist-get spec :headers)
                                        (plist-get spec :payload)))))

(defun ct--claude-spec (text &optional system-extra)
  "Return the request plist for the Anthropic Claude Messages API."
  (let ((api-key (ct--provider-key 'claude)))
    (unless api-key
      (user-error "comment-translator: set `comment-translator-claude-api-key' \
or the ANTHROPIC_API_KEY environment variable"))
    (list :url (concat (string-remove-suffix "/" comment-translator-claude-base-url)
                       "/messages")
          :method "POST"
          :headers `(("Content-Type" . "application/json")
                     ("x-api-key" . ,api-key)
                     ("anthropic-version" . "2023-06-01"))
          :payload
          (json-encode
           `((model . ,comment-translator-claude-model)
             (max_tokens . ,(ct--output-limit text))
             (system . ,(ct--llm-system-prompt system-extra))
             (messages . [((role . "user") (content . ,text))]))))))

(defun ct--claude-parse (json)
  "Extract the translation from a Claude response JSON."
  (let ((content (cdr (assoc 'content json))))
    (unless content
      (error "comment-translator: Claude API error: %S" json))
    (mapconcat (lambda (block) (or (cdr (assoc 'text block)) ""))
               content "")))

(defun ct--claude-translate (text &optional system-extra)
  "Translate TEXT with the native Anthropic Claude Messages API."
  (let ((spec (ct--claude-spec text system-extra)))
    (ct--claude-parse (ct--request-json (plist-get spec :url)
                                        (plist-get spec :method)
                                        (plist-get spec :headers)
                                        (plist-get spec :payload)))))

(defun ct--llm-spec (backend text &optional system-extra)
  "Return the request plist for the LLM BACKEND and TEXT."
  (pcase backend
    ('gemini (ct--gemini-spec text system-extra))
    ('claude (ct--claude-spec text system-extra))
    ((pred ct--openai-backend-p)
     (ct--openai-provider-spec backend text system-extra))))

(defun ct--llm-parse (backend json)
  "Extract a translation from BACKEND's response JSON."
  (pcase backend
    ('gemini (ct--gemini-parse json))
    ('claude (ct--claude-parse json))
    ((pred ct--openai-backend-p) (ct--openai-parse backend json))))

(defun ct--llm-backend-p (backend)
  "Return non-nil when BACKEND is one of the LLM providers."
  (or (ct--openai-backend-p backend)
      (memq backend '(gemini claude))))

(defun ct--llm-raw-translate (backend text &optional system-extra)
  "Translate TEXT with the LLM backend BACKEND (already resolved).
SYSTEM-EXTRA, when non-nil, is appended to the system prompt (used by
batched requests)."
  (pcase backend
    ('gemini (ct--gemini-translate text system-extra))
    ('claude (ct--claude-translate text system-extra))
    ((pred ct--openai-backend-p)
     (ct--openai-provider-translate backend text system-extra))))

(defun ct-translate (text)
  "Translate TEXT with the configured backend, using the cache.
Return nil when the backend produced nothing useful."
  (let* ((backend (ct--resolve-backend))
         (glossed (ct--apply-glossary text))
         (key (ct--cache-key glossed))
         (cached (gethash key ct--cache))
         (translated (or cached
                         (progn
                           (unless backend
                             (user-error (ct--no-key-message)))
                           (pcase backend
                             ((pred ct--llm-backend-p)
                              (ct--llm-raw-translate backend glossed))
                             ((pred functionp)
                              (funcall backend glossed))
                             (_ (error "comment-translator: unknown backend: %S"
                                       backend)))))))
    (when (and (stringp translated)
               (not (string-empty-p (string-trim translated))))
      (setq translated (string-trim translated "[ \t\r]+" "[ \t\r]+"))
      (unless cached
        (ct--cache-put key translated))
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

(defvar-local ct--source-comment-cache nil
  "Cons (TICK . RESULT) caching `ct--buffer-has-source-comment-p'.")
(defvar-local ct--size-warned nil
  "Non-nil once the buffer-too-large warning was shown.")
(defvar-local ct--last-error-time nil
  "Time of the last reported error in this buffer.")

(defun ct--buffer-too-large-p ()
  "Return non-nil when the buffer exceeds `comment-translator-max-buffer-size'."
  (and comment-translator-max-buffer-size
       (> (buffer-size) comment-translator-max-buffer-size)))

(defun ct--warn-buffer-too-large ()
  "Warn once that this buffer is too large for automatic translation."
  (unless ct--size-warned
    (setq ct--size-warned t)
    (message (concat "comment-translator: buffer larger than %s characters; "
                     "automatic translation skipped")
             comment-translator-max-buffer-size)))

(defun ct--report-error (err)
  "Report ERR, at most once per `comment-translator-error-throttle' seconds."
  (let ((now (float-time)))
    (unless (and ct--last-error-time
                 (< (- now ct--last-error-time)
                    comment-translator-error-throttle))
      (setq ct--last-error-time now)
      (message "comment-translator: %s (run M-x comment-translator-doctor)" err))))

(defun ct--buffer-has-source-comment-p ()
  "Return non-nil when the current buffer contains a translatable comment.
The result is cached per `buffer-chars-modified-tick' so repeated idle
and save hooks do not rescan an unchanged buffer."
  (let ((tick (buffer-chars-modified-tick)))
    (if (and ct--source-comment-cache
             (= (car ct--source-comment-cache) tick))
        (cdr ct--source-comment-cache)
      (let* ((scripts (ct--language-scripts comment-translator-source-language))
             (body (buffer-string))
             (pre (if (memq 'latin scripts)
                      (string-match-p "[A-Za-z]\\{2,\\}" body)
                    (ct--text-has-script-p body scripts)))
             (result (and (not (ct--buffer-too-large-p))
                          pre
                          (cl-some (lambda (region)
                                     (ct--needs-translation-p region nil))
                                   (ct-comment-regions)))))
        (setq ct--source-comment-cache (cons tick result))
        result))))

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

(defun ct-translate-region (region &optional translated)
  "Translate the comment REGION (BEG . END) in place.
TRANSLATED, when non-nil, is used instead of calling the backend
(used by batched translation).  Return non-nil when the text changed."
  (let* ((beg (car region)) (end (cdr region))
         (analysis (ct--analyze-comment beg end))
         (content (mapconcat #'identity (plist-get analysis :lines) "\n"))
         (original (buffer-substring-no-properties beg end)))
    (when-let* ((result (or translated (ct-translate content))))
      (let ((replacement (ct--render analysis result)))
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
                            result)))))
        (unless (string= replacement original)
          (goto-char beg)
          (delete-region beg end)
          (insert replacement)
          (push (cons replacement original) ct--history)
          t)))))

(defun ct--needs-translation-p (region &optional reverse from-language)
  "Return non-nil when the comment REGION should be translated.
The language to detect comes from FROM-LANGUAGE when given, otherwise
from `comment-translator-source-language' (or, with REVERSE non-nil,
from `comment-translator-target-language').  Latin-script sources match
text with at least two Latin letters; other scripts match via
`ct--text-has-script-p'."
  (let* ((analysis (ct--analyze-comment (car region) (cdr region)))
         (content (mapconcat #'identity (plist-get analysis :lines) "\n"))
         (scripts (ct--language-scripts
                   (or from-language
                       (if reverse comment-translator-target-language
                         comment-translator-source-language)))))
    (and (not (and comment-translator-skip-regexp
                   (string-match-p comment-translator-skip-regexp content)))
         (if (memq 'latin scripts)
             (string-match-p "[A-Za-z]\\{2,\\}" content)
           (ct--text-has-script-p content scripts)))))

(defun ct--check-reverse (reverse)
  "Signal an error when REVERSE is requested but there is no reverse target.
`auto' has no concrete language to translate back into."
  (when (and reverse (eq comment-translator-source-language 'auto))
    (user-error (concat "comment-translator: reverse translation needs a "
                        "concrete `comment-translator-source-language' "
                        "(`auto' has no target)"))))

(defun ct--next-line-comment-content ()
  "Return the content of the comment on the next line, or nil."
  (save-excursion
    (forward-line 1)
    (when-let* ((span (car (ct-comment-regions
                            (line-beginning-position) (line-end-position)))))
      (let ((a (ct--analyze-comment (car span) (cdr span))))
        (string-trim (mapconcat #'identity (plist-get a :lines) "\n"))))))

(defun ct--bilingual-already-translated-p (region)
  "Non-nil when REGION is a source-language comment already followed by
its [en] line."
  (when comment-translator-bilingual
    (save-excursion
      (goto-char (cdr region))
      (let ((next (ct--next-line-comment-content)))
        (and next (string-prefix-p comment-translator-bilingual-marker next))))))

;;; Batch translation ----------------------------------------------------------

(defun ct--llm-batch-instruction ()
  "Return the extra system prompt used for batched requests."
  (concat "The input contains several comments separated by lines with the "
          "marker " ct--batch-marker ". Reply with each translation separated "
          "by the same marker lines, in the same order, no other text."))

(defun ct--group-batches (pairs limit)
  "Group (REGION . CONTENT) pairs into batches of at most LIMIT chars."
  (let (batches current (size 0))
    (dolist (pair pairs)
      (let ((len (length (cdr pair))))
        (when (and current (> (+ size len) limit))
          (push (nreverse current) batches)
          (setq current nil size 0))
        (push pair current)
        (cl-incf size len)))
    (when current
      (push (nreverse current) batches))
    (nreverse batches)))

(defun ct--batch-join (texts)
  "Join TEXTS with the batch marker, sanitizing embedded markers."
  (mapconcat (lambda (text) (string-replace ct--batch-marker " " text))
             texts
             (concat "\n" ct--batch-marker "\n")))

(defun ct--batch-split (raw expected-count)
  "Split RAW into EXPECTED-COUNT translations, or return nil."
  (when (and raw (stringp raw))
    (let ((parts (cl-remove "" (mapcar #'string-trim
                                       (split-string
                                        raw
                                        (concat "[ \t\r\n]*"
                                                (regexp-quote ct--batch-marker)
                                                "[ \t\r\n]*")))
                            :test #'string=)))
      (when (= expected-count (length parts))
        parts))))

(defun ct--llm-batch-translate (backend texts)
  "Translate TEXTS in a single request to the LLM backend BACKEND.
Return the list of translations, or nil when the response does not
follow the marker format (the caller falls back to per-comment calls).
A single text skips the marker protocol entirely."
  (if (null (cdr texts))
      (list (ct--llm-raw-translate backend (car texts)))
    (let* ((joined (ct--batch-join texts))
           (raw (condition-case nil
                    (ct--llm-raw-translate backend joined
                                           (ct--llm-batch-instruction))
                  (error nil))))
      (ct--batch-split raw (length texts)))))

;;; Asynchronous requests -------------------------------------------------------

(cl-defstruct (ct--job (:constructor ct--job-create))
  key url method headers payload callback attempts done process timer)

(defvar ct--job-queue nil
  "Jobs waiting for a free request slot.")
(defvar ct--jobs-in-flight 0
  "Number of asynchronous requests currently running.")
(defvar ct--jobs-pending (make-hash-table :test #'equal)
  "Queued and in-flight jobs keyed by URL and payload.")
(defvar ct--cache-save-timer nil
  "Idle timer for a debounced cache save.")

(defun ct--request-key (url payload)
  "Return the deduplication key for a request to URL with PAYLOAD."
  (concat url "\0" (or payload "")))

(defun ct--job-end-attempt (job)
  "Release JOB's request slot and cancel its timeout timer."
  (when (timerp (ct--job-timer job))
    (cancel-timer (ct--job-timer job))
    (setf (ct--job-timer job) nil))
  (setq ct--jobs-in-flight (max 0 (1- ct--jobs-in-flight))))

(defun ct--job-notify (job json err)
  "Call JOB's callbacks with JSON and error ERR."
  (dolist (callback (nreverse (ct--job-callback job)))
    (condition-case e
        (funcall callback json err)
      (error (message "comment-translator: callback error: %s"
                      (error-message-string e))))))

(defun ct--cache-save-soon ()
  "Save the cache after a short idle delay (debounced)."
  (unless (timerp ct--cache-save-timer)
    (setq ct--cache-save-timer
          (run-with-idle-timer
           2 nil
           (lambda ()
             (setq ct--cache-save-timer nil)
             (ct--cache-save))))))

(defun ct--job-complete (job json err)
  "Finish JOB with the parsed JSON or error ERR."
  (unless (ct--job-done job)
    (setf (ct--job-done job) t)
    (ct--job-end-attempt job)
    (remhash (ct--job-key job) ct--jobs-pending)
    (when json
      (ct--cache-save-soon))
    (ct--job-notify job json err)
    (ct--queue-pump)))

(defun ct--job-timeout (job)
  "Fail JOB because its timeout expired."
  (unless (ct--job-done job)
    (let ((proc (ct--job-process job)))
      (when (processp proc)
        (delete-process proc)))
    (ct--job-complete
     job nil
     (format "request timed out after %ss" comment-translator-request-timeout))))

(defun ct--job-retryable-p (err)
  "Return non-nil when the request error ERR is worth retrying.
url.el reports errors as (error KIND ...), e.g. (error http 500) or
(error connection-failed WHY)."
  (let ((kind (and (consp err) (nth 1 err)))
        (http (and (consp err) (eq (nth 1 err) 'http) (nth 2 err))))
    (or (memq kind '(connection-failed file-error))
        (and (numberp http) (or (= http 429) (>= http 500))))))

(defun ct--job-fail (job err)
  "Handle the failure ERR of JOB, retrying when appropriate."
  (if (and (> (ct--job-attempts job) 0)
           (ct--job-retryable-p err))
      (progn
        (setf (ct--job-attempts job) (1- (ct--job-attempts job)))
        (ct--job-end-attempt job)
        (run-with-timer comment-translator-retry-delay nil
                        (lambda ()
                          (setq ct--job-queue
                                (append ct--job-queue (list job)))
                          (ct--queue-pump))))
    (ct--job-complete job nil (format "HTTP request failed: %S" err))))

(defun ct--job-finish (job status buffer)
  "Handle the completion of JOB with url.el STATUS and response BUFFER."
  (unwind-protect
      (cond
       ((ct--job-done job) nil)
       ((plist-get status :error)
        (ct--job-fail job (plist-get status :error)))
       (t
        (condition-case e
            (let ((json
                   (with-current-buffer buffer
                     (goto-char (point-min))
                     (unless (re-search-forward "^\r?$" nil t)
                       (error "malformed HTTP response"))
                     (if enable-multibyte-characters
                         (json-parse-buffer :object-type 'alist
                                            :array-type 'list)
                       (json-parse-string
                        (decode-coding-string
                         (buffer-substring-no-properties (point) (point-max))
                         'utf-8)
                        :object-type 'alist :array-type 'list)))))
              (ct--job-complete job json nil))
          (error
           (ct--job-complete job nil (error-message-string e))))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun ct--job-run (job)
  "Send the queued JOB over the network."
  (cl-incf ct--jobs-in-flight)
  (condition-case err
      (progn
        (setf (ct--job-process job)
              (let ((url-request-method (ct--job-method job))
                    (url-request-extra-headers (ct--job-headers job))
                    (url-request-noninteractive t)
                    (url-request-data
                     (when (ct--job-payload job)
                       (encode-coding-string
                        (ct--json-ascii-safe (ct--job-payload job))
                        'utf-8)))
                    (url-show-status nil))
                (url-retrieve (ct--job-url job)
                              (lambda (status)
                                (let ((buffer (current-buffer)))
                                  (ct--job-finish job status buffer)))
                              nil t)))
        (when (and (not (ct--job-done job))
                   comment-translator-request-timeout
                   (> comment-translator-request-timeout 0))
          (setf (ct--job-timer job)
                (run-with-timer comment-translator-request-timeout nil
                                (lambda () (ct--job-timeout job))))))
    (error
     (ct--job-complete job nil (error-message-string err)))))

(defun ct--queue-pump ()
  "Start queued jobs while a request slot is free."
  (while (and ct--job-queue
              (< ct--jobs-in-flight comment-translator-max-concurrent-requests))
    (ct--job-run (pop ct--job-queue))))

(defun ct--http-async (url method headers payload callback)
  "Request URL asynchronously with METHOD, HEADERS and PAYLOAD.
CALLBACK is called with (JSON . ERROR); exactly one of them is non-nil.
Identical URL/payload pairs share a single request.  Returns the job."
  (let* ((key (ct--request-key url payload))
         (existing (gethash key ct--jobs-pending)))
    (if existing
        (progn
          (setf (ct--job-callback existing)
                (cons callback (ct--job-callback existing)))
          existing)
      (let ((job (ct--job-create
                  :key key :url url :method method
                  :headers headers :payload payload
                  :callback (list callback)
                  :attempts comment-translator-retry-attempts)))
        (puthash key job ct--jobs-pending)
        (setq ct--job-queue (append ct--job-queue (list job)))
        (ct--queue-pump)
        job))))

(defun ct-translate-async (text callback)
  "Translate TEXT asynchronously.
CALLBACK is called with (TRANSLATION . ERROR); exactly one of them is
non-nil.  A cached translation calls CALLBACK immediately."
  (let* ((backend (ct--resolve-backend))
         (glossed (ct--apply-glossary text))
         (key (ct--cache-key glossed))
         (cached (gethash key ct--cache)))
    (cond
     (cached (funcall callback cached nil))
     ((null backend) (funcall callback nil (ct--no-key-message)))
     ((not (ct--llm-backend-p backend))
      (funcall callback nil "this backend does not support async translation"))
     (t
      (condition-case err
          (let ((spec (ct--llm-spec backend glossed)))
            (ct--http-async
             (plist-get spec :url) (plist-get spec :method)
             (plist-get spec :headers) (plist-get spec :payload)
             (lambda (json request-error)
               (if request-error
                   (funcall callback nil request-error)
                 (condition-case e
                     (let ((translation (ct--llm-parse backend json)))
                       (when translation
                         (ct--cache-put key translation))
                       (funcall callback translation nil))
                   (error
                    (funcall callback nil (error-message-string e))))))))
        (error (funcall callback nil (error-message-string err))))))))

(defun ct-translate-batch-async (texts callback)
  "Translate TEXTS asynchronously in one batched request.
CALLBACK is called with (TRANSLATIONS . ERROR), TRANSLATIONS in the
same order as TEXTS.  Cached entries are reused.  A single text skips
the marker protocol entirely."
  (let* ((backend (ct--resolve-backend))
         (glossed (mapcar #'ct--apply-glossary texts))
         (keys (mapcar #'ct--cache-key glossed))
         (cached (mapcar (lambda (key) (gethash key ct--cache)) keys)))
    (cond
     ((cl-every #'identity cached) (funcall callback cached nil))
     ((null backend) (funcall callback nil (ct--no-key-message)))
     ((not (ct--llm-backend-p backend))
      (funcall callback nil "this backend does not support async translation"))
     ((null (cdr texts))
      (ct-translate-async
       (car texts)
       (lambda (translation error)
         (if error
             (funcall callback nil error)
           (funcall callback (list translation) nil)))))
     (t
      (condition-case err
          (let ((spec (ct--llm-spec backend (ct--batch-join glossed)
                                    (ct--llm-batch-instruction))))
            (ct--http-async
             (plist-get spec :url) (plist-get spec :method)
             (plist-get spec :headers) (plist-get spec :payload)
             (lambda (json request-error)
               (if request-error
                   (funcall callback nil request-error)
                 (condition-case e
                     (let ((translations (ct--batch-split
                                          (ct--llm-parse backend json)
                                          (length texts))))
                       (unless translations
                         (error "the model did not follow the batch format"))
                       (cl-loop for translation in translations
                                for key in keys
                                do (ct--cache-put key translation))
                       (funcall callback translations nil))
                   (error
                    (funcall callback nil (error-message-string e))))))))
        (error (funcall callback nil (error-message-string err))))))))

(defun ct--translate-llm-batches (backend candidates)
  "Translate CANDIDATES (comment regions) with the LLM backend BACKEND.
Cached translations are reused; the rest are sent in batched requests.
Returns (COUNT . FAILED)."
  (let ((plan nil)     ; (region . translation) pairs to apply
        (pending nil)  ; (region . glossed-content) pairs to translate
        (failed 0))
    (dolist (region candidates)
      (let* ((analysis (ct--analyze-comment (car region) (cdr region)))
             (content (mapconcat #'identity (plist-get analysis :lines) "\n"))
             (glossed (ct--apply-glossary content))
             (cached (gethash (ct--cache-key glossed) ct--cache)))
        (if cached
            (push (cons region cached) plan)
          (push (cons region glossed) pending))))
    ;; One request per batch for everything not cached.
    (dolist (batch (ct--group-batches (nreverse pending)
                                      comment-translator-llm-batch-limit))
      (let ((translations (ct--llm-batch-translate backend (mapcar #'cdr batch))))
        (if (null translations)
            ;; The model did not follow the format: request them one by one.
            (dolist (pair batch)
              (condition-case err
                  (let ((tr (ct-translate (cdr pair))))
                    (if tr
                        (push (cons (car pair) tr) plan)
                      (cl-incf failed)))
                (error
                 (cl-incf failed)
                 (message "comment-translator: %s" (error-message-string err)))))
          (cl-loop for pair in batch
                   for tr in translations
                   do (progn
                        (ct--cache-put (ct--cache-key (cdr pair)) tr)
                        (push (cons (car pair) tr) plan))))))
    ;; Apply every planned change bottom-up so positions stay valid.
    (let ((count 0))
      (setq plan (sort plan
                       (lambda (a b)
                         (> (car (car a)) (car (car b))))))
      (dolist (pair plan)
        (condition-case err
            (when (ct-translate-region (car pair) (cdr pair))
              (cl-incf count))
          (error
           (cl-incf failed)
           (message "comment-translator: %s" (error-message-string err)))))
      (cons count failed))))

(defun ct-translate-comments-in-region (beg end &optional reverse)
  "Translate the comments between BEG and END.
With REVERSE non-nil, translate in the opposite direction (from
`comment-translator-target-language' back to
`comment-translator-source-language').
Return the number of translated comments."
  (when (ct-disabled-p)
    (user-error "comment-translator: disabled in `%s'" major-mode))
  (ct--check-reverse reverse)
  (let* ((ct--reverse (and reverse t))
         (comment-translator-source-language
          (if reverse comment-translator-target-language
            comment-translator-source-language))
         (comment-translator-target-language
          (if reverse comment-translator-source-language
            comment-translator-target-language))
         (scripts (ct--language-scripts comment-translator-source-language))
         (has-source (if (memq 'latin scripts)
                         (string-match-p "[A-Za-z]\\{2,\\}"
                                         (buffer-substring-no-properties
                                          beg end))
                       (ct--text-has-script-p
                        (buffer-substring-no-properties beg end) scripts)))
         (regions (when has-source (ct-comment-regions beg end)))
         (backend (ct--resolve-backend))
         (candidates
          (cl-remove-if-not
           (lambda (region)
             (and (ct--needs-translation-p region nil
                                           comment-translator-source-language)
                  (not (ct--bilingual-already-translated-p region))))
           regions))
         (count 0) (failed 0))
    (unless backend
      (user-error (ct--no-key-message)))
    (when (> (length candidates) 1)
      (message "comment-translator: translating %d comments..."
               (length candidates)))
    (if (and comment-translator-llm-batching
             (ct--llm-backend-p backend))
        (let ((result (ct--translate-llm-batches backend candidates)))
          (setq count (car result) failed (cdr result)))
      ;; Translate from the bottom up so earlier region positions stay valid.
      (dolist (region (nreverse candidates))
        (condition-case err
            (when (ct-translate-region region)
              (setq count (1+ count)))
          (error
           (setq failed (1+ failed))
           (message "comment-translator: %s" (error-message-string err))))))
    (ct--cache-save)
    (when (or (> count 0) (> failed 0))
      (message "comment-translator: %d translated, %d failed%s"
               count failed
               (if (> failed 0) " (see *Messages*)" "")))
    count))

;;; Interactive commands -------------------------------------------------------

;;;###autoload
(defun comment-translator-translate-comment (&optional arg)
  "Translate the comment at point from the source language to the target.
With a prefix ARG, translate in the opposite direction (target -> source)."
  (interactive "P")
  (let ((reverse (and arg t)))
    (ct--check-reverse reverse)
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
  "Translate the comments overlapping the region BEG..END.
With a prefix ARG, translate in the reverse direction (target -> source)."
  (interactive "r\nP")
  (ct-translate-comments-in-region beg end arg))

;;;###autoload
(defun comment-translator-translate-buffer (&optional arg)
  "Translate all comments in the current buffer.
With a prefix ARG, translate in the reverse direction (target -> source)."
  (interactive "P")
  (ct-translate-comments-in-region (point-min) (point-max) arg))

;;;###autoload
(defun comment-translator-revert-comment ()
  "Restore the original text of the comment at point.
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

(defun ct--key-source (provider)
  "Describe where the API key of PROVIDER comes from."
  (let* ((var (intern (format "comment-translator-%s-api-key" provider)))
         (env (cdr (assq provider ct--env-key-alist))))
    (cond
     ((symbol-value var) (format "option `%s'" var))
     ((and env (getenv env)) (format "env %s" env))
     (t "MISSING"))))

(defun ct--doctor-live-test (backend)
  "Try one real translation with BACKEND and describe the outcome."
  (cond
   ((null backend) "SKIPPED (no API key configured)")
   ((ct--llm-backend-p backend)
    (condition-case err
        (format "OK: %S" (ct--llm-raw-translate backend "你好，世界！"))
      (error (format "FAILED: %s" (error-message-string err)))))
   ((functionp backend)
    (condition-case err
        (format "OK: %S" (funcall backend "你好，世界！"))
      (error (format "FAILED: %s" (error-message-string err)))))
   (t (format "SKIPPED (unknown backend %S)" backend))))

;;;###autoload
(defun comment-translator-doctor ()
  "Show a diagnostic report for comment-translator.
Reports which file is loaded, the resolved backend, where the API key
comes from, endpoint and model settings, cache state, and the result of
one live translation request.  Useful when translation does not work."
  (interactive)
  (let* ((raw comment-translator-backend)
         (backend (ct--resolve-backend))
         (file (or (locate-library "comment-translator") "unknown")))
    (with-current-buffer (get-buffer-create "*comment-translator doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "comment-translator doctor\n"
                "=============================\n")
        (insert (format "loaded file   : %s\n" file))
        (insert (format "backend       : %S (effective: %s)\n"
                        raw (if backend (format "%S" backend) "none")))
        (insert (format "language      : %s -> %s\n"
                        comment-translator-source-language
                        comment-translator-target-language))
        (when backend
          (if (ct--llm-backend-p backend)
              (insert (format "api key       : %s\n" (ct--key-source backend))
                      (format "base url      : %s\n"
                              (symbol-value (intern (format "comment-translator-%s-base-url"
                                                            backend))))
                      (format "model         : %s\n"
                              (symbol-value (intern (format "comment-translator-%s-model"
                                                            backend)))))
            (insert "api key       : (custom backend function)\n")))
        (insert (format "batching      : %s (limit %s chars)\n"
                        (if comment-translator-llm-batching "on" "off")
                        comment-translator-llm-batch-limit))
        (insert (format "cache file    : %s (%s)\n"
                        comment-translator-cache-file
                        (if (file-exists-p comment-translator-cache-file)
                            "exists"
                          "missing")))
        (insert (format "cache entries : %d\n" (hash-table-count ct--cache)))
        (insert (format "glossary      : %d terms\n"
                        (length comment-translator-glossary)))
        (insert "\nlive test     : "
                (ct--doctor-live-test backend)
                "\n\n"
                "If the live test fails: check the API key, the network,\n"
                "and whether this file is the newest version of the package\n"
                "(M-x package-vc-upgrade RET comment-translator RET).\n"))
      (special-mode)
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;;###autoload
(defun comment-translator-setup ()
  "Interactively configure the translation provider and its API key.
Asks for a provider, then for an API key -- leaving the key empty keeps
the current option or environment variable.  Saves the result with
`customize-save-variable' so the configuration survives restarts."
  (interactive)
  (let* ((choices '(("DeepSeek" . deepseek)
                    ("ChatGPT (OpenAI)" . openai)
                    ("通义千问 (Qwen)" . qwen)
                    ("Kimi (Moonshot)" . kimi)
                    ("豆包 (Doubao)" . doubao)
                    ("小米 MiMo" . mimo)
                    ("Gemini (Google)" . gemini)
                    ("Claude (Anthropic)" . claude)))
         (name (completing-read "Translation provider: " choices nil t))
         (provider (cdr (assoc name choices))))
    (let* ((var (intern (format "comment-translator-%s-api-key" provider)))
           (env (cdr (assq provider ct--env-key-alist)))
           (env-val (and env (getenv env)))
           (default (or (symbol-value var) env-val))
           (prompt (if default
                       (format "API key (empty keeps %s): "
                               (if (symbol-value var)
                                   (concat (substring (symbol-value var) 0 6) "...")
                                 (concat "env " env)))
                     "API key (paste here): "))
           (key (read-string prompt nil nil default)))
      (when (and (not (string-empty-p key))
                 (not (equal key (symbol-value var))))
        (set var key)
        (condition-case err
            (customize-save-variable var key)
          (error (message "comment-translator: saved for this session only: %S"
                          err))))
      (when (and env-val (not (symbol-value var)))
        (message "comment-translator: using key from the %s environment variable"
                 env)))
    (condition-case err
        (customize-save-variable 'comment-translator-backend provider)
      (error (setq comment-translator-backend provider)
             (message "comment-translator: backend set for this session: %S" err)))
    (message "comment-translator: provider set to %s" name)))

;;; Read mode -------------------------------------------------------------------

(defvar comment-translator-read-mode nil
  "Non-nil when `comment-translator-read-mode' is enabled.
Declared before the helper functions that reference it.")

(defvar-local ct--read-timer nil
  "Idle timer that schedules a read-mode scan in this buffer.")
(defvar-local ct--read-overlays nil
  "Translation overlays created by `comment-translator-read-mode'.")
(defvar-local ct--read-pending (make-hash-table :test #'equal)
  "Comment texts currently being translated in this buffer.")
(defvar-local ct--read-error-seen nil
  "Non-nil once a read-mode request error was reported in this buffer.")

(defun ct--read-visible-ranges ()
  "Return merged (START . END) ranges visible in windows of this buffer."
  (let (ranges)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (window-live-p window)
        (let ((start (window-start window))
              (end (window-end window t)))
          (when (and start end (< start end))
            (push (cons start end) ranges)))))
    (let ((sorted (sort ranges (lambda (a b) (< (car a) (car b)))))
          merged)
      (dolist (range sorted)
        (if (and merged (<= (car range) (cdr (car merged))))
            (setf (cdr (car merged)) (max (cdr (car merged)) (cdr range)))
          (push range merged)))
      (nreverse merged))))

(defun ct--read-overlay-at (start)
  "Return the read-mode overlay starting at START, if any."
  (cl-find-if (lambda (overlay)
                (and (overlayp overlay)
                     (overlay-buffer overlay)
                     (= (overlay-start overlay) start)))
              ct--read-overlays))

(defun ct--read-wants-p (content)
  "Return non-nil when read mode should translate CONTENT.
Comments already written in the target language's script are skipped."
  (let ((target-scripts
         (ct--language-scripts comment-translator-read-mode-target-language)))
    (and (string-match-p "[A-Za-z]" content)
         (or (memq 'latin target-scripts)
             (not (ct--text-has-script-p content target-scripts)))
         (or (null comment-translator-read-mode-skip-regexp)
             (not (string-match-p comment-translator-read-mode-skip-regexp
                                  content))))))

(defun ct--read-add-overlay (beg end translation)
  "Show TRANSLATION after the comment between BEG and END."
  (let ((overlay (make-overlay beg end)))
    (overlay-put overlay 'ct-read t)
    (overlay-put overlay
                 'after-string
                 (concat " "
                         (propertize "‖" 'face 'comment-translator-read-face)
                         " "
                         (propertize translation
                                     'face 'comment-translator-read-face)))
    (push overlay ct--read-overlays)
    overlay))

(defun ct--read-clear-overlays ()
  "Delete every overlay created by read mode."
  (dolist (overlay ct--read-overlays)
    (when (overlayp overlay)
      (delete-overlay overlay)))
  (setq ct--read-overlays nil)
  (clrhash ct--read-pending))

(defun ct--read-after-change (beg end _length)
  "Remove read-mode overlays touched by an edit between BEG and END."
  (setq ct--read-overlays
        (cl-remove-if
         (lambda (overlay)
           (cond
            ((not (overlayp overlay)) t)
            ((null (overlay-buffer overlay)) nil)
            ((and (< (overlay-start overlay) end)
                  (> (overlay-end overlay) beg))
             (delete-overlay overlay)
             t)
            (t nil)))
         ct--read-overlays)))

(defun ct--read-translate (items)
  "Translate ITEMS, a list of (SPAN . CONTENT) pairs, and add overlays."
  (let* ((buffer (current-buffer))
         (texts (mapcar #'cdr items))
         (spans (mapcar (lambda (item)
                          (cons (copy-marker (car (car item)) t)
                                (copy-marker (cdr (car item)) t)))
                        items)))
    (dolist (text texts)
      (puthash text t ct--read-pending))
    (let ((comment-translator-source-language
           comment-translator-read-mode-source-language)
          (comment-translator-target-language
           comment-translator-read-mode-target-language))
      (ct-translate-batch-async
       texts
       (lambda (translations error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (dolist (text texts)
               (remhash text ct--read-pending))
             (cond
              (error
               (unless ct--read-error-seen
                 (setq ct--read-error-seen t)
                 (message "comment-translator read mode: %s" error)))
              (translations
               ;; Remember the keys as read-mode entries so they stay out
               ;; of the on-disk cache unless persistence is enabled.
               (let ((comment-translator-source-language
                      comment-translator-read-mode-source-language)
                     (comment-translator-target-language
                      comment-translator-read-mode-target-language))
                 (dolist (text texts)
                   (puthash (ct--cache-key (ct--apply-glossary text))
                            t ct--read-keys)))
               (cl-loop for span in spans
                        for translation in translations
                        do (let ((start (marker-position (car span)))
                                 (end (marker-position (cdr span))))
                             (when (and start end
                                        (not (ct--read-overlay-at start)))
                               (ct--read-add-overlay start end translation)))))))))))))

(defun ct--read-scan (&optional ranges)
  "Translate visible comments without a translation overlay.
RANGES, when non-nil, overrides the visible window ranges (for testing)."
  (when (and comment-translator-read-mode
             (not (ct-disabled-p)))
    (let (pending)
      (dolist (range (or ranges (ct--read-visible-ranges)))
        (dolist (span (ct-comment-regions (car range) (cdr range)))
          (unless (ct--read-overlay-at (car span))
            (let* ((analysis (ct--analyze-comment (car span) (cdr span)))
                   (content (mapconcat #'identity
                                       (plist-get analysis :lines) "\n")))
              (when (and (ct--read-wants-p content)
                         (not (gethash content ct--read-pending)))
                (push (cons span content) pending))))))
      (setq pending (nreverse pending))
      (when (> (length pending) comment-translator-read-mode-max-batch)
        (setq pending (cl-subseq pending 0 comment-translator-read-mode-max-batch)))
      (when pending
        (ct--read-translate pending)))))

(defun ct--read-schedule ()
  "Schedule a read-mode scan after a short idle delay."
  (when (and comment-translator-read-mode
             (not (timerp ct--read-timer))
             (get-buffer-window-list (current-buffer) nil t))
    (setq ct--read-timer
          (run-with-idle-timer comment-translator-read-mode-idle-delay nil
                               #'ct--read-idle (current-buffer)))))

(defun ct--read-idle (buffer)
  "Idle-timer function: scan BUFFER for untranslated visible comments."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ct--read-timer nil)
      (when comment-translator-read-mode
        (ct--read-scan)))))

(defun ct--read-on-scroll (_window _start)
  "Window-scroll hook: reschedule the read-mode scan."
  (ct--read-schedule))

(defun ct--read-kill ()
  "Cancel read-mode timers when the buffer is killed."
  (when (timerp ct--read-timer)
    (cancel-timer ct--read-timer)
    (setq ct--read-timer nil)))

;;;###autoload
(defun comment-translator-read-refresh ()
  "Translate visible comments now (read mode)."
  (interactive)
  (if comment-translator-read-mode
      (ct--read-scan)
    (user-error "Enable `comment-translator-read-mode' first")))

;;;###autoload
(define-minor-mode comment-translator-read-mode
  "Show translations of code comments as overlays, without changing text.

Comments written in `comment-translator-read-mode-source-language' get a
translation appended after the comment itself; the buffer text is never
modified, and turning the mode off removes every overlay.  Only visible
comments are translated, cached results are shown instantly, and
requests run asynchronously after an idle delay."
  :lighter " CTrans-Read"
  :group 'comment-translator
  (cond
   (comment-translator-read-mode
    (setq ct--read-error-seen nil)
    (add-hook 'post-command-hook #'ct--read-schedule nil t)
    (add-hook 'window-scroll-functions #'ct--read-on-scroll nil t)
    (add-hook 'window-configuration-change-hook #'ct--read-schedule nil t)
    (add-hook 'after-change-functions #'ct--read-after-change nil t)
    (add-hook 'kill-buffer-hook #'ct--read-kill nil t)
    (ct--read-schedule))
   (t
    (remove-hook 'post-command-hook #'ct--read-schedule t)
    (remove-hook 'window-scroll-functions #'ct--read-on-scroll t)
    (remove-hook 'window-configuration-change-hook #'ct--read-schedule t)
    (remove-hook 'after-change-functions #'ct--read-after-change t)
    (remove-hook 'kill-buffer-hook #'ct--read-kill t)
    (when (timerp ct--read-timer)
      (cancel-timer ct--read-timer)
      (setq ct--read-timer nil))
    (ct--read-clear-overlays))))

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
               ;; we get a fresh span that reflects any edits.  Bound the
               ;; scan so a large buffer is not walked on every keystroke.
               (limit (min (point-max) (+ (cdr old-region) 4096)))
               (span (car (ct-comment-regions (car old-region) limit))))
          (setq ct--current-comment nil)
          ;; If the bounded scan stopped inside the comment (e.g. after a
          ;; huge insertion), rescan the rest of the buffer.
          (when (and span
                     (< limit (point-max))
                     (< (cdr span) (point-max))
                     (save-excursion
                       (goto-char (1+ (cdr span)))
                       (nth 4 (syntax-ppss))))
            (setq span (car (ct-comment-regions (car old-region) (point-max)))))
          (when (and span (= (car span) (car old-region)))
            (condition-case err
                (when (and (not (ct--bilingual-already-translated-p span))
                           (ct--needs-translation-p span nil))
                  (ct-translate-region span))
              (error
               (ct--report-error (error-message-string err))))))))))

(defun ct--on-save ()
  "Translate comments before the buffer is written to disk.
With `comment-translator-auto-on-save-async' the network part runs
after the save instead of blocking it."
  (when (and comment-translator-auto-mode
             comment-translator-auto-on-save
             (not (ct-disabled-p)))
    (if comment-translator-auto-on-save-async
        (ct--translate-buffer-before-save)
      (ct--translate-buffer-quietly))))

(defun ct--translate-buffer-before-save ()
  "Apply cached translations and queue the rest asynchronously.
Never waits for the network, so saving stays fast."
  (condition-case err
      (catch 'ct-skip
        (when (ct--buffer-too-large-p)
          (ct--warn-buffer-too-large)
          (throw 'ct-skip nil))
        (unless (ct--buffer-has-source-comment-p)
          (throw 'ct-skip nil))
        (when comment-translator-auto-confirm
          (unless (y-or-n-p "comment-translator: translate untranslated comments? ")
            (throw 'ct-skip nil)))
        (let ((uncached (ct--cached-translations-apply
                         (point-min) (point-max))))
          (when uncached
            (ct--translate-items-async uncached))))
    (error (ct--report-error (error-message-string err)))))

(defun ct--cached-translations-apply (beg end)
  "Apply cached translations between BEG and END.
Return a list of (MARKERS . GLOSSED-TEXT) for comments that still need a
network request, where MARKERS is (START-MARKER . END-MARKER)."
  (let (uncached)
    (dolist (region (nreverse (ct-comment-regions beg end)))
      (when (and (ct--needs-translation-p region nil)
                 (not (ct--bilingual-already-translated-p region)))
        (let* ((analysis (ct--analyze-comment (car region) (cdr region)))
               (content (mapconcat #'identity (plist-get analysis :lines) "\n"))
               (glossed (ct--apply-glossary content))
               (key (ct--cache-key glossed))
               (cached (gethash key ct--cache)))
          (cond
           (cached
            (condition-case err
                (ct-translate-region region cached)
              (error (ct--report-error (error-message-string err)))))
           (t
            (push (cons (cons (copy-marker (car region) t)
                              (copy-marker (cdr region) t))
                        glossed)
                  uncached))))))
    (nreverse uncached)))

(defun ct--translate-items-async (items)
  "Translate ITEMS ((MARKERS . TEXT) ...) asynchronously and apply them.
MARKERS are resolved after the requests complete, so edits made while
the request is in flight do not corrupt the region positions."
  (let* ((buffer (current-buffer))
         (texts (mapcar #'cdr items)))
    (ct-translate-batch-async
     texts
     (lambda (translations error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (cond
            (error
             (ct--report-error error))
            (translations
             (let ((plan (cl-mapcar (lambda (item translation)
                                      (cons (car item) translation))
                                    items translations)))
               (setq plan
                     (sort plan
                           (lambda (a b)
                             (> (marker-position (car (car a)))
                                (marker-position (car (car b)))))))
               (dolist (pair plan)
                 (let ((start (marker-position (car (car pair))))
                       (end (marker-position (cdr (car pair)))))
                   (when (and start end)
                     (condition-case err
                         (ct-translate-region (cons start end) (cdr pair))
                       (error
                        (ct--report-error (error-message-string err)))))))
               (message "comment-translator: translations applied after save"))))))))))

(defun ct--translate-buffer-quietly ()
  "Translate all comments in the current buffer, never signaling."
  (condition-case err
      (cond
       ((ct--buffer-too-large-p)
        (ct--warn-buffer-too-large))
       (comment-translator-auto-confirm
        (when (ct--buffer-has-source-comment-p)
          (if (y-or-n-p "comment-translator: translate untranslated comments? ")
              (ct-translate-comments-in-region (point-min) (point-max))
            (message "comment-translator: skipped"))))
       (t
        (ct-translate-comments-in-region (point-min) (point-max))))
    (error (ct--report-error (error-message-string err)))))

(defun ct--idle-tick (buffer)
  "Idle-timer function: translate BUFFER's comments, if any."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'comment-translator-auto-mode buffer))
    (with-current-buffer buffer
      (when (and (not (ct-disabled-p))
                 (buffer-modified-p)
                 (ct--buffer-has-source-comment-p))
        (ct--translate-buffer-quietly)))))

(defun ct--on-kill ()
  "Cancel the buffer's idle timer when the buffer is killed."
  (when (timerp ct--idle-timer)
    (cancel-timer ct--idle-timer)
    (setq ct--idle-timer nil)))

;;;###autoload
(define-minor-mode comment-translator-auto-mode
  "Automatically translate code comments into the target language.
When enabled:
- a comment is translated as soon as you finish typing it and move
  point out of it (`comment-translator-auto-on-write');
- comments are translated while Emacs is idle
  (`comment-translator-auto-on-idle');
- all comments are translated just before each save
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
