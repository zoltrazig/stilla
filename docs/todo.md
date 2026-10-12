# Stilla 编译器与运行时整改待办

> 本文件是**前瞻性、可执行的整改计划**：按优先级列出整个编译器与运行时的
> 待办项，每项给出问题、代码证据、建议工作与验证方式。
> [roadmap.md](roadmap.md) 是**设计层 backlog**，记录每项的设计依据、依赖与验收；
> 本文件只做优先级排序与可执行化，重叠处只引用 roadmap.md 的小节，不重复其论证。
> 本文件不是工作日志：完成的条目直接删除，不归档。条目使用稳定的区域前缀标识
> （F/O/B/T/S）以便交叉引用，但不使用 milestone/stage/phase 标签。

## 目标

- 收敛编译器与运行时中**已知的规范违反、实现不一致与可观测缺陷**，按正确性
  优先排列，使每一项都能独立验证。
- 把「优化空间」与「测试/规范缺口」从设计文档里显式化，形成可直接开工的清单。

## 范围

整个编译器与运行时：

- 前端：词法、语法、module graph、checker（注解与消费者检查）；
- 中端：HIR 构建与校验、effect 分析、HIR 消费者与 SEG；
- 优化管线：CFG 优化序列、LLIR 后端与二进制格式；
- 运行时：LLIR 解释器 VM 与析构 walker；
- 规范与文档：规范文本（`spec`）与设计文档（`docs`）同代码的一致性。

## 非目标

- 不在本文件重复 roadmap.md 的设计论证；设计细节以 roadmap.md 与各设计文档为准。
- 不改动规范文本的语义决策本身（例如 teardown 措辞的取舍属 roadmap.md 的
  spec-blocked 项）；本文件只登记需要落地的具体修改。
- 不记录工作历史，也不使用工作编号。

## 约定

- 每个条目字段固定：优先级、问题、证据、建议工作、验证方式、关联。
- 优先级含义：**P0** 正确性/规范违反；**P1** 可观测的规范或一致性缺陷；
  **P2** 优化、精度或健壮性；**P3** 清理与长期方向。
- 证据统一引用 `文件名:行`，不写仓库路径。
- 验证方式给出定向测试名、过滤运行
  `zig build -fincremental test -Dtest-filter=<name>`，或一个明确的检查。
  过滤值必须取自测试声明里真实出现、且能区分目标测试的子串；保留在本文档
  中的每个过滤值都必须实测运行超过 8 个测试（8 是匿名聚合测试的基线，零匹配
  的过滤只跑这 8 个而假绿）。
- 关联指向 roadmap.md 的对应小节；没有对应小节时标「无」。
- 所有编译/测试命令前缀统一为 `zig build -fincremental`。
- 优先级例外：O12 的未开关 LLIR peephole / drop lowering 属可差分性与健全性
  相邻的缺口，但为保持优化管线按优先级单调排列仍列 P3，并应在优化 on/off
  差分（T1）落地前优先处理。

---

## 前端与中端

### F5 解构 `let` 上的类型标注被拒绝

- **优先级**：P2
- **问题**：`let <pattern> : <type> = init;` 语法允许，checker 也已解析该标注，但
  HIR 构建对「解构 `let` + 类型标注」直接失败。这是未在 `checker.md` 记录的隐性
  限制（普通标识符 `let` 的标注可用）。
- **证据**：`hir_build_block.zig:222`（`a type annotation on a
  destructuring let is unsupported`）；语法
  `Stilla Core Grammar Draft.abnf:454-460`；checker 已解析
  `checker_annotate.zig:240-247`。
- **建议工作**：要么在 HIR 构建中支持该标注（把标注类型下推给 pattern 叶子），
  要么在 `checker.md` 明确记为限制并在 checker 层更早报错。
- **验证方式**：若支持，`hir_tests.zig` 补带标注解构 `let` 的 round-trip 用例；
  若记为限制，`checker_tests.zig` 补诊断用例；`zig build -fincremental
  test -Dtest-filter=checker`。
- **关联**：无

### F6 泛型 struct 的 drop hook 被拒绝

