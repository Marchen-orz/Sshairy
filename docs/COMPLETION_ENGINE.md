# 规格补全引擎

2026-11-08。领域引擎已接入终端会话、惰性规格加载、远程路径来源与候选框；自动回归通过，真实服务器和原生输入法仍待验收。

纯 Dart，无 IO、无 shell、无时钟：输入一份静态命令规格（COMPLETION_SPECS）和草稿，输出带替换范围的类型化候选，以及需要调用方列目录的路径请求。历史置顶、目录列举（TERMINAL_PATHS）、方向键与 Tab、候选与 `CommandKind` 的映射都在引擎之外。

```text
lib/features/terminal/domain/
  completion_spec.dart     规格数据模型与 fromJson
  completion_context.dart  草稿解析、shell 编码
  spec_completion.dart     引擎、结果类型、路径请求（并 export 前两者）
```

只依赖 Dart core；不 import `command_assistance`，用自己的 `SpecSuggestionKind`，由调用方映射。

## 规格模型

`CompletionSpec.fromJson` 读 COMPLETION_SPECS 的节点，字段是 Fig 的子集；未知字段忽略，已知字段类型错就抛 `FormatException`（`tryParse` 返回 null），损坏的文件不会变成读了一半的规格。嵌套深度上限 24。

| 类型 | 要点 |
|---|---|
| `CompletionSpec` | `names`（首个为规范名）、`subcommands`、`options`、`args`、`additionalSuggestions`、`loadSpec`、`directives`、`hidden`、`priority` |
| `CompletionOption` | `names`、`args`、`isPersistent`、`maxUses`（`isRepeatable`：false 为 1，true 为不限，数字为次数）、`isRequired`、`separator`（`requiresSeparator`/`requiresEquals`）、`exclusiveOn`、`dependsOn`、`hidden` |
| `CompletionArg` | `isOptional`、`isVariadic`、`isCommand`、`isScript`、`choices`、`templates` |
| `CompletionChoice` | 静态建议；`insertValue` 的 `{cursor}` 去掉（终端放不了光标） |
| `ParserDirectives` | `flagsArePosixNoncompliant`、`optionsMustPrecedeArguments`、`optionArgSeparators`（默认 `=`） |

`template` 取 `filepaths`、`folders`、`history`；`history` 由调用方处理，引擎不产出。隐藏项（`hidden`）不进候选。`loadSpec` 在引擎侧由 `withLoaded` 合并：目标的子命令、选项追加在节点自己的内容之后，节点自己的 `args` 优先。

## 草稿解析

`CompletionContext.parse(draft)` 把草稿按 POSIX 单行规则切词，光标在末尾。

- 识别引号（单、双）与反斜杠转义；制表符与空格分词。
- 每个词有 `raw`（原文）、`value`（shell 实际传给命令的值）、`start`/`end`，`rawOffsetAfter(n)` 把 value 的偏移映回 raw。
- `current` 是正在输入的最后一个词；草稿以空格结尾时是末尾的空词。`quote` 是它仍未闭合的引号。
- 替换范围永远是整个最后一个词：`replaceStart = current.start`，`replaceEnd = draft.length`。

下列情况整份草稿判为不支持（`issue` 非空，没有词，没有候选），不去猜：

| issue | 触发 |
|---|---|
| `control` | 换行等控制字符（制表符除外） |
| `operator` | `\| & ; < > ( )` |
| `substitution` | `$`、反引号（双引号内同样） |
| `expansion` | `* ? [ ] { } !`、词首 `#`；双引号内的 `!` |
| `danglingEscape` | 末尾孤立反斜杠 |
| `tooLong` | 超过 4096 个字符 |

单引号内全部按字面处理；被反斜杠转义的字符是普通文字。

## 引擎

`completeSpec(spec, draft, {config})` 返回 `SpecCompletionResult(context, suggestions, path, truncated, missingNested, missingCommand)`。`spec` 是草稿首词对应命令的规格；null 或首词不在 `names` 内按未知命令处理。

### 走词

最后一个词之前的每个词依次归类，状态机维护：

- 子命令链（含别名）；仅在该节点第一个位置词、且规格有子命令时才查子命令；查不到又没有 `args` 则整条线 dead，不给候选。
- 选项：精确名；`--opt<sep>值`（`optionArgSeparators`）；POSIX 合并短选项（`-xzf`、`-Ipath`，第一个带值的字母结束合并）；`-数字` 忽略。`flagsArePosixNoncompliant` 关闭合并。
- 选项取值：必选的值消耗下一个词；`separator` 选项的值必须连写；可变参数的值遇到以 `-` 开头的词结束。
- `--` 之后全是位置词；`optionsMustPrecedeArguments` 时第一个位置词之后的 `-` 词也是位置词。
- 位置词按 `args` 下标计数，可变参数不耗尽。
- 未知选项使后续位置、子命令候选不再给出（无法确定下一个词是不是它的值），选项名仍可补全；`--x=值` 与 `-数字` 不算不确定。
- 持久选项（`isPersistent`）对其后所有子命令生效；更近的节点同名选项遮住外层的。

### 候选

按词类产生候选，前缀匹配最后一个词的 `value`，与词完全相同的不再给：

| 位置 | 候选 |
|---|---|
| 位置词，第一个位置 | 子命令（空词只给规范名，有输入再给别名）与 `additionalSuggestions` |
| 位置词 | 当前 `arg` 的静态建议；可选参数被跳过时下一个 `arg` 也是候选 |
| 以 `-` 开头 | 选项名；已用完（`maxUses`）、被 `exclusiveOn` 排除、`dependsOn` 未满足的不给；`hidden` 不给 |
| 选项值 | 该选项的 `args` 建议；`--opt=` 与 `-Xvalue` 的候选带上前缀 |
| `-la` 这类已知无值短选项合并 | 可再并入的短选项（`-la` + `-h` 给 `-lah`） |
| `isCommand` 参数 | `config.commands`（`SpecSuggestionKind.command`），并改由 `config.command(名)` 的规格接管其后的词（`sudo git ...`） |
| `isScript` 参数 | 不给 |

