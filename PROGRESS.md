# PROGRESS — Stilla HIR M1a 实施追踪

> 本文件记录 docs/hir.md §11 **M1a**（结构 HIR）分阶段实施的进度、验收与决策。
> 接缝声明与 pass 顺序见 passes.md、frontend.md、architecture.md；设计规范以
> hir.md 为准（其中 §9 为 HIR→CFG lowering 契约，§10.1 为结构校验不变量，
> §10.3 为语义等价门禁，§11 为落地档位）。
>
> **工作规则**：每阶段以 `zig fmt src/` → `zig build -fincremental` →
> `zig build -fincremental test` 全绿验收；一阶段验收完成即**暂停**，
> 不自动进入下一阶段，等待指示后再开工。

## 范围（M1a）

- 目标：checker 与 CFG lowering 之间的**结构 HIR seam**（兼容边界，hir.md §2.3、§11）。
- 输入：只消费 checker 注解与 module graph 的已判决结论，不重新推理（§2.4）。
- 形态：arena + 稠密句柄；binder / region / pattern 统一为 region params；名字不进 IR；
  HIR 是树、禁 DAG；full-expression 栅栏。
- 效果分析**关闭**：不实现效果模型、不设效果字段；SemanticInfo 仅携带 ownership_view
  （M1a 允许，§11）；效果相关校验只跑结构一级（§10.1）。
- SEG（§8 全部）不在本档；post-CFG drop 展开、LLIR lifecycle、AIR/CFG validator/optimizer 不变。
- **唯一验收**：语义等价门禁（§10.3）——现有全部 suite 不改语义通过；
  AIR 文本（`cfg.print` 规范化）或解释执行输出等价。
- 栅栏：不落 `EffectSummary` / `effect_transfer` / `seg_*` 标识符
  （允许注释引用 M1b / M2a）。

## 阶段总览

| # | 阶段 | 内容 | 状态 |
| --- | --- | --- | --- |
| S0 | 文档先行 | 声明 HIR 接缝与 pass 顺序；开 PROGRESS | done（本次提交） |
| S1 | hir.zig 结构 | arena 句柄/容器 + 注册表骨架 + 白盒 | pending |
| S2 | 文本 printer/parser | 前缀括号文本、binder 确定性编号、round-trip | pending |
| S3 | 结构 validator | hir.md §10.1 第一级 | pending |
| S4 | AST→HIR builder | M1a 主件；CFG 行为不变 | pending |
| S5 | HIR→CFG + 等价门禁 | toggle + 字节差分 | pending |
| S6 | 全量覆盖 + 默认翻转 | 删除直降路径 | pending |
| S7 | 文档回填 | hir.md 状态、README 移出 Unimplemented | pending |

## 各阶段明细

### S0 — 文档先行（done）

- [x] passes.md：checker 与 CFG lowering 之间加「HIR seam — planned, M1a」节，
      目标顺序 build → validate → lower；planned 文件名显式标注。
- [x] frontend.md：§1 加 **target-only** 图（当前直降管线不动）；§4 加未勾选
      M1a 条目；「every pass is implemented」限定为 current 管线。
- [x] architecture.md：Boundaries 表加 planned HIR seam 行（owns / does not own）。
- [x] README.md：hir.md 保留在 Unimplemented proposals，注记 M1a 为已登记实施
      目标、尚未接线（无 HIR 代码）。
- [x] 新建本文件 PROGRESS.md。
- 验收：docs-only；`zig build -fincremental test` 全绿。

### S1 — hir.zig 结构（pending）

- 目标：arena + 稠密句柄；ExprNode（op/ty/operands/regions 扁平切片）；Region/Binder
  （mode）；Pattern/FullExpr；SemanticInfo（仅 ownership_view，无效果字段）；
  core-op 注册表骨架（§7.1，无 seg/effect 字段）。
- 文件：`hir.zig`（仿 cfg.zig：数据 + 再导出）；白盒测试在属主模块 `test{}`。
- 验收：`zig build -fincremental test`；白盒：切片 append、句柄 fresh、结构构造。

### S2 — 文本 printer + parser（pending）

- 文件：`hir_print.zig`、`hir_parse.zig`（由 hir.zig 再导出，仿 cfg_print/cfg_parse）。
- 验收：golden 取自 hir.md §4.7/§8.7 示例：`parse(print(parse(example))) == parse(example)`；
  binder 重编号 round-trip。