- **优先级**：P2
- **问题**：checker 拒绝在泛型 struct 上声明 drop hook（因为 monomorphize 只克隆
  函数模板、不克隆 hook，hook 会静默不运行）。规范并未排除泛型 struct 的 hook；
  这是实现限制，需要么实现 per-instantiation hook 展开、要么在规范/文档中记为限制。
- **证据**：`checker_annotate.zig:103-116`（`:110-113` 拒绝）。相关：
  `cfg_lower_program.zig:62`（泛型声明 ownership 为 `null`）、
  `checker.md` 泛型展开章节。
- **建议工作**：评估在 monomorphize 中为泛型 struct 克隆 hook；若成本过高，
  把限制写入 `checker.md` 并确认诊断文案。
- **验证方式**：若实现，新增 `probes/*.st`（泛型 struct + 可观察 hook）并纳入
  on/off 差分；若记为限制，`checker_tests.zig` 断言诊断；
  `zig build -fincremental test -Dtest-filter=checker`。
- **关联**：无

### F7 词法接受指数浮点，规范未定义

- **优先级**：P2
- **问题**：lexer 接受 `1.5e19` / `5e-324` 指数字面量，但语法里
  `float = 1*digit "." 1*digit` 无指数形式；解析语义、后端与运行时都未对此定义，
  也没有测试。
- **证据**：`lex.zig:343-353`；语法 `Stilla Core Grammar Draft.abnf:92`。
- **建议工作**：要么从 lexer 移除指数识别（`e` 另起 token），要么扩展语法的
  `float` 产生式并定义其值与范围语义，补齐各层测试。
- **验证方式**：`lex_tests.zig` 补指数用例（按所选决策断言 token 流）；
  `zig build -fincremental test -Dtest-filter=lex`。
- **关联**：无

### F8 含类型参数的 tuple 所有权分类返回 unique 而非 deferred

- **优先级**：P2
- **问题**：所有权结构分类对未特化类型参数应返回 `null`（deferred）。`.list` /
  `.box` / `.param` 都遵守（子元素为 param 时上浮 `null`），但 `.tuple` 在任一元素
  返回 `null` 时回退为 `unique`，与 `checker.md` 的记录及同族类型的处理不一致，
  可能在 monomorphize 前错误标记。
- **证据**：`type_shape.zig:100-112`（`:103` param→null、`:104`
  list/box 递归、`:105-112` tuple 回退 unique）；`checker.md:65-69`。
- **建议工作**：tuple 与 list/box 对齐——任一元素为 deferred 则整型 deferred；
  补白盒用例（`tuple[File, T]`、`tuple[T, T]`、全具体元素）。
- **验证方式**：`type_shape.zig` 的 `test {}` 白盒或
  `checker_tests.zig` 黑盒；`zig build -fincremental test -Dtest-filter=checker`。
- **关联**：无

### F9 陈旧的相等域诊断文案

- **优先级**：P2
- **问题**：`isEqScalar` 的注释与 `validateBinary` 的诊断文案只列
  `byte, int32, uint32, float32, bool, str` 六类，但实现已含 `int64` / `uint64` /
  `float64`，诊断会误导。
- **证据**：`checker_validate.zig:1000-1008`（注释与实现）、`:309-314`
  （文案）；实现本身正确（`:1006`）。
- **建议工作**：把注释与诊断文案更新为实际相等域（含 64 位整型与 `float64`）。
- **验证方式**：`checker_tests.zig` 补 `int64 == int64` 正例与 `any == any`
  负例并断言文案；`zig build -fincremental test -Dtest-filter=checker`。
- **关联**：无

### F10 前端反例测试缺口

- **优先级**：P2
- **问题**：F2–F9 各自要求的定向反例尚未落地（drop-hook `let` 解构、块作用域无
  `as` 的 `using`、未解析 `using`、解构 `let` 类型标注、指数浮点、tuple-param
  所有权），另缺泛型实例上限 `kMaxInstances` 的边界用例；改动容易回归。
- **证据**：`kMaxInstances` 位于 `checker_annotate.zig:1343-1346`；其余缺口的
  代码位置见 F2–F9。
- **建议工作**：为每项补一条定向正/负例，放入对应模块的 `test {}` 或
  `checker_tests.zig`。