空词默认不给选项，`includeOptionsForEmptyToken` 打开后给规范名。排序：必选选项在前，再按 `priority` 降序，同分保持规格顺序；按值去重；至多 `config.limit`（默认 200）个，超出时 `truncated` 为 true。

### 替换与后缀

`SpecSuggestion` 带：`value`（插入后的完整逻辑词）、`display`（简短标签）、`kind`、`replaceStart`/`replaceEnd`、`replacement`（该范围插入后的 raw 文本，已按 shell 引号与转义编码）、`suffix`、`appendSpace`、`description`。

- `suffix` 非空：`replacement == 已输入的 raw + suffix`，即纯追加，`draft + suffix == applyTo(draft)`；调用方可以只追加字符，不删任何已输入内容。
- `suffix` 为 null：已输入文本不是 `value` 的前缀（规格的 `insertValue` 改写），应用时要替换已输入字符，调用方必须确认或跳过。
- 追加内容按引号状态编码：无引号时转义非普通字符（词首的 `~`、`#` 也转义）；单引号内 `'` 写成 `'\''`；双引号内转义 `" \ $` 和反引号，`!` 写成 `"\!"`。词结束（`appendSpace`）时补上闭合引号。
- `appendSpace` 为 false：文件夹（结尾 `/`，继续下钻）与 `--名=`（值要连写）。

## 路径

模板为 `filepaths` 或 `folders` 的参数产生 `PathCompletionRequest`，引擎不列目录。

| 字段 | 含义 |
|---|---|
| `typedPrefix` | 已输入的路径文本，去引号去转义（`~/pro`、`My Do`） |
| `foldersOnly` | 来自模板；同一词既要文件又要文件夹时取文件 |
| `tokenStart`/`tokenEnd`、`tokenValue`/`tokenRaw` | 整个最后一个词 |
| `valueStart` | 路径文本在草稿里的起点：词首，或 `--file=`、`-I` 之后 |
| `quote` | 词仍未闭合的引号 |
| `directory`、`namePrefix` | 要列的逻辑目录（`''` 为工作目录，`~/`、`src/`、`/etc/`）与名字前缀；`~` 单独时目录为 `~/`；`~user` 不产生请求 |

调用方异步列出 `directory`，把条目转成 `CompletionPathEntry(name, isDirectory:)` 交给 `request.resolve(entries, limit: 200)`：

- 按给定顺序保留；名字含控制字符或 `/`、`.`、`..` 的丢弃；点开头的文件除非前缀以 `.` 开头；`foldersOnly` 时去掉文件；按名去重。
- 前缀能成为 `..` 的前缀时补一个 `../`。
- 目录结尾 `/`、不追加空格。
- 词首为空且名字以 `-` 开头时写成 `./名`，避免被读成选项。

## 未知命令

首词没有规格，或最后一个词落在没有规格的内层命令（`sudo 某命令 ...`）时，只在两种情况产生路径请求：

- 显式路径：以 `/`、`./`、`../`、`~/` 开头，或正好是 `.`、`..`、`~`。
- 保守的通用位置：在参数位置（有首词）、此前没出现任何 `-` 词、词非空且不以 `-` 开头。

其余不给候选。

## 异步加载

引擎同步。`config.nested`（`loadSpec` 键）和 `config.command`（`isCommand` 后面的命令名）是同步查表，没有就返回 null；走到该处但缺少时，结果里的 `missingNested`/`missingCommand` 给出键或命令名，调用方异步加载后重新调用。只是引用而无内容的节点缺目标时不给候选；有自己内容的节点仍可用，同时报告缺失。

## 调用方约定

1. 候选的 `value` 与 `kind` 映射到 `CommandCandidate`；`suffix` 为 null 的需要确认或跳过。
2. 路径请求由调用方列目录，条目映射为 `CompletionPathEntry`；`~` 在调用方侧展开。
3. 草稿 `context.supported` 为 false 时不给任何候选，历史候选的处理不变。
4. 命令清单（顶层命令名）由调用方外部加载，引擎只处理一份根规格与以它开头的草稿。
5. 候选文案（`description`）来自第三方规格，不得翻译成事实陈述；界面上的固定文案走 i18n。

## 实现状态

- 三个领域文件和 `test/spec_completion_test.dart` 已写成。
- `test/spec_completion_test.dart`、全部打包资源解码、会话与候选 UI、路径来源均已运行通过；2026-11-08 完整工程回归 700 项通过、1 项跳过（排除无关的未跟踪 `test/zz_probe_test.dart`）。
- 已格式化本轮 Dart 文件；模块 import 检查通过。`flutter analyze --no-pub` 仅有上述 probe 文件原有 3 条诊断，本轮没有新增诊断。
- 自动测试覆盖 Tab/Enter、四方向虚拟浏览、转义路径、超过 8 项滚动、异步选中保留、旧结果与光标定位；不等同于真实 shell 或原生输入法验收。引号/转义规则未在作者服务器逐项比对，真实 IME、最终窗口与真实服务器 SFTP 仍未验证。
- 不覆盖：多行、管道和重定向后的命令、变量与命令替换、通配符、`~user`、别名与 shell 函数、生成器类参数（git 分支、容器名等没有候选）。
