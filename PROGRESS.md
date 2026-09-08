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
| S1 | hir.zig 结构 | arena 句柄/容器 + 注册表骨架 + 白盒 | done（本次提交） |
| S2 | 文本 printer/parser | 前缀括号文本、binder 确定性编号、round-trip | done（本次提交） |
| S3 | 结构 validator | hir.md §10.1 第一级 | done（本次提交） |
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

### S1 — hir.zig 结构（done）

- [x] `hir.zig`（新建）：句柄（ExprId/RegionId/BinderId/PatternId/FullExprId/
      ScopeId/SemanticInfoId/AttrSetId/OpId + Range）、Program 容器（实体 arena +
      expr/region/binder 扁平缓冲 + append 助手 + 只读访问器）、ExprNode（泛型节点 +
      typed `payload`：const/local/fn_ref/module_const/field/tag）、Region/Binder
      （mode）、arm region 可选 `pattern`（文档化的布局选择，§5.4）、Pattern
      （子模式按 PatternId 引用）、Scope/FullExpr 最小记录（无 cleanup 执行）、
      SemanticInfo（**仅 ownership_view**，无效果字段）、OpRegistry（§7.1 22 个核心
      opcode + §7.2 8 个 typed 样本行 + comptime validateRegistry 身份/形状检查）。
- [x] `cfg.Type` 内联为节点/绑定类型（无 HIR 类型 interner——§3.8 Target 形式不做，
      不建第二类型世界）；常量复用 `cfg.ConstValue`。
- [x] root.zig 导出 `hir`（refAllDecls 纳入库测试）。
- [x] 白盒 `test{}`（7 个）：句柄 fresh / 扁平 Range 跨增长稳定与有序、let init
      在 binder region 之外（结构镜像 §5.3）、payload 具体值、pattern 绑定叶引用
      arm region params、ownership views（0 = 默认 owned）、注册表身份/形状、typed
      rep 映射 cfg.Type。**整树拒绝测试（捕获/DAG/作用域）归 S3，不在 S1。**
- 验收：`zig build -fincremental test` 全绿（1019 tests 通过，含 hir 的 7 个白盒）。
      包含性证明记录：首次临时失败断言遇编译错误未生效；改用真实失败断言（hir.test.*
      被点名）确认收集后移除，全绿。
- 栅栏：无 `EffectSummary` / `effect_transfer` / `seg_*` 标识符落盘。

### S2 — 文本 printer + parser（done）

- 范围决策（用户批准）：引入**最小序列化上下文** `SerCtx`（夹具 decl 表 +
  `cfg.substParams` 简单代换），§4.7 例2（match + Option[i32]）golden 逐字往返；
  struct_make / field_get / variant_make 的成员/标签身份文本形态**推迟 + 报错**
  （§4.4 缩写丢身份；print/parse 两侧显式拒绝，绝不静默降级）。
- `passes/hir_parse.zig`：词法 + 递归下降（expr/ty/binder/pattern/region）；`#refs:`
  字典（§4.8 stable key，严禁猜号）；**文本级 §5.3 初始化排除**（let init 先于声明入
  作用域，自引用即报错）；函数边界不捕获留 S3（解析期通过）；arm pattern 绑定叶按
  文本序映射 region params（类型经 decl 代换推导）；名义类型经 SerCtx 解析。
- `passes/hir_print.zig`：canonical 单行输出；**确定性 binder 重编号**（首次引入序 =
  文本出现序）；refs 打印号按 stable key 排序 + 字典行；结果类型派生 vs `: ty` 标注
  （num_cast/any_cast/空 list_make 标注；fn/match/let/seq/call/tuple/list 结构推导）；
  then 分支嵌套 if 加括号防 else 悬挂。
- `hir.zig`：`SerCtx` + `mul.i32` 注册行 + print/parseText/Parser/Diag 再导出；追加测试
  强制分析两个 pass——zig 懒分析下无调用者则其 test{} 不注册（探针实验证实；cfg.print
  因 main 调用被分析、hir.print 无调用者）。
- 测试（printer 属主 white-box）：§4.7 例1/2/3 + §8.7 片段 parse→print→parse α-等价；
  canonical 输出逐字稳定；α-等价文本打印相同；let init 排除 / 出域引用 / 未声明 binder /
  未知 opcode / 裸数字字面量 / 元数错误 / 无 ctx 名义类型 / refs 无字典条目 全拒绝；
  成员身份 op 文本两侧拒绝。独立递归 α-等价比较器（binder 位置映射）。
- 验收：`zig build test` 全绿 exit=0（全套 ~1032 tests 含 hir 文本套件——失败日志点名
  `passes.hir_print.test.*` 证明收集）；`zig build -fincremental` 绿。
- 栅栏：无 `EffectSummary`/`effect_transfer`/`seg_*` 落盘。

#### S2 取舍与风险（记录）

- refs 跨 invocation 字节稳定依赖 SerCtx stable key（同 ctx 内已稳定）；接真实 module
  key 的缝在 S4。pattern 内数字字面量打裸数字（pattern 只存 value，重解析默认 i64/f64）。
  非有限浮点非 v1 文本可序列化（报错）。
