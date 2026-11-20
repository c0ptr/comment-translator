# comment-translator

一个 Emacs 插件：编写代码时，把注释里的中文自动翻译成英文。
支持 Emacs 认识的所有编程语言，只翻译注释，绝不碰代码和字符串。

```
// 你好，世界！                          // Hello World!
int x = 1; /* 初始值 */        ───▶     int x = 1; /* initial value */
/*
 * 这是一个多行注释。
 * 第二行：计算总和。
 */                                      /*
                                          * This is a multi-line comment.
                                          * Line 2: Calculate the sum.
                                          */
```

## 工作原理

- **注释识别**：使用每个 major mode 自带的语法表（`parse-partial-sexp` 增量扫描）
  定位注释，因此天然支持 C/C++/Java/JS/TS/Python/Go/Rust/Shell/Lisp/HTML……
  无需任何语言专用解析器。
- **字符串安全**：字符串字面量、文档字符串里的中文永远不会被翻译。
- **排版无损**：`//`、`#`、`;`、`--`、`/* */`、`<!-- -->` 等各种注释标记、
  行尾注释、多行块注释的 ` * ` 装饰前缀与缩进都会被完整保留。
- **可插拔翻译后端**：Google（免费）、MyMemory（免费）、任意 OpenAI 兼容 API
  （DeepSeek / OpenAI / Ollama / 本地模型）、或你自己的函数。

## 安装

把本目录加入 `load-path`：

```elisp
(add-to-list 'load-path "~/path/to/comment-translator")
(require 'comment-translator)
```

或用 use-package：

```elisp
(use-package comment-translator
  :load-path "~/path/to/comment-translator"
  :bind ("C-c C-t" . comment-translator-translate-comment))
```

## 快速上手

### 手动模式

| 命令 | 作用 |
| --- | --- |
| `comment-translator-translate-comment` | 翻译光标所在的注释 |
| `comment-translator-translate-region` | 翻译选区内的全部注释 |
| `comment-translator-translate-buffer` | 翻译整个缓冲区 |
| `C-u` + 上面任意命令 | 反向翻译：英文 → 中文 |
| `comment-translator-revert-comment` | 撤销：恢复本次会话内翻译前的原文 |
| `comment-translator-clear-cache` | 清空翻译缓存 |

### 自动模式

三种触发时机，可独立开关（默认全部开启）：

```elisp
;; 只对编程模式启用
(add-hook 'prog-mode-hook #'comment-translator-auto-mode)

;; 或全局启用（等价于对每个 prog-mode 缓冲区开启上面的 minor mode）
(comment-translator-global-auto-mode 1)
```

| 配置 | 默认 | 行为 |
| --- | --- | --- |
| `comment-translator-auto-on-write` | t | 在注释里打完中文、光标移出注释的瞬间翻译 |
| `comment-translator-auto-on-idle` | t | Emacs 空闲 5 秒（`comment-translator-auto-idle-delay`）后翻译，只处理已修改的缓冲区 |
| `comment-translator-auto-on-save` | t | 保存前把全文的中文注释翻译完再落盘 |
| `comment-translator-auto-confirm` | nil | 置 t 时自动翻译前先询问 |

## 翻译后端

```elisp
;; 默认：Google Translate 免费端点，无需 API key
(setq comment-translator-backend 'google)

;; 免费备选：MyMemory（匿名每天 5000 字符，注册后填入邮箱可达 5 万）
(setq comment-translator-backend 'mymemory)
(setq comment-translator-mymemory-email "you@example.com")

;; 任意 OpenAI 兼容 API（默认已填 DeepSeek 官方地址）
(setq comment-translator-backend 'openai)
(setq comment-translator-openai-api-key "sk-...")
(setq comment-translator-openai-base-url "https://api.deepseek.com/v1")
(setq comment-translator-openai-model "deepseek-chat")

;; 自定义函数：输入一个字符串，返回译文
(setq comment-translator-backend
      (lambda (text) (my-fancy-translator text "zh-CN" "en")))
```

网络提示（中国大陆）：

- `google` / `mymemory` 需要能访问境外站点；
- 在公司内网或需走代理时，可配置 `url-proxy-services`，或改用
  `openai` 后端（DeepSeek 等国内 API 直连即可）；
- LLM 后端对代码注释的术语和上下文理解通常更好，推荐长期使用。

