# Fig 静态补全规格

2026-11-08。静态导入、运行时按需加载和补全接线已实现，实际数量与边界见文末“实现状态”。

把固定版本的 [withfig/autocomplete](https://github.com/withfig/autocomplete) 规格离线转成纯数据 JSON，作为终端补全的静态命令树（TERMINAL_ASSISTANCE）。只取名称、说明、选项、子命令、参数与固定建议；不执行任何上游代码，也不声称等同 Fig 运行时。

## 来源与许可证

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/withfig/autocomplete` |
| 提交 | `aef52acff84c45edde61ae610cc2c964802b9a38` |
| 包版本 | `@withfig/autocomplete` 2.692.3（该提交的 `package.json`） |
| 下载 | `https://codeload.github.com/withfig/autocomplete/tar.gz/<提交>`，归档内 pax 全局头 `comment=` 必须等于该提交 |
| 归档 SHA-256 | `44f11c63d150b2f77db35479871b026e0c9882e1049a29d201d0a8ab46c2aaab`（8,182,891 字节，2026-11-08 实测；GitHub 不保证归档字节永久稳定，只作溯源记录） |
| 解析器 | npm `typescript@5.9.3`，`dist.integrity` = `sha512-jl1vZzPDinLr9eUt3J/t7V6FgNEw9QjvBPdysz9KfQDD41fQrC2Y4vKQdiaUpFT4bXlb1RHhLpp8wtm6M5TgSw==`（`npm pack --ignore-scripts` 核对） |

许可证有不一致，如实保留：该提交根目录 `LICENSE` 是 MIT（Copyright (c) 2021 Hercules Labs Inc. (Fig)），而 `package.json` 的 `license` 写 ISC。本项目按仓库实际的 `LICENSE` 文件处理，原文逐字节放进 `assets/completions/LICENSE`，manifest 同时记录两处声明和 LICENSE 的 SHA-256。这不是法律结论；发布前许可证审计（ROADMAP“确定 LICENSE；审计依赖”）仍要复核，必要时联系上游澄清。上游规格里的说明文字是第三方内容，分发时随带上述许可证。

不打包上游的图标（`icons/`、规格里的 `icon`）、运行时代码、生成器、构建脚本。Netcatty（GPL-3.0）的代码与数据不参与，只有 NETCATTY_REVIEW 里记录的交互参考。

## 不可信数据

下载内容一律视为不可信数据。

- 归档放在新建的空目录；导入脚本在别处，cwd 不在数据目录，路径作参数传入。
- 导入脚本直接在内存里读 `.tar.gz`：只接受普通文件和目录，拒绝符号/硬链接和设备，拒绝绝对路径、`..`、反斜杠和 NUL；只保留 `src/**/*.ts`、`LICENSE`、`package.json`；解压后总量、文件数与单文件大小有上限。不把归档解到磁盘也能导入（为人工查看另行解压时先检查文件列表）。
- 不 `import`/`eval`/`require` 任何下载的 JS/TS，不运行 `pnpm`/`npm install`/`tsc`/生成器/上游脚本，不装上游依赖。
- TypeScript 只作语法分析（`createSourceFile`，无类型检查、无 Program、不读 `tsconfig`）。它取自 npm 固定版本，在独立的新目录用 `--ignore-scripts` 取得，脚本通过 `--typescript <目录>` 加载。

## 导入流程

```text
node tool/import_completion_specs.mjs --archive <fig.tar.gz> --typescript <typescript 包目录> [--out assets/completions]
node tool/import_completion_specs.mjs --source <已解出的目录> --typescript <...>      # 测试或离线复核
```

脚本是 Node ESM、零 npm 依赖，只用内置模块。归档模式校验提交和 `package.json` 版本等于固定值；`--unpinned` 才允许其他来源（测试用，manifest 会记录）。输出确定性：键序固定、数组按源码顺序、文件名与 manifest 键排序。

1. 读取源码集合（上面的内存读取，或目录模式下同样的白名单，lstat 拒绝符号链接）。
2. 确定根：`src/<名>.ts`、`src/@scope/<名>.ts`、`src/<名>/index.ts`（含 `src/@scope/<名>/index.ts`）。`src/<名>/` 下的其他文件不是根，只在被静态 `loadSpec` 引用时输出。`*.d.ts` 跳过。
3. 用有界 AST 解释器计算每个规格的默认导出（见下）。`createVersionedSpec("名", ["a","b"])` 取其中最高版本对应的 `src/<名>/<版本>.ts`，写入审计。
4. 按白名单字段投影为输出 JSON，其余字段计数后丢弃。
5. 静态 `loadSpec` 字符串：目标文件存在且链长不超过上限就登记到 `nested` 并同样投影；否则丢弃引用并计入审计。
6. 校验输出（结构不变量，见“审计”），写文件，最后写 manifest 与 LICENSE。任何一项超出预算或校验失败就整体失败，不写出部分结果。

### 有界解释器

只对 AST 求值，从不执行。支持：字符串/数值/布尔/null/undefined、无替换或替换项为静态值的模板字符串、对象与数组字面量（含 `...spread`、简写属性、字符串/计算字面键）、同文件顶层 `const/let/var` 引用、`as`/`satisfies`/括号/非空断言、成员访问、字符串与数值 `+`、`!`、负号、条件取值（条件为静态布尔）、`export const`/`export default`/`export { }`/`export * from`、相对路径 `import`（默认、命名、命名空间；解析 `.ts`、`/index.ts`，限制导入深度）。

另支持有界的纯 AST helper：本地函数/箭头函数的简单参数、默认值、局部声明、单个 return 或表达式体；只解释这些语法，不将源码交给 JS 执行。允许静态 Array 的 map/filter/concat/join/includes、Object.keys/values/entries、Array.from 和 createVersionedSpec 的固定版本选择；短路、空值合并与严格原始值比较也只在静态值上求值。

不支持的语法产生带种类标记并计数：new、类、循环、赋值等函数副作用、运行时条件（process.*）、非相对路径的导入（@fig/autocomplete-generators、semver 等）、getter/setter、命名空间/枚举及白名单以外的调用。函数值仅供静态 helper 解释，生成器、generateSpec、动态 loadSpec 和其他运行时回调仍丢弃。

预算：单文件 8 MiB、解析源码总量 256 MiB、每规格求值 5×10⁶ 步、表达式深度 256、调用深度 24、静态数组长度 20000、导入链 8、模块缓存 64 MiB；输出节点数与文件大小见下表。输出超限整体失败，无法解释的静态部分按审计记录省略，不能宣称获得完整动态能力。

## 输出

```text
assets/completions/
  manifest.json
  LICENSE                      上游 LICENSE，逐字节
  specs/<键>.json              每个根与被引用的嵌套规格各一个文件，扁平目录
```

`pubspec.yaml` 只登记 `assets/completions/` 与 `assets/completions/specs/`（Flutter 不递归子目录，所以文件名扁平）。文件名 = 规格键中 `/` 换成 `__`，不在 `[A-Za-z0-9._@+-]` 内的字符转成 `_xHH_`；大小写不敏感地检查重名，重名则整体失败。

### manifest.json

```json
{
  "version": 1,
  "source": {
    "name": "@withfig/autocomplete", "repository": "...", "commit": "...", "packageVersion": "2.692.3",
    "archive": {"url": "...", "sha256": "...", "bytes": 0},
    "license": {"file": "assets/completions/LICENSE", "sha256": "...", "licenseFile": "MIT", "packageJson": "ISC", "note": "..."},
    "parser": {"name": "typescript", "version": "5.9.3", "integrity": "sha512-..."},
    "importer": {"script": "tool/import_completion_specs.mjs", "schema": 1, "limits": {...}}
  },
  "commands": {"git": "assets/completions/specs/git.json", "python3": "...", "@usermn/sdc": "..."},
  "nested": {"aws/ec2": "assets/completions/specs/aws__ec2.json"},
  "stats": {"roots": 0, "nested": 0, "assets": 0, "bytes": 0, "unsupported": {"<种类>": 0}, "omitted": {"<字段>": 0}, "...": 0}
}
```

- `commands`：用户输入的命令词 → 资源路径（`rootBundle` 键）。键 = 文件决定的根名，再加规格 `name` 数组里的别名；别名与其他根名冲突时让给文件名，冲突写进审计。
- `nested`：`loadSpec` 字符串 → 资源路径。目标自己是根时也登记，解码器只查这一张表；`commands` 里的键不参与。
- `stats` 是汇总，完整逐根明细在 `tool/import_completion_specs.audit.json`（不进应用包）。

### 规格文件

根与嵌套规格的文件内容就是一个 Subcommand 节点，没有外层包装、没有来源元数据。字段是 Fig 的子集，名称与 Fig 一致；缺省字段不写，空数组不写。

Subcommand（根也是）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string \| string[] | 子命令名，数组是别名 |
| `description` | string | 截断到 160 字符，在词边界切并加 `…`；取首个非空行 |
| `displayName` | string | |
| `insertValue` | string | 可含 Fig 的 `{cursor}` 占位 |
| `priority` | number | 0–100，Fig 的排序提示 |
| `hidden`、`deprecated`、`isDangerous`、`requiresSubcommand` | true | 只写 true |
| `parserDirectives` | object | 仅 `flagsArePosixNoncompliant`、`optionsMustPrecedeArguments`（bool）与 `optionArgSeparators`（string \| string[]） |
| `loadSpec` | string | 静态引用，内容在 `manifest.nested[loadSpec]`；本节点自己不再带 `subcommands/options/args`（有也保留，加载后追加在其后） |
| `subcommands` | Subcommand[] | |
| `options` | Option[] | |
| `args` | Arg \| Arg[] | 对象或列表，保持源码形态 |
| `additionalSuggestions` | Suggestion[] | |

Option：`name`（string \| string[]，含 `-` 前缀）、`description`、`displayName`、`insertValue`、`priority`、`hidden`、`deprecated`、`isDangerous`、`isPersistent`、`isRequired`、`requiresEquals`（true）、`isRepeatable`（true \| 正整数，Fig 的数字表示可重复次数）、`requiresSeparator`（true \| string）、`exclusiveOn`（string[]）、`dependsOn`（string[]）、`args`（同上）。

Arg：`name`、`description`、`isOptional`、`isVariadic`、`isCommand`、`isScript`、`isModule`（true \| string）、`optionsCanBreakVariadicArg`、`suggestCurrentToken`（true）、`default`（string）、`template`（string \| string[]，`filepaths`/`folders`/`history`/`help`）、`suggestions`（Suggestion[]）。

Suggestion：只有名字时是字符串；否则 `{name, description?, displayName?, insertValue?, priority?, hidden?, deprecated?, isDangerous?}`（`name` 可为 string[]）。

固定丢弃（计数，不静默）：`generators`、`generateSpec`、`loadSpec` 为函数/动态值、`icon`、`postProcess`、`script`、`custom`、`filterStrategy`、`debounce`、`cache`、`isOptional` 以外的函数字段，以及任何不在上表的字段。没有名字的节点、名字不是字符串的节点整体丢弃并计数。

覆盖含义：输出是“静态能读出来的那部分”。依赖生成器的参数（git 分支、docker 容器、aws 配置档等）没有候选，函数构造出的子命令（如 `php.ts` 的 `generateSpec`）缺失。审计里的未支持/丢弃计数就是这部分的量度，不要据此说“覆盖 Fig”。

## 预算

| 项 | 上限 |
|---|---|
| 归档（压缩前） | 64 MiB |
| 解压后总量 / 文件数 / 单文件 | 384 MiB / 20000 / 8 MiB |
| 解析源码总量 | 256 MiB |
| 单个输出文件 | 3 MiB |
| 全部输出 | 56 MiB |
| 嵌套引用链 | 16 层 |
| 单规格节点数 | 400000 |

上限是失败条件，不是静默截断；唯一的有损变换是说明截断到 160 字符，计入统计。

## 审计与测试

导入时和测试里共用同一个不变量校验：JSON 可解析；每个 manifest 路径存在且无多余文件；规格内只有白名单字段，类型符合上表；没有函数/图标字段；`loadSpec` 都能在 `nested` 找到；`commands`/`nested` 的路径都在 `specs/` 内。

`tool/test/import_completion_specs.test.mjs`（`node --test`，不联网）用 `tool/test/fixtures/completion_specs/` 的小型上游样子的源码树，覆盖：本地导入、const 与 spread、模板字符串、`as const`、函数省略、不支持调用的计数与路径、生成器与图标丢弃、名字数组别名、作用域根和 `index.ts` 根、版本化规格、`loadSpec` 嵌套与环/超深/缺失、恶意路径与符号链接的 tar 条目、预算失败、输出确定性、LICENSE 逐字节保留。解析器目录用环境变量 `SSHAIRY_TYPESCRIPT_DIR`；未设置时测试报告“跳过”，不算通过。

## 解码器约定（Dart 一侧）

纯 Dart：读 `manifest.json` 建 `commands`/`nested` 两张表；用 `rootBundle` 按需读单个规格文件；缺省字段按 Fig 默认值（`isOptional` 假、`isVariadic` 假、`isRepeatable` 假、`isPersistent` 假）；遇到未知字段忽略；遇到 `loadSpec` 查 `nested`，目标可能互相引用成环，只在用户输入走到那里时才加载。`aws`、`az`、`gcloud` 的嵌套文件很大，不要一次性解析全部。

## 实现状态

2026-11-08 从上述固定归档重新生成：727 / 727 根成功，失败 0，738 个命令名（含别名）、744 个嵌套索引、1451 个规格文件，规格共 55,134,421 字节、681,944 个节点。根导出能投影成功不表示动态字段可用：生成器、运行时 loadSpec 和动态建议仍省略，细项见审计 JSON。

- `node --test tool/test/import_completion_specs.test.mjs` 使用固定 TypeScript 解析器，28 项通过；测试含恶意归档条目、静态 helper、预算和确定性。
- `test/completion_assets_test.dart` 实际逐个解码 manifest 指向的全部 1451 个规格，检查常用命令的选项/子命令不再受 8 条限制，以及 AWS 嵌套规格接线。
- 运行时通过 `CompletionSpecs` 惰性加载，仅追踪当前命令分支的嵌套引用（最多 16 轮、每轮最多 32 个缺失引用）。全局 LRU 最多 32 个资源，按输入字符串 UTF-16 大小估算的缓存成本最多 16 MiB；这不是解码后对象堆的精确上限。原始规格 `loadString(cache:false)` 不留在 AssetBundle 字符串缓存，同一路径在途加载合并。
- 顶层候选的说明与可浏览标记另由 `tool/generate_completion_command_metadata.dart` 从随包 JSON 生成纯 Dart 小索引，覆盖 738 个命令名，不为名称列表加载完整规格；`--check` 验证与源数据一致。运行时明确的 `cd` 路径修正也体现在索引。该索引、离线中文映射和未覆盖说明的类型回退不改变来源 JSON、manifest 或许可统计；悬浮保留来源说明，中文映射不是全库完整翻译。
- 上游 LICENSE 已加入 Flutter 许可注册与打包 notices，派生的根说明索引与译文沿用同一来源声明；包级 ISC 与文件级 MIT 的不一致仍保留说明，未替代正式发行的许可审计。
- Release 包体与逐文件资源校验记录见 ROADMAP；真实窗口性能或大量大型规格加载的内存仍未实测。