- **验证方式**：`zig build -fincremental test -Dtest-filter=checker` 覆盖 checker
  侧反例（含 `kMaxInstances` 边界），指数浮点用 `-Dtest-filter=lex`；逐项跑绿后
  再跑全量 `zig build -fincremental test`。
- **关联**：无

### F11 Typed HIR 方向（monomorphization 与 ownership 检查上移）

- **优先级**：P3
- **问题**：`hir.md` §2.3 记录了一个远期边界：先建 Typed HIR 再特化，把
  monomorphization 与 ownership 检查上移到 HIR 构建。该方向未立项，但应在 backlog
  中有明确位置，避免文档间遗漏。
- **证据**：`hir.md:111-129`（`2.3 与现状管线的边界`、`远期边界（Target）`）。
- **建议工作**：做一次范围评估并记录决策（采用，或明确放弃）。
- **验证方式**：一份写回 `hir.md` §2.3 的范围决策；若采用，
  `zig build -fincremental test` 全绿且全语料 `--emit-hir` 往返/逐字节不变。
- **关联**：roadmap.md「Typed HIR target (monomorphization and ownership checking on
  HIR)」（验收以该小节为准：采用需给出命名受影响 pass 与迁移测试的范围设计，且
  全语料已可编译、现有测试证明 ownership 检查在 HIR 上运行；否则放弃并从
  `hir.md` §2.3 删除该方向）

---

## 优化管线

### O3 CFG 优化无不动点

- **优先级**：P2
- **问题**：`optimizeOnce` 单发执行；`copyProp` 在 `pre` / `ifConvert` / `phiSimplify`
  之前，后者新暴露的 copy 与单入 phi 不会再被前序 pass 处理，留下可消除的冗余。
- **证据**：`cfg_optimize.zig:76-88`、`:102-105`（copyProp）、
  `:106-133`（pre / ifConvert / phiSimplify）。
- **建议工作**：引入有界 fixpoint（以各 pass 是否改变为收敛条件），或至少把 copy
  propagation / phi simplification 排到序列末尾并对其余相关 pass 重跑一次；inliner
  保持一次性（避免递归内联膨胀，见 `cfg_inline.zig:80-87`）。
- **验证方式**：新增 `probes/*.st` 触发「phiSimplify 后暴露 copy / 单入 phi」，
  断言新排序下 AIR 更小且运行输出不变；
  `zig build -fincremental test -Dtest-filter=optimizer`。
- **关联**：无

### O4 HIR simplify 与 SEG 单向

- **优先级**：P2
- **问题**：驱动先 `hir_simplify` 再 `hir_seg` 各一次；SEG 暴露出的新 dead-let /
  ANF 机会不会再被 simplify 看到。
- **证据**：`frontend.zig:346-363`（simplify）、`:364-392`（seg）。
- **建议工作**：改为 `simplify → seg → simplify`（或共享分析环），并保持每步后的
  revalidate。
- **验证方式**：新增触发「SEG 后新 dead-let / ANF」的 probe，断言第二遍 simplify
  使 AIR 进一步缩小且运行输出不变；`zig build -fincremental test -Dtest-filter=hir`。
- **关联**：无

### O5 PRE 少触发

- **优先级**：P2
- **问题**：`operandsDominate` 要求所有 operand 定义在严格支配者中，operand 在某个
  前驱内产生（部分冗余的常见形状）会被整块拒绝；候选集也不含 `read_field` /
  `read_tuple` / `tail` / `select`。
- **证据**：`cfg_pre.zig:145-164`（严格支配者）、`:218-252`（候选集）。
- **建议工作**：用「operand 在所有可用路径上已求值」的可用性判据替代严格支配者
  要求，并扩充候选集（含投影与 `select`）。
- **验证方式**：新增 `probes/*.st` 的部分冗余形状（一条路径已算、另一条未算），
  断言改写后 AIR 变化且运行输出不变；
  `zig build -fincremental test -Dtest-filter=redundancy`。
- **关联**：roadmap.md「HIR PRE (cross-statement and branch sharing)」（CFG PRE 是
  其设计指定的 fallback）

### O6 cfg_inline 无预算启发式

- **优先级**：P2
- **问题**：仅按 `calleeCost < 25` 决定内联，没有单调用点 / 叶函数 / 尾位 / 循环
  调用点的加成，也没有调用者规模 / 多调用点的惩罚。
