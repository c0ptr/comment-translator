# comment-translator

Emacs 插件：写代码时，自动把注释里的中文翻译成英文。
支持所有编程语言，只翻译注释，绝不碰代码和字符串。

```
// 你好，世界！           ───▶   // Hello World!
int x = 1; /* 初始值 */         int x = 1; /* initial value */
```

## 安装（use-package / GitHub）

需要 Emacs ≥ 29.1（内置 package-vc）：

```elisp
(use-package comment-translator
  :vc (:url "https://github.com/liuldao/comment-translator")
  :bind ("C-c C-t" . comment-translator-translate-comment)
  :hook (prog-mode . comment-translator-auto-mode))
```

或手动 clone：

```sh
git clone https://github.com/liuldao/comment-translator ~/.emacs.d/lisp/comment-translator
```

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/comment-translator")
(require 'comment-translator)
```

## 配置（一分钟）

**零配置**：默认用免费 Google Translate，装完即用。

**想用 LLM（译文质量更好）**，任选一种方式：

1. **向导**：`M-x comment-translator-setup` —— 选提供商 → 粘贴 API key → 自动写入配置。
2. **环境变量**（推荐）：在 `~/.zshrc` 里 `export DEEPSEEK_API_KEY=sk-...`，
   Emacs 里只写一行：
   ```elisp
   (setq comment-translator-backend 'deepseek)
   ```
   也可以填 `'auto`，自动用第一家配好 key 的提供商。
3. **直接写配置**：
   ```elisp
   (setq comment-translator-backend 'kimi
         comment-translator-kimi-api-key "sk-...")
   ```

## 提供商

| backend | API key 环境变量 | 默认模型 |
| --- | --- | --- |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-chat` |
| `openai`（ChatGPT） | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `qwen`（通义千问） | `DASHSCOPE_API_KEY` | `qwen-plus` |
| `kimi`（Moonshot） | `MOONSHOT_API_KEY` | `moonshot-v1-8k` |
| `doubao`（豆包/方舟） | `ARK_API_KEY` | `doubao-1-5-pro-32k-250115` |
| `mimo`（小米） | `MIMO_API_KEY` | `mimo-v2.6-pro` |
| `gemini` | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| `claude` | `ANTHROPIC_API_KEY` | `claude-3-5-haiku-latest` |
| `google` / `mymemory` | 免费，无需 key | — |

换模型/网关：`(setq comment-translator-<名字>-model "...")`、
`(setq comment-translator-<名字>-base-url "...")`。
豆包在方舟控制台建了推理接入点的话，模型填 endpoint id（`ep-...`）。

## 使用

**手动**：

| 命令 | 作用 |
| --- | --- |
| `C-c C-t`（`comment-translator-translate-comment`） | 翻译光标所在的注释 |
| `comment-translator-translate-buffer` | 翻译整个缓冲区 |
| `C-u` + 上面任意命令 | 反向：英文 → 中文 |
| `comment-translator-revert-comment` | 撤销本次会话内的翻译 |

**自动**（写完就译、空闲时译、保存前译，默认全开）：

```elisp
(add-hook 'prog-mode-hook #'comment-translator-auto-mode)
```

想只保留某一种触发：`(setq comment-translator-auto-on-idle nil)` 等，
见 `comment-translator-auto-on-write/on-idle/on-save`。

## 常用自定义

```elisp
;; 术语表：锁定专业词汇的译法
(setq comment-translator-glossary '(("服务器" . "server")))

;; 双语模式：保留中文原文，译文另起一行
(setq comment-translator-bilingual t)

;; 不翻译某些模式 / 跳过匹配的注释
(setq comment-translator-excluded-modes '(org-mode))
(setq comment-translator-skip-regexp "TODO")
```

按项目禁用：项目根目录 `.dir-locals.el` 里写
`((prog-mode . ((comment-translator-disabled . t))))`。

## 省 token 设计

- **批量请求**：多条注释合并为一次 LLM 调用（`comment-translator-llm-batching`，
  默认开；`comment-translator-llm-batch-limit` 控制单批大小，格式解析失败自动
  退回逐条请求）；
- **持久缓存**：相同注释只翻译一次，重启 Emacs 不重复计费；
- **精简提示词** + 输出长度按需封顶（`max_tokens`）；
- 只处理含中文的注释，其余全部跳过。

## 测试

```sh
emacs -Q --batch -L . -L test -l test/comment-translator-test.el \
      -f ert-run-tests-batch-and-exit
```

## 已知限制

- 请求是同步的（有缓存兜底）；Google 端点是民间接口，失效时换一家提供商即可。
- 路线图：异步队列、翻译前 diff 预览、git diff 增量翻译、全项目批量、本地离线模型。