- 发现 cfg 先例：AIR 文本成员用显式数字下标（`load_member %v, #3`）；hir §4.4 缩写形
  态与 token 集均未定义成员身份 → 按用户决策推迟，报错保护，S4 定成员文本表达。

### S3 — 结构 validator（done）

- `passes/hir_validate.zig`（新建，`validate(program, root, allocator) !?[]const u8`，
  cfg_validate 约定：null=通过，否则首违例消息）：**迭代**遍历（显式 worklist，天然
  免疫深层恶意 arena 的栈溢出），从给定 root 校验可达树、不要求 arena 全可达（S4 多
  函数 root 扩展点已在文件头注明）。
- 校验项（对照 §10.1 第一级，效果分析关闭）：
  - 边界先行：每个 expr/region/binder/pattern id 与 operand/region/param range 先查
    界再索引，恶意 arena 不崩溃；
  - 树形无 DAG（§3.7）：同一 ExprId 两次出现（共享子树 / 回环）即拒；region 唯一
    属主；pattern 可跨 arm 共享但 pattern 环拒（0/1/2 状态 DFS）；
  - 作用域（§5.3）：`local` 沿词法 region 祖先链解析，**λ region 即函数边界**（自身
    params 可用、不可外穿 → 不捕获）；let init 在 let 所在 ctx 求值、天然够不着自己
    的 region params → **init 排除结构性成立**；
  - 无重复 BinderId：同一 binder 至多是一个 region 的 param（含同 region 内重复）；
  - region/pattern 形状：let region 恰 1 个 binder、if region 0 个、pattern 只出现在
    match arm；arm pattern 绑定叶（bind/type_test）与 arm region params **双射**；
    无 pattern 的 arm 不得带 params；
  - payload/op 配对（S1 注释点名的 S3 职责）+ descriptor operand/region 元数 +
    op id 界；
  - full_expr / sema 只查**归属界**（membership-only：FullExpr 在 M1a 是身份记录，
    生命周期边界/清理登记序/跨边界改写是 SEG/lowering 层职责——不越权，无清理机制）。
- 测试（属主 white-box，15 个）：§4.7 三 golden + §8.7 片段 parse 后通过；shadowing /
  嵌套 let / if 有无 else / 空 λ 通过；**capture 文本可 parse、被 validator 拒**
  （`fn (B0) => fn (B1) => %B0`——parse 不设 λ 边界，validator 设）；sibling arm
  漏 binder 拒；DAG 共享 operand / 自环 / region 双属主拒；单 region 重复 binder 拒；
  let init 引用自身 binder 拒；OOB id / range 越界（含 root 越界、operand id 不存、
  range 超缓冲）拒；payload 错配 / 元数错拒；full_expr、sema 越界拒；arm pattern 与
  params 失配拒；pattern 出现在非 arm region 拒；pattern 环拒；let/if region 参数数
  规则拒。
- 验收：`zig build test` 非增量全绿 exit=0（~1047 tests，含 hir_validate 的 15——
  临时失败断言点名 `passes.hir_validate.test.*` 证明收集后移除）；`zig build
  -fincremental test` 绿；`zig fmt --check src/` 绿。
- 限制（记录在案）：full-expr 只查归属界；ownership/effect 数据流与 SEG 相关不变量
  不在本档；S4 构建产物复验同入口。
- 栅栏：无 `EffectSummary`/`effect_transfer`/`seg_*` 落盘。

#### S3 过程记录（风险）

- 首次 `zig build -fincremental test` 出现一次 ~15 分钟空转无输出（无新 test 二进制
  产出）；重启后正常（~3 分钟编译 + 秒级测试）。原因未定，怀疑增量 listener 卡死；
  后续轮次均正常，无代码关联证据。中途两轮编译错误为返回类型可选包/error-union
  再包问题（`return self.fail(...)` 不隐式剥 error-union 包 optional；改为捕获后
  `return msg;`），已记录。

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
| 2026-09-08 | S0 | docs(hir) S0 提交 | 声明 M1a 接缝（passes.md/frontend.md/architecture.md/README.md）+ 开 PROGRESS |
| 2026-09-08 | S1 | 本次 docs(hir) S1 提交 | hir.zig 数据骨架 + root.zig 导出 + 7 白盒测试；docs 措辞更新为「S1 数据已落地、阶段未接线」 |
| 2026-09-08 | S2 | 本次 feat(hir) S2 提交 | passes/hir_parse.zig + hir_print.zig；hir.zig SerCtx/mul.i32/再导出/强制分析测试；§4.7/§8.7 golden round-trip + binder 重编号 + #refs 字典；成员身份文本推迟（用户批准） |
| 2026-09-08 | S3 | 本次 feat(hir) S3 提交 | passes/hir_validate.zig 结构校验（§10.1 第一级）+ hir.zig 再导出/强制分析测试扩为三 pass；15 白盒测试（含 parse 可过、validator 必拒的 capture 文本）；验收 = 全套 ~1047 tests 绿 |