- **证据**：`cfg_inline.zig:44-65`（启发式 TODO）、`:94-96`（阈值）、
  `:271-293`（筛选）。
- **建议工作**：在既有预算旋钮后实现有效预算启发式，并用优化 harness 语料调参。
- **验证方式**：新增 probe（单调用点与多调用点），`frontend_cfg_passes_tests.zig`
  断言 AIR 差异；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：roadmap.md「`cfg_inline` budget heuristics」（验收以该小节为准：单调用点
  且超预算应内联、多调用点同规模不内联，且每个优化后的程序仍然通过校验并产生
  不变的运行输出）

### O7 64 位 SEG 常量折叠缺失

- **优先级**：P2
- **问题**：SEG 的整数代数折叠对 `min` / `max` 只覆盖 `i32` / `u32`（另加
  `f32` / `f64`），`clz` / `popcount` 只覆盖 `i32` / `u32`；`i64` / `u64` 常量不折叠。
- **证据**：`hir_egraph_rules.zig:257-270`（clz / popcount）、
  `:288-312`（min / max）。
- **建议工作**：补齐 `i64` / `u64`（必要时对齐 `clz` / `popcount` 的口径与 HIR
  registry）的折叠分支。
- **验证方式**：`hir_egraph_rules.zig` 白盒补 64 位常量折叠正例；
  `zig build -fincremental test -Dtest-filter=egraph`。
- **关联**：无

### O8 `select` 永不参与 CSE

- **优先级**：P2
- **问题**：构造期 CSE 的候选集 `cseOk` 不含 `select`；独立 CSE pass 只识别
  `module_ref` / `load_member`，且早于 if-conversion，因此不同块中的相同 `select`
  永不合并。
- **证据**：`cfg_lower_emit.zig:1154-1188`（无 `select`）；
  `cfg_optimize.zig:98-113`（CSE 在 ifConvert 前）；
  `optimizer.md:300-304`。
- **建议工作**：在 if-conversion 后增加 select-aware、可跨块复用的 CSE（注意支配与
  所有权数据流），或在 emit 候选集中加入并调整顺序。
- **验证方式**：`frontend_cfg_passes_tests.zig` 新增「两块相同 select 合并」的
  正例与「operand / 类型不同不合并」的负例及 AIR 差异断言；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：roadmap.md「`select` CSE」

### O9 未知所有权策略在 pass 间不一致

- **优先级**：P2
- **问题**：同一个未解析（`null`）所有权在 pass 间语义相反，分成两组。
  保守组按「非 Copy」处理：`cfg_lower_emit` 的 copy 消除只在
  `ownership(...) == .copy` 时折叠（`null` 不进分支），`cfg_drop_elide` 只在
  `val.ownership == .copy` 时删除 drop（`null` 不被 elide）。未知⇒Copy 组用
  `(ownership orelse .copy)`，把 `null` 当成 Copy：`cfg_copy_prop` 会折叠该 copy、
  `cfg_dead_instr` 会删除其结果、`cfg_cse` 会跨块共享它。风险集中在后三个 pass——
  未知被当成 Copy 而删除、折叠或共享带 deferred 所有权的可观察析构。
- **证据**：保守组 `cfg_lower_emit.zig:84-89`、`cfg_drop_elide.zig:39`；
  未知⇒Copy 组 `cfg_copy_prop.zig:37`、`cfg_dead_instr.zig:175-181`、
  `cfg_cse.zig:64`。
- **建议工作**：统一为「未知一律保守」的单一查询（`cfg_lower_emit` 的
  `ownership(...) == .copy` 语义），或至少修正后三个 pass 的方向并在注释里记录
  其保守策略，避免未知被当成 Copy 而删除可观察析构。
- **验证方式**：构造 deferred-ownership（`null`）值的定向用例，断言 copy prop /
  dead-instr / CSE 均不折叠、不删除、不共享；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：无

### O10 inliner splice 对 BlockOrder 支配不变量的隐式依赖

- **优先级**：P2
- **问题**：构建 `value_map` 时对每个克隆值调用 `mapOrigin`；若某 borrow 的
  `origin.root` 尚未进表，`mapOrigin` 会回退为**原 callee 值**（静默指向错误值）。
  预分配按 BlockOrder 逐块进行，依赖「定义块排在引用块之前」这一未文档化的不变量。