## 完整配置项

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| `comment-translator-backend` | `google` | 翻译后端（见上） |
| `comment-translator-source-language` | `"zh-CN"` | 源语言代码 |
| `comment-translator-target-language` | `"en"` | 目标语言代码 |
| `comment-translator-glossary` | nil | 术语表：`(("服务器" . "server") ...)`，这些词交给翻译器前先替换，保证术语不被乱译 |
| `comment-translator-bilingual` | nil | 双语模式：保留中文原文，译文另起一行 |
| `comment-translator-bilingual-marker` | `"[en]"` | 双语译文行的标记，用于防止重复翻译 |
| `comment-translator-cache-enabled` | t | 翻译结果落盘缓存，重启不重复请求 |
| `comment-translator-cache-file` | `~/.emacs.d/comment-translator-cache.el` | 缓存文件位置 |
| `comment-translator-excluded-modes` | nil | 不翻译的 major mode 列表 |
| `comment-translator-enabled-modes` | nil | 白名单；nil 表示所有有注释的模式 |
| `comment-translator-skip-regexp` | nil | 内容匹配该正则的注释跳过（如许可证头） |
| `comment-translator-auto-on-write` | t | 离开注释即翻译 |
| `comment-translator-auto-on-idle` | t | 空闲时翻译 |
| `comment-translator-auto-idle-delay` | 5 | 空闲触发秒数 |
| `comment-translator-auto-on-save` | t | 保存前翻译 |
| `comment-translator-auto-confirm` | nil | 自动翻译前确认 |
| `comment-translator-openai-*` | 见上文 | OpenAI 兼容后端的 key/地址/模型/额外参数 |

## 按项目 / 文件禁用

在项目根目录放 `.dir-locals.el`：

```elisp
((prog-mode . ((comment-translator-disabled . t))))
```

单个缓冲区里 `M-x comment-translator-auto-mode` 可随时开关自动模式
（手动命令始终可用，除非设置了上面的禁用）。

## 术语表（保持术语一致）

翻译「服务器」「数据库」这类词时，机器翻译可能今天译成 server、
明天译成 host。用术语表锁定：

```elisp
(setq comment-translator-glossary
      '(("服务器" . "server")
        ("数据库" . "database")
        ("登录"   . "login")))
```

术语在发送给翻译器**之前**就被替换，翻译器只会看到英文术语并原样保留。

## 双语模式

```elisp
(setq comment-translator-bilingual t)
```

单行整行注释会变成两行（原文在上，译文在下），重复运行不会产生重复行：

```
    // 计算总和
    // [en] Calculate the sum
```

修改中文后想刷新译文：删掉 `[en]` 行即可触发重新翻译。

## 测试

```sh
# 离线单元测试（15 个用例，覆盖注释识别/分析/渲染/术语表/缓存等）
emacs -Q --batch -L . -L test -l test/comment-translator-test.el \
      -f ert-run-tests-batch-and-exit

# 真实网络端到端测试（默认 Google 后端，可用 CT_E2E_BACKEND=mymemory 切换）
emacs -Q --batch -L . -l test/e2e-live.el
```

## 已知限制

- 手动/自动翻译是同步网络请求，批量翻译大文件时会短暂阻塞 UI
  （有缓存兜底，重复内容秒回）；异步化在路线图中。
- Google 端点是「民间」接口，官方没有 SLA，未来可能失效——失效时
  切换到 `mymemory` 或 `openai` 后端即可，插件代码无需改动。
- 自动翻译后原中文会在缓存中保留，`comment-translator-revert-comment`
  可在本次会话内撤销。

## 路线图（还可以有什么功能）

当前未实现、但很适合这个插件的方向：

1. **异步 + 并发翻译队列**：批量翻译不阻塞 Emacs，显示进度。
2. **翻译前 diff 预览**：先弹出 ediff 让你确认，再落盘。
3. **整个项目批量翻译**：集成 `project.el` / `projectile`，翻译指定
   目录下的所有文件（带 dry-run 和跳过列表）。
4. **只翻译改动过的注释**：结合 `git diff` / vc 状态，只处理新增或
   修改的注释行。
5. **持久化撤销历史**：把「译文 → 原文」也写盘，跨会话可恢复。
6. **翻译记忆学习**：用户手动改过的译文自动学习，同句不再重翻。
7. **本地离线翻译**：接入 Argos Translate / MarianNMT 等本地引擎，
   代码注释不出本机（适合保密项目）。
8. **更多语言对**：日/韩/法/德 → 英文，或中英以外任意互译
   （后端已支持，只差检测规则）。
9. **tree-sitter 后端**：用 tree-sitter 做第二套注释定位器，
   在语法表不完整的模式里兜底。
10. **翻译结果自动排版**：译完后按 `fill-column` 重新折行，保持
    doc-comment 美观。
11. **hover 预览**：先把译文显示在 tooltip，按 `y` 才替换。
12. **字符串/文档翻译扩展**：可选的「连 docstring 一起翻译」开关。
13. **团队共享词库**：术语表支持从文件/Git 仓库加载。
14. **忽略注释内的代码片段**：识别注释里的代码块并原样保留。

## License

MIT
