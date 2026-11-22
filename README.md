# comment-translator

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Emacs](https://img.shields.io/badge/Emacs-27.1%2B-purple.svg)]()
[![Tests](https://img.shields.io/badge/tests-30%20passing-brightgreen.svg)]()

An Emacs package that automatically translates Chinese comments in your
code into English — while you write them.

Works with **every programming language Emacs supports**. Only comments
are touched: code and string literals are never modified.

```
Before                              After
--------------------------------    ----------------------------------
// 你好，世界！                      // Hello World!
int x = 1; /* 初始值 */             int x = 1; /* initial value */
/*
 * 这是一个多行注释。
 * 第二行：计算总和。
 */                                 /*
                                     * This is a multi-line comment.
                                     * Line 2: Calculate the sum.
                                     */
```

## Features

- **All languages** — comments are located with each major mode's own
  syntax table, so C/C++/Java/JS/Python/Go/Rust/Shell/Lisp/HTML… all work
  with no language-specific parser. Strings are never translated.
- **Manual & automatic** — translate the comment at point, a region, or
  the whole buffer; or let it happen automatically when you finish typing
  a comment, while Emacs is idle, and before saving.
- **8 LLM providers** — DeepSeek, ChatGPT (OpenAI), Qwen, Kimi, Doubao,
  Xiaomi MiMo, Gemini, and Claude.
- **Zero-friction setup** — an interactive `M-x comment-translator-setup`
  wizard; API keys read from standard environment variables; the default
  `auto` mode picks the first provider with a key and explains how to
  configure one when none is found.
- **Token-conscious** — comments are batched into single LLM requests,
  results are cached persistently, prompts are minimal, and output
  length is capped per request.
- **Layout-preserving** — comment markers, indentation, ` * ` decorations,
  inline comments and multi-line blocks are rebuilt losslessly.
- **Extras** — glossary for consistent terminology, bilingual mode
  (keep the Chinese original), reverse translation (English → Chinese),
  per-project disable, undo within the session.
- **Self-diagnosis** — `M-x comment-translator-doctor` reports the loaded
  file, the resolved backend, where the API key comes from, and runs one
  live translation, so problems are one command away from an answer.

## Installation

The package is not on MELPA yet; install from GitHub with `use-package`
and `package-vc` (built into Emacs ≥ 29.1):

```elisp
(use-package comment-translator
  :vc (:url "https://github.com/c0ptr/comment-translator")
  :bind ("C-c C-t" . comment-translator-translate-comment)
  :hook (prog-mode . comment-translator-auto-mode))
```

Or clone it manually:

```sh
git clone https://github.com/c0ptr/comment-translator ~/.emacs.d/lisp/comment-translator
```

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/comment-translator")
(require 'comment-translator)
```

**Upgrading.** `package-vc` installs a snapshot; it does not track upstream
automatically.  After a new release, run:

```
M-x package-vc-upgrade RET comment-translator RET
```

(or delete `~/.emacs.d/elpa/comment-translator` and restart — the
`use-package :vc` form reinstalls it).  `M-x comment-translator-doctor`
shows which file is actually loaded.

## Quick start

All backends are LLM APIs, so configure an API key first — pick one of
three ways:

1. Run `M-x comment-translator-setup`: choose a provider, paste the API
   key, and it is saved to your init file.
2. Set a standard environment variable (see the table below), e.g. in
   your shell profile:

   ```sh
   export DEEPSEEK_API_KEY="sk-..."
   ```

   That is enough — the default backend is `auto`, which picks the
   first provider whose key is configured.  To pin a provider, add
   `(setq comment-translator-backend 'deepseek)` to your init file.
3. Set it explicitly in Elisp:

   ```elisp
   (setq comment-translator-backend 'kimi
         comment-translator-kimi-api-key "sk-...")
   ```

Then bind the manual command and enable automatic translation:

```elisp
(global-set-key (kbd "C-c C-t") #'comment-translator-translate-comment)
(add-hook 'prog-mode-hook #'comment-translator-auto-mode)
```

## Translation backends

| Backend | Protocol | API key env var | Default model |
| --- | --- | --- | --- |
| `deepseek` | OpenAI-compatible | `DEEPSEEK_API_KEY` | `deepseek-chat` |
| `openai` (ChatGPT) | OpenAI-compatible | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `qwen` | OpenAI-compatible | `DASHSCOPE_API_KEY` | `qwen-plus` |
| `kimi` (Moonshot) | OpenAI-compatible | `MOONSHOT_API_KEY` | `moonshot-v1-8k` |
| `doubao` (Volcengine Ark) | OpenAI-compatible | `ARK_API_KEY` | `doubao-1-5-pro-32k-250115` |
| `mimo` (Xiaomi) | OpenAI-compatible | `MIMO_API_KEY` | `mimo-v2.6-pro` |
| `gemini` | native generateContent | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| `claude` | native Messages API | `ANTHROPIC_API_KEY` | `claude-3-5-haiku-latest` |

Every provider has `comment-translator-<name>-api-key`, `-base-url` and
`-model` options.  For Doubao, use your Ark endpoint id (`ep-…`) as the
model if you created an inference endpoint.  A custom function of one
string argument is also accepted as a backend.

## Usage

### Manual

| Command | Action |
| --- | --- |
| `comment-translator-translate-comment` | translate the comment at point |
| `comment-translator-translate-region` | translate comments in the region |
| `comment-translator-translate-buffer` | translate the whole buffer |
| `C-u` + any of the above | reverse direction: English → Chinese |
| `comment-translator-revert-comment` | restore the original comment (this session) |
| `comment-translator-clear-cache` | clear the translation cache |
| `comment-translator-setup` | interactive provider/key configuration |
| `comment-translator-doctor` | diagnostic report + one live translation |

### Automatic mode

`M-x comment-translator-auto-mode` (or the `prog-mode` hook above)
enables three triggers, each independently switchable:

- `comment-translator-auto-on-write` (t) — translate a comment as soon
  as you finish typing it and move point out;
- `comment-translator-auto-on-idle` (t) — translate while Emacs is idle
  (`comment-translator-auto-idle-delay` seconds, modified buffers only);
- `comment-translator-auto-on-save` (t) — translate right before saving.

`comment-translator-global-auto-mode` turns it on in every `prog-mode`
buffer; `comment-translator-auto-confirm` asks before applying
automatic changes.

## Customization

| Option | Default | Purpose |
| --- | --- | --- |
| `comment-translator-backend` | `auto` | `auto` / a provider / a function |
| `comment-translator-source-language` | `"zh-CN"` | source language code |
| `comment-translator-target-language` | `"en"` | target language code |
| `comment-translator-glossary` | nil | `(("服务器" . "server") …)` — locked terms |
| `comment-translator-bilingual` | nil | keep the Chinese original as an extra line |
| `comment-translator-llm-batching` | t | batch several comments per LLM request |
| `comment-translator-llm-batch-limit` | 1200 | max chars per batch |
| `comment-translator-llm-extra-args` | nil | extra JSON fields for OpenAI-compatible requests |
| `comment-translator-cache-enabled` / `-file` | t | persistent translation cache |
| `comment-translator-excluded-modes` / `-enabled-modes` | nil | mode filter |
| `comment-translator-skip-regexp` | nil | skip comments matching this regexp |

Disable a whole project with `.dir-locals.el`:

```elisp
((prog-mode . ((comment-translator-disabled . t))))
```

## Token usage

Translation cost is kept low by design:

- **Batching** — several comments share one request (the system prompt
  is sent once); if the model does not follow the marker format, the
  plugin falls back to one request per comment.
- **Persistent cache** — identical comments are translated once, ever.
- **Minimal prompts** and a per-request `max_tokens` cap.
- Non-Chinese comments are skipped before any network call.

## How it works

Comments are found with an incremental `parse-partial-sexp` scan of the
buffer's syntax table, so detection matches the language exactly and
strings are excluded.  Each comment is split into prefix / decoration /
content / suffix, the content is translated, and the comment is rebuilt
losslessly.

## Troubleshooting

Start with `M-x comment-translator-doctor`.  It prints the loaded file,
the effective backend, where the API key comes from, the endpoint and
model, cache state, and the result of one live translation request.

| Symptom | Cause and fix |
| --- | --- |
| Nothing happens; the comment stays unchanged | An out-of-date copy is loaded.  The doctor report's `loaded file` shows which file Emacs uses — upgrade (see Installation). |
| `Multibyte text in HTTP request` | Old version: request bodies were not ASCII-escaped.  Upgrade. |
| `no API key configured` | Run `M-x comment-translator-setup`, or export the provider's environment variable (e.g. `DEEPSEEK_API_KEY`). |
| Live test fails with 401/403 | The key is wrong, expired, or not enabled for the chosen model.  Check the doctor report's `api key` and `model` lines. |
| Timeouts or connection errors | The provider may be unreachable without a proxy — configure `url-proxy-services`, or use a provider reachable from your network (DeepSeek, Qwen, Kimi, Doubao and MiMo are usually direct-accessible from mainland China). |
| A comment was translated once and then "frozen" | It is served from the cache.  `M-x comment-translator-clear-cache` resets it. |

## Development

```sh
# Offline unit tests (30 tests: scanning, analysis, rendering, protocols,
# batching, cache, fallback paths, doctor)
emacs -Q --batch -L . -L test -l test/comment-translator-test.el \
      -f ert-run-tests-batch-and-exit

# Live end-to-end test against a real backend
CT_E2E_BACKEND=deepseek CT_E2E_API_KEY=sk-... \
  emacs -Q --batch -L . -l test/e2e-live.el
```

## Roadmap

Async translation queue, diff preview before applying, whole-project
batch translation, translating only `git diff`-changed comments,
persistent undo history, local/offline translation engines, and
tree-sitter as an alternative comment locator.

## License

MIT — see [LICENSE](LICENSE).