- **证据**：`cfg_inline.zig:355-384`（预分配）、`:579-588`
  （`mapOrigin` 的 `orelse base` 回退）。
- **建议工作**：改为两遍预分配（先登记全部克隆值，再统一 `mapOrigin` 重定向），或
  在 miss 时失败关闭而非回退到原值。
- **验证方式**：新增白盒用例，构造 borrow origin 跨块且 BlockOrder 不保证定义在前的
  形状，断言 origin 被正确改写（而非静默保留原值）；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：无

### O11 缺失的优化能力（清单）

- **优先级**：P3
- **问题**：当前没有 GVN；没有通用 DCE（仅窄 op 集的 `cfg_dead_instr` 与 HIR
  dead-let）；没有循环优化（LICM / 展开 / 旋转 / 归纳变量，TCO 是唯一的循环相关
  优化）；没有间接调用 / 函数值内联；没有 HIR PRE（设计上推迟到 CFG）；没有线性值
  SEG；没有 `canMove`；没有强度削减、冗余分支消除、尾合并。
- **证据**：`cfg_dead_instr.zig:46-81`（窄 DCE 集）；
  `cfg_inline.zig:19-23`、`:271-293`（仅直接调用）；仓库内无 `gvn` /
  `licm` / 循环优化实现；`optimizer.md`。
- **建议工作**：按证据驱动逐项立项，并遵守 `probes/*.st` 触发要求（新 pass 必须有
  真正触发它的 probe）。
- **验证方式**：每项落地时新增触发 probe + on/off AIR 差异 + 运行输出不变；
  未立项时以「无实现」检查为准——`grep -rnE '\bgvn\b|\blicm\b' src` 为空，并对照
  roadmap.md 对应小节。
- **关联**：roadmap.md「SEG linear-value cases」「HIR PRE (cross-statement and branch
  sharing)」「`canMove` / `MovementContext`」

### O12 LLIR peephole 与 drop lowering 无开关

- **优先级**：P3
- **问题**：`llir_fusion` / `llir_result_coalesce` / `llir_expand_spills` /
  `llir_fuse_lifecycle` 在 `lowerLlir` 中无条件运行；CFG 的 drop lowering 在 `cfg`
  gate 下无条件运行。二者都不在 `OptimizeConfig` 中，无法单独关闭做差分。
- **证据**：`cfg_lower_llir.zig:498-509`（`:498` result coalescing、`:506` fusion、
  `:508-509` lifecycle/spill）；`frontend.zig:425-447`（`:445` drop lowering）。
- **建议工作**：把这些纳入 `OptimizeConfig`（至少 drop lowering 与 LLIR peephole 作为
  独立开关），以便优化 on/off 差分。
- **验证方式**：新增开关后用 on/off 编译同一 probe，断言结果一致或差异符合预期；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：无

### O13 pass 序号注释跨文件漂移

- **优先级**：P3
- **问题**：同一 pass 在不同文件里编号不一致：驱动头注释把 drop elision /
  dead-instr 记为 8.4、phi 8.5、jump 8.6，而测试文件记 drop 8.6、phi 8.7、
  jump 8.8、dead-instr 8.7。
- **证据**：`cfg_optimize.zig:6-11`；
  `frontend_cfg_passes_tests.zig:1-2`、`:33-34`、`:75`、`:151`、`:324`、`:663`；
  `optimizer.md:150-152`（只给顺序、无编号）。
- **建议工作**：选定单一编号来源（以 `optimizer.md` 的顺序为准，或直接去编号），
  同步所有注释与测试名。
- **验证方式**：grep 全仓编号并人工核对；`zig fmt --check src` 与
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：无

### O14 陈旧的 pass 注释

- **优先级**：P3
- **问题**：`cfg_copy_prop` 头注释说自己在 drop elision「之后」运行，但驱动实际先跑
  copy propagation；`cfg_drop_elide` 注释提到不存在的 `trydrop` op。
- **证据**：`cfg_copy_prop.zig:1-3`；`cfg_optimize.zig:102-105`、
  `:118-121`；`cfg_drop_elide.zig:1-3`、`:24`；另见
  `checker_ownership.zig:17` 的同类措辞。