### S3 — 结构 validator（pending）

- 文件：`hir_validate.zig`。
- 校验：作用域 / init 排除 / 不捕获 / 树形无 DAG / 无重复 BinderId / full-expr 归属
  （§10.1 第一级，效果分析关闭时）。
- 验收：对 S2 解析结果与 S4 构建结果跑校验；恶意文本（越界引用、共享子树）被拒。

### S4 — AST→HIR builder（pending）

- 目标：消费 module graph + checker.Annotation（含 mono 体）→ 逐 module 的
  `hir.Program`：函数 / 实例 / drop hook / @init 体；路径解析为 fn_ref / module_const；
  lambda 与 intrinsic wrapper 提升（复刻 cfg_lower_func / cfg_lower_intrinsic 的
  命名与次序）；full-expr 标注；ownership_view 搬移。
- 文件：`hir_build.zig`（数据在 hir.zig）；入口 `buildProgram(graph, &ck.annotation)`。
- 验收：probes/、examples/ 语料构建无 validator 报错；全 suite 绿（本阶段无 CFG 影响）。

### S5 — HIR→CFG + 等价门禁（pending）

- 目标：新 lowering 驱动，复用 lower.zig / FuncState / cfg_lower_emit 的
  block/value/drop 机制；code-only 开关 `frontend.Options.hir_stage`（默认 false），
  frontend.compile phase3 二选一。
- 文件：`hir_lower.zig`（逐 HirFunc → cfg.IrFunc；内部再分 expr/control/call/pattern，
  复用或适配 cfg_lower_pattern）；`hir_tests.zig` 并导入 root.zig。
- 验收：同源 `compileText` 与 `compileText(…, .hir_stage = true)` → `irText` 逐字节
  相等；不可比时 `--run` 输出相等；`zig build run -- examples/fib.st` 开关前后
  stdout 一致；suite + `zig build -fincremental examples` 绿。

### S6 — 全量覆盖 + 默认翻转（pending）

- 覆盖：泛型实例/mono、match pattern、move/borrow/drop、any 打包、list pattern、
  intrinsic、host binding syscall、@init。
- 删除直降路径；开关翻默认 true 后移除。
- 验收：删除前以 probes/ + examples/ + std 语料跑开关 on/off 差分（输出相等）作
  最终等价基线，再删；suite（含 llir/解释器）、examples 绿。

### S7 — 文档回填（pending）

- hir.md 状态从「提案」改 implemented（M1a 范围）；passes.md / frontend.md 同步；
  docs/README.md 将 hir.md 移出 Unimplemented proposals。
- 验收：docs 提交 + 全 suite 绿。

## 风险与未知（实施时注意）

- **逐字节等价风险最高**：cfg 文本输出对 block 名、函数创建顺序
  （lambda / intrinsic wrapper 的 `next_lambda_id` / `next_intrinsic_id`）、值序
  敏感；HIR builder 若与今日「边 lowering 边提升」的次序差一步，文本即不等。
  差分测试从最小 probe 逐例扩到全语料，先锁字节、再谈翻转。
- full-expression 边界（drop timing）标注错位静默改变销毁顺序，结构 validator
  抓不到（§8.4 言明 destructor timing 校验不收）；靠字节差分兜底。
- pattern lowering：cfg_lower_pattern 吃 ast.Pattern；HIR pattern arena（§5.4）
  后 HIR→CFG 的 pattern lowering 需适配或新写。
- intrinsic 展开位置：文档说 canonical HIR 无 intrinsic 痕迹、lowering 早期展开；
  现实现是 cfg_lower_intrinsic 在 emit 期合成 wrapper / 展开——HIR builder 须在
  构建期复刻，S4 内核对齐语义。
- 效果字段表示：按「分析关闭、不带效果字段」执行；若实施中发现需要占位字段，
  回到本文件更新并注明理由。

## 变更记录

| 日期 | 阶段 | 提交 | 说明 |
| --- | --- | --- | --- |
| 2026-09-08 | S0 | 本次 docs 提交 | 声明 M1a 接缝（passes.md/frontend.md/architecture.md/README.md）+ 开 PROGRESS |