- **建议工作**：修正注释（copy prop 在 drop elision 之前；删除 `trydrop` 措辞）。
- **验证方式**：与 `optimizer.md`、源码交叉核对；`zig fmt --check src`。
- **关联**：无

### O15 `cfg_copy_prop` 与构造期 copy 折叠冗余，端到端不可观测

- **优先级**：P2
- **问题**：`cfg_copy_prop` 子开关端到端不可观测：`cfg_lower_emit` 在构造期就把 Copy 值的 `copy` 折叠为其 operand，而 `cfg_copy_prop` 只在 `ownership != .unique` 时删除 `copy`，因此 lowering 产出的 AIR 中不存在该 pass 能删除的 `copy`；pass 实际不生效，翻转子开关不改变任何 AIR。
- **证据**：`cfg_lower_emit.zig:84-89`（构造期 copy 折叠）；`cfg_copy_prop.zig:37`（仅非 unique 时删除）；`frontend_cfg_passes_tests.zig:614-637`（合成用例在调用前已无 `copy %`）。全语料在 `--no-opt cfg_copy_prop` 与默认下 AIR 逐字节相同。
- **建议工作**：确定该 pass 的定位——删除（连同 `cfg_copy_prop` 子开关），或找到一个端到端能触发它的输入形状并在注释中说明为何端到端不可达；若保留，评估构造期折叠与 pass 的分工是否应合并以免冗余。
- **验证方式**：若删除，`grep -rn "cfg_copy_prop" src` 为空且 `zig build -fincremental test -Dtest-filter=OptimizeConfig` 通过；若保留，新增一个端到端触发该 pass 的 `probes/*.st`，或明确记录其不可达。
- **关联**：无

### O16 子开关到驱动的映射只单向完备

- **优先级**：P3
- **问题**：`frontend.zig` 的三处映射改为对 `OptimizeConfig` 反射后，只保证「`OptimizeConfig` 的子开关都有对应的目标字段」（缺目标字段即编译错误）；反向不成立——向 `cfg_optimize.Config` / `hir_seg.Config` / `hir_simplify.Config` 增加一个 bool 字段而不同步 `OptimizeConfig` 时，该字段静默保持默认值、没有子开关暴露。HIR 处的负向谓词（排除 `cfg_` / `seg_` / `egraph_` 前缀与门）对未来新增的同名无前缀字段也会静默误配。
- **证据**：`frontend.zig` 的 `runOptimizer` 与 `compile` 中的反射块；`cfg_optimize.zig:53-67`、`hir_seg.zig:336-376`、`hir_simplify.zig:157-187`。
- **建议工作**：加一处 comptime 断言，要求每个目标 Config 的子开关 bool 都有对应的 `OptimizeConfig` 字段；并把 HIR 处的负向谓词改为正向字段列表（`dead_let`、`anf`、`never_suffix`），使漏加或误配同样编译失败。
- **验证方式**：在 `optimize_config.zig` 或 `frontend.zig` 增加 comptime 检查；`zig build -fincremental test -Dtest-filter=OptimizeConfig`；`zig fmt --check src`。
- **关联**：无

---

## 后端与运行时

### B4 泛型实例化所有权分类不可靠

- **优先级**：P1
- **问题**：运行时 destruction walker 的 `typeIsUnique` 从序列化图像的
  `TypeDeclDesc.a` 读所有权，但泛型模板序列化为 `no_index`，于是所有泛型实例退化为
  Copy；被转移（Unique）的计数字段构造时会 retain，而固定 walker 释放一次，在
  walker-only 模式下净泄漏。当前 checker 拒绝泛型递归 union 且泛型计数字段会中止
  interning，故端到端暂不可达，但分类对未来可达实例不可靠。
- **证据**：`interpreter_dispatch.zig:1557-1597`（`typeIsUnique`）、
  `:1599-1609`（`retainConstructedChild`）；`cfg_lower_llir_intern.zig:286`、
  `:320-324`、`:340-349`。
- **建议工作**：按实例（而非模板）序列化所有权行，或把已解析的实例所有权穿到序列化层。
- **验证方式**：待 checker 接受可达程序后，新增
  `interpreter_lifecycle_tests.zig` 用例——泛型实例含 Unique 计数字段在
  walker-only 模式恰好析构一次（无泄漏、hook 运行）；
  `zig build -fincremental test -Dtest-filter=interpreter_lifecycle`。
- **关联**：roadmap.md「Generic-instantiation ownership classification in the destruction
  walker」

### B5 `abs.f64` 被 AIR 校验拒绝

- **优先级**：P2
- **问题**：HIR registry 定义 `abs.f64`，LLIR 有 `abs_f64`，VM 执行它，但 CFG AIR
  校验只接受 int32 / int64 / float32（还漏了 `abs.u32`），拒绝 `float64`。当前
  `math.abs` 只有 float32 故不可达，但校验与后端能力不一致。
- **证据**：`cfg_validate.zig:531-543`；`hir.zig:698-701`（`abs.f64`）；
  `llir_opcodes.zig:615-618`；`interpreter_dispatch.zig:1048`、`:1833`；
  `std/math.st:45`。
- **建议工作**：让 `abs` 校验接受与 registry / LLIR 对齐的完整集合（至少 `f64`；同时
  决定 `u32` 的取舍）。
- **验证方式**：`cfg_validate.zig` 白盒或 `frontend_cfg_passes_tests.zig`
  用例断言 `abs.f64` 通过校验；
  `zig build -fincremental test -Dtest-filter=validator`。
- **关联**：无

### B6 64 位 `clz`/`popcount`：构造期折叠与 HIR registry 缺失

- **优先级**：P2
- **问题**：AIR 校验接受 64 位 `clz` / `popcount`，LLIR 与 VM 支持，但构造期常量折叠
  只覆盖 32 位，且 HIR registry 只注册 `.i32` / `.u32`，64 位形式无法从 HIR 生成。
- **证据**：`cfg_validate.zig:544-548`（clz / popcount 规则）；
  `cfg_lower_emit.zig:957-994`；`hir.zig:702-705`；
  `llir_opcodes.zig:619-622`；VM `interpreter_dispatch.zig:1834-1835`、`:2055-2056`。
- **建议工作**：补 HIR registry 的 `clz.i64` / `popcount.i64`（unsigned 形式若需要）
  并扩展折叠；或明确 64 位形式不可达并从校验集移除。
- **验证方式**：`cfg_lower_emit.zig` / `hir_egraph_rules.zig` 白盒补 64 位
  折叠用例，`hir.zig` registry 注册测试；
  `zig build -fincremental test -Dtest-filter=egraph`。
- **关联**：无

### B7 `emitBinWithEntry` 的 `entry` 形参是死的

- **优先级**：P2
- **问题**：`writeWithEntry` 忽略 `entry` 实参、依赖 `image.entry_member`，但
  `lower.zig` 与 `main.zig` 的文件 / 测试注释都声称它把 entry 写入头部，API 会误导
  调用者。
- **证据**：`llir_emit_bin.zig:260-267`（`_ = entry;`）；
  `lower.zig:326-329`；`main.zig:437-446`、`:1074-1079`。
- **建议工作**：删除死参并让调用者先设置 `entry_member`，或在 `writeWithEntry` 内真正
  写入 entry；同步所有注释与测试。
- **验证方式**：`llir_emit_bin.zig` / `main.zig` 的二进制 round-trip
  测试（`-Dtest-filter=emit-bin`）断言 header entry
  与预期一致。
- **关联**：无

### B8 以 `unreachable` 处理可失败的分配（OOM→panic）

- **优先级**：P2
- **问题**：在返回错误风格的代码里，个别可失败操作（如 `DynamicBitSet.initEmpty`、
  `program.types` 的 `.alias` 分支）用 `unreachable` 收尾，allocator OOM 或未预期
  输入会变成 panic，绕过诊断。
- **证据**：`cfg_lower_lifecycle.zig:149`；`cfg_lower_program.zig:48`、
  `:84`。
- **建议工作**：把可失败分配改为传播 `error.OutOfMemory`；`.alias` 分支若不是真正
  不可达，改为具名诊断或明确断言其不变量并加注释。
- **验证方式**：白盒构造触发路径，或代码审查确认不可达并加注释；
  `zig build -fincremental test -Dtest-filter=frontend_cfg_passes`。
- **关联**：无

### B9 后端不发射 `auipc` / `lui`

- **优先级**：P3
- **问题**：`auipc` / `lui` 是 LLIR ISA 的规范 opcode，VM 已实现其语义
  （`interpreter_dispatch.zig` 的 `hAuipc` / `hLui`），但没有任何 lowering /
  fusion / peephole 发射它们：唯一的 U 型发射点是 `jal`。LLIR 没有计算地址的
  load/store，`auipc` 的 pc 相对寻址也无消费者，因此当前没有源构造需要二者，
  它们只出现在手工构造的测试图像中。
- **证据**：`cfg_lower_llir_emit.zig:514`（`setU` 的唯一调用只发 `.jal`）；
  `llir.zig:1190-1253`（CFG→LLIR 映射无 U 型项）；`llir_fusion.zig:485`、`:513`
  （只匹配 C 型）；VM `interpreter_dispatch.zig:1121-1122`；
  `probes/README.md:242-246`；规范 `Stilla LLIR Instruction Set.md:1470-1481`。
- **建议工作**：评估是否需要一条发射路径（例如 pc 相对常量或大立即数物化的新
  构造）；若需要则设计并实现 lowering 与消费方，若确认无消费者则明确记录二者为
  「有意不发射」，或考虑从 ISA 移除（属规范决策）。两种方向都需在文档中固定定位。
- **验证方式**：未实现时以「无发射方」检查为准——`grep -rn "\.auipc\|\.lui"
  src/passes` 不应出现发射点，并核对文档；若实现，则新增触发该构造的
  `probes/*.st`，断言 AIR 出现 `auipc` / `lui` 且运行输出不变。
- **关联**：无

---

## 测试与验证

### T1 无「无优化模式」运行时差分

- **优先级**：P1
- **问题**：pass smoke 测试只跑 optimizer + drop lowering + LLIR 校验 / 汇编 /
  二进制，不执行程序；唯一的运行时 differential 是 HIR 的 simplify × seg 四组合。
  没有任何测试比较「无优化 vs 有优化」的运行时输出。
- **证据**：`frontend_pass_smoke_tests.zig:155-194`（不执行）；
  `hir_seg_tests.zig:1805-1854`（四组合、执行）；
  `hir_simplify_tests.zig:345-510`。
- **建议工作**：新增端到端 differential——对 `probes/` + `examples/` 语料以 `cfg=off`
  与 `cfg=on`（可再加 LLIR peephole）各编译执行一次，逐字节比较输出 / 终止 / panic
  信息。
- **验证方式**：新增测试并断言至少一个程序两侧 AIR 不同（非空跑）；
  `zig build -fincremental test -Dtest-filter=frontend_pass_smoke`。
- **关联**：roadmap.md「End-to-end and differential test hardening」

### T2 stsmith sweep 偏弱

- **优先级**：P1
- **问题**：sweep 的子进程没有超时；只用默认 `--run` 模式；失败仅保留程序、不保留
  stderr 与精确复现命令；CI 只跑一次。
- **证据**：`tools/stsmith/sweep.py:26-28`（无 timeout）、`:72`、`:75-86`；
  `.github/workflows/ci.yml:19-23`。
- **建议工作**：为子进程加超时；增加优化 on/off（以及 `--emit-bin` 后再 `--run`）
  差分；失败时保留程序、生成器 stderr 与可复制命令；CI 至少跑两种配置。
- **验证方式**：对已知失败 / 超时 seed 断言 sweep 给出超时分类与复现命令；本地
  `python3 tools/stsmith/sweep.py --seed 0-9`；CI 通过。
- **关联**：roadmap.md「End-to-end and differential test hardening」

### T3 其他端到端覆盖缺口

- **优先级**：P2
- **问题**：缺 cfg on/off 端到端 differential（T1 的推论）；`--opt-list` 的可执行 /
  库两种默认 profile 无测试。
- **证据**：`main.zig:915-927`（opt-list 单 profile）；T1。
- **建议工作**：随 T1 一起加 cfg differential。
- **验证方式**：`zig build -fincremental test -Dtest-filter=parseArgs` 与
  `-Dtest-filter=frontend_pass_smoke`。
- **关联**：无
