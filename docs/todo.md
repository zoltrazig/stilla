# Stilla frontend TODO — HIR 与 effect 模型

本文件是 HIR / effect 模型未落地工作的**唯一清单**，由
[hir.md](hir.md) 与 [effects.md](effects.md) 的现状章节统一引用。
「近期」内各项的先后是**建议顺序**，不是串行依赖；每项单独列出前置
依赖。设计细节仍在两篇文档正文，本文件只记范围、依赖与验收。
已完成的历史条目按原编号归档于「已完成」节，供跨文档交叉引用；
「近期」从第 22 项续起，新增项一律追加到队尾。

## 近期（建议顺序）

- [ ] **22. Cost model 与 Extraction**（hir.md 的 cost model / extraction 条目）
  - 现状：**extraction 已落地但只有单一 cost**。第 21 项实现了
    `hir_egraph.zig` 的 `extract`：每个 e-class 跟一个 preferred e-node
    （`preferred_prio` 0 = encode 原貌、1 = 规则选中的项，同类多个提案按最低
    e-node 索引定序），这就是全部 cost——没有 per-opcode 权重、没有候选间最小
    cost 求解。白盒测试已固定 extraction 的往返契约（identity 写回零新节点 /
    重定向后深拷贝 / 共享类 materialize 成 `let` / fresh `BinderId`）。
  - 范围：把「优先级 + 最低索引」升级为 **per-opcode cost model**——cost 是
    优化器事实、**不进 op descriptor**（hir.md 已定），按 op 类给权重（构造 /
    投影 / 调用 / 字面量……），缺省回退到节点计数；extraction 自底向上取最小
    cost 项，确定性 tie-break（优先规则顺序 → 稳定的 op / operand 序）。
    extraction 回 HIR 的契约（fresh `BinderId`、island 外原 binder 不得混淆、
    共享子项 materialize 成显式 `let`）已由第 21 项实现，本项只需把它从
    preferred 选择解耦为 cost 求解；抽取完成后按现状重跑结构 + 效果重校验。
  - 依赖：**第 21 项**（已落地：e-graph 与 `extract` 骨架）。
  - 验收：白盒 cost model（权重、tie-break 稳定性、缺省回退）与 extraction
    正例（两候选取低 cost、共享子项 materialize 成 `let`、fresh binder）；
    全语料 SEG-on / SEG-off 差分逐字不变；`Stats` 报告抽取选中项的总 cost
    （见第 23 项）。

- [ ] **23. 覆盖 e-graph 的 SEG 统计与预算**（`hir_seg.zig` 的
      `Stats`；`hir_seg_tests.zig` 的 `SEG budget`）
  - 现状：第 21 项已落 arena 一半——`hir_egraph.Stats`（`rounds` / `converged`
    / `eclasses` / `enodes` / `merges` / `unions` / 按规则计数 / `materialized`
    / `copied` / `written`）与 `hir_seg.Stats.egraph_*`，`SEG budget` 同步汇总
    e-graph 维度并断言 `egraph_converged`，基线已重录进 hir.md 的「验收与
    落地现状」。**尚缺**：`Stats` 各字段的 doc 注释（`hir_seg.zig` 侧只标了
    `egraph_*` 的聚合语义）、按规则的匹配 / 应用计数（现在只有应用后成功的
    计数）、以及 extraction 选中的总 cost（依赖第 22 项）。
  - 范围：补齐上述三项；v1 计数保留（读旧字段的测试随命名迁移）。
  - 依赖：第 21 项（已落地）；cost 部分依赖第 22 项。
  - 验收：`SEG budget` 对全语料断言 e-graph 引擎也在轮界内收敛且计数非零
    （非空跑）；`Stats` 各字段语义在 `hir_seg.zig` 的 doc 注释说明；新基线
    记入 hir.md。

## 已完成（归档，原「近期」第 1–21 项）

> 以下条目均已落地，按完成时的编号保留，供 [effects.md](effects.md) 等正文
> 交叉引用；新工作从「近期」第 22 项续起。

- [x] **21. Slotted E-Graph 本体**（hir.md §8.1–§8.2；`hir_egraph.zig`）
  - 范围：新增一个 pass 承载 SEG arena：e-class 表 + union-find、SLOT 编号、
    递归 `encode`、saturation 主循环（把 union 规则从逐节点原位改写改为
    e-graph 规则），β / η / `let` 三族与 known-variant `match` 保持编码边界
    之外的 boundary rewrite。
  - 已完成：新增 `hir_egraph.zig`（e-class 表 + union-find、`BinderId → Slot`
    编号、`encode` / `saturate` / `rebuild` / `extract`）并把常折叠、整数代数、
    常量条件与聚合投影四条 union 规则搬进 arena；`hir_seg.zig` 保留 island
    准入（`computeIslands` / `markIslandRoots`）、β / η / `let` 折叠与
    known-variant `match`，新增 `saturateIsland`（每 island 一个 scratch
    arena，聚合 arena `Stats`，把写回站点记 dirty）并在每个 island 根上先于
    局部走查调用；α-相等 / CSE sharing 由 hash-consing + `rebuild` 同余合并
    自然涌现，extraction 的 materialize 准入与旧 `ruleCse` 一致（`strict_ltr`
    无 region 父节点 + `isDuplicable` + 非 trivial atom）。`Stats` 新增
    `egraph_islands` / `egraph_rounds` / `egraph_converged` / `egraph_merges`
    / `egraph_unions` / `egraph_copies`，`SEG budget` 一并汇总并在 hir.md §11
    重录基线；arena 的 `Stats` 落在 `hir_egraph.zig`（§8.2 正文）。
  - 验收：白盒——`hir_egraph.zig` 的 e-class 合并 / α-CSE、SLOT 重用与
    free-binder 身份（island 外 binder 经 slot 表原样写回）、递归编码边界拒绝
    （未注册 `.seg` 的 op、非 `isSegSafe` 子树、越界下标与非构造基）、
    extraction 的 identity（零写回）与重定向 / materialize，以及从 `hir_seg`
    迁入的折叠 / 代数单测；黑盒——`hir_seg_tests.zig` 断言 `probes/egraph.st`
    的 arena 计数非零（islands / rounds / merges / unions / copies / shares，
    且 `egraph_converged`）与其投影规则在 AIR 中可见（`--seg` 开时
    `read_field` 消失）；全语料四组合（`--simplify` × `--seg`）解释器差分
    逐字不变（`probes/egraph.st` 自动进入语料）。`zig build -fincremental test`
    全绿（1208/1208）；SEG budget 基线随新探针更新（60 程序 / 4732 节点 /
    2558 islands / 91 轮 / 109 次重写 / 2061 arena 轮 / 41 union / 322 merge /
    82 copy / ≈112 ms，断言两层收敛）。

- [x] **20. `effects.dropEffect` 的处置**（[effects.md](effects.md) §11.1）
  - 现状：`effects.dropEffect` 是 M1b 的极简版（Copy → `{}`，其余 / null →
    `Top`），只有定义 + 单测、无生产消费者；生产路径是 `hir_effects.dropEffectOf`
    的精确全链。它是 `pub` 且经 `root.zig` 导出。
  - 已完成：**删除**。功能已被 `hir_effects.dropEffectOf` 的精确全链完全替代，
    无生产消费者，留着只是失效 API。删除 `effects.zig` 的 `dropEffect` 函数、
    其单测与随之失去唯一用者的 `meta.zig` 导入；`root.zig` 导出的是整个 `effects`
    模块，无直接引用需改（全仓确认无其它调用点）。`docs/effects.md` §11.1 删去
    遗留行、正文标为唯一路径；doc 注释随之移除。
  - 验收：`zig build -fincremental test` 通过（保留基线噪音外的全绿）。

- [x] **19. tuple / list 的 SEG 编码与投影规则**（[hir.md](hir.md) §8.3；
      `src/hir.zig` 的 `seg == null` 断言）
  - 范围：`tuple_make` / `list_make` 补 `construct` 编码，投影走已有的 `field_get`
    `project` 编码，并加已知下标归约规则。
  - 已完成：`tuple_make` / `list_make` 的 descriptor 补 `seg = .construct`，
    `hir.zig` 的 M2a 注册测试把二者从「硬 island 边界」移入编码集（各断言
    `.construct`）。`hir_seg.projectStruct` 泛化为 `projectAggregate`：
    `field_get(C(v0, …, vn), i) → vi`，`C` = `struct_make` / `tuple_make` /
    `list_make`，`idx >= operands.len` 即拒绝。list 的越界证明落在效果模型：
    `hir_effects.fieldGetOwn` 对 `.list` 基细化——只有基是 `list_make` 且
    payload 下标小于其 operand 数才判 `pure`（源级 list 基 `field_get` 否则
    保守 `Top`），该节点因此能过 island 门与投影规则汇合（无需旁路规则）。
    **tuple / list 投影是 IR 级规则**：Stilla 没有元素读取后缀，元素只经解构
    pattern（lowering 用 `read_tuple` / `read_index`）读取，源码不产生 tuple /
    list 的 `field_get`，故两者由白盒规则测试覆盖。耦合收益落地：两个字面量
    并入 CSE 可用子项集。
  - 验收：白盒——`hir_seg.zig` 的聚合投影测试遍历 struct / tuple / list 三种构造
    的每个下标、越界与非构造基拒绝，另有「tuple projection fires end to end
    through island admission」——以 HIR 文本形式构造 tuple `field_get`，经
    `optimize` 证明 island 准入（`encOf`）后确实折叠为常量，而非只测独立规则
    函数；`hir_effects.zig` 新增 `fieldGetOwn` list 基测试（界内 `pure`、越界 /
    非构造基 `Top`）。黑盒——新探针 `probes/tuple_list_encoding.st`（tuple / list
    字面量内两个 α-相等 `mul` 经 CSE 合成一个 `let`，非 α-相等对保持分离）进四
    组合解释器差分、pass smoke 与 SEG budget，`hir_seg_tests.zig` 断言两处
    sharing 与合成 `let` 形状。`zig build test` 全绿（1241/1241）；SEG budget
    基线随语料更新（59 程序 / 4618 节点 / 2485 islands / 89 轮 / 99 次重写 /
    ≈99 ms，仍断言收敛）。

- [x] **18. rewrite 契约形式化的第二批（η / `tryAnf`）**
      （[effects.md](effects.md) §10.3、[hir.md](hir.md) §8.1 / §8.5）
  - 范围：把 η 与 `tryAnf` 的准入声明为 `RewriteRule` 实例、经 `check` /
    `checkCleanup` 消费，行为逐字不变（与第 13 项同为提取，不改语义）。
  - 依赖：**第 13 项**（已落地）。
  - 已完成：`rewrite_contract.zig` 的 `Requirement` 新增 `materializable`
    （主体 `Subjects.hoist = {parent, slot}`，与 `swap_operands` 的复合主体同一
    形态），`check` 分支调用新派生查询
    `hir_effects.canMaterializeOperand(parent, slot)`——把 selective ANF 的两条
    ownership/lifetime 义务（其前 operand 可推迟，`Class.seq` 时更要求 Copy；
    被提 operand 的析构点不动：Copy，或父节点已 `Consume` / 就地处弃它）从
    `hir_simplify` 的内联助手（`deferrableOperands` / `uniqueDestructionCoincides`）
    提取为该查询（行为逐字：seq 分支先查其前 operand 的 capability，再查被提
    operand 的 capability / `Consume` / seq 非末位）。`hir_seg.zig` 新增
    `eta_rule`（`.shape`，`EvaluationCountPreserved`，`PreservesEvaluationCount`，
    无 cleanup 义务），`tryEta` 在 `fn_ref` op 检查后由 `check` 消费；
    `hir_simplify.zig` 新增 `anf_rule`（`.shape`，
    `{EvaluationCountPreserved, Materializable}`，
    `PreservesEvaluationCount + MayReorder`，无 `maps_full_expr` / cleanup kind
    ——合成 `let` 沿用父节点 FE、不跨边界），`tryAnf` 选中首个不可浮动 operand
    后由 `check` 消费。匹配层保持结构性 applicability（η 的 `fn_ref` opcode /
    λ 形状 / 链界 / 类型相等 / 全性；ANF 的 `strict_ltr` policy 与首个不可浮动
    operand）。既有 η 白盒正负例、ANF 白盒正负例、全语料 `--simplify` × `--seg`
    on/off 解释器差分与 SEG budget 基线（58 程序 / 4551 节点 / 2404 islands /
    86 轮 / 94 次重写）均未变。
  - 验收：`hir_simplify_tests.zig` 的「legality engine agrees with the derived
    queries」补 `.materializable` 分支与 `canMaterializeOperand` 对账（正例、
    越界 / 缺主体失败关闭），新增「the materializable requirement routes through
    `canMaterializeOperand`」——同一父形状下 `Consume` 的 Unique 实参可物化、
    `borrow` 的实参被拒，`check` 与派生查询逐项一致。`zig build test` 全绿
    （1238/1238）。effects.md §10.1 / §10.3–§10.4 / §12.1 与 hir.md §5.7 /
    §8.1 / §8.5 同步改写。

- [x] **17. scope-end 清理建模**（[effects.md](effects.md) §11.2）
  - 范围：独立的 scope-end 销毁累加与排序模型——把 scope-end 绑定的销毁点、创建
    序与 FE 内临时量的销毁计划统一到同一套注册 / 排序，使 `cleanupEffect` 能表达
    「外层 FE 末尾的 scope-end 析构」。放开后 selective ANF 的 Unique region 绑定
    与源级 Unique `let` 不再落入保守 `Top`。
  - 依赖：无（第 3 / 7 项已落地）。
  - 已完成：`hir.CleanupToken` 增加 `kind: full_expression | scope_end`（后者携带
    region + binder）；builder 的清理登记步骤（`hir_build_cleanup.zig`）对每个
    region 的非借用 Unique 参数登记 `scope_end` token——锚在 **region root** 上、
    归属外层 FE、与 FE 临时量共用同一张表与同一 `registration_index` 计数器。锚取
    region root 而非 init：init 自成内层 FE，其类型匹配也无法满足「origin 节点
    FE == token FE」，而 root 同时满足边界与「类型经 binder 携带」两项约束。
    `cleanupEffect` 删除 `regionOwnsUnique` 的 null 分支，两类 token 统一按
    「origin ∈ 求值子树」折叠；`lambdaBodySummary` 改为 `effectOf(body) ;
    cleanupEffect(body)`——owned Unique 参数的 normal-exit 析构、体局部量与体 FE
    临时量都进函数摘要，不再对含 Unique 参数 / 局部的函数一律 `Top`。`cleanupFree`
    保持字面（`regionOwnsUnique` 仍在其中），供 β / speculatability / reorder 使用。
    路径敏感状态（Consumed / Escaped）仍属 CFG 侧：被 move / 转入调用的绑定其
    token 保守登记为 may-drop。**构建期之后的合成绑定不登记**——selective ANF 的
    Unique `let` 其契约已证明「父节点转移或序列中就地处弃」、β 克隆体
    `isSegSafe(body)` 保证 cleanup-free、CSE 共享 init 是 `isDuplicable` 的 Copy 值——
    由 `ruleMatch` 拼接的 `let` 复用 arm 的构建期 binding 与 token，故树内这些绑定
    不产生未建模析构。`remapCleanupOrigin` 只 remap `full_expression` token（scope
    token 的锚是 region root、身份是 binder，绑定不变）；dead-let（hir_simplify /
    hir_seg 两处）经 `Program.retireScopeTokens` 退役被删绑定的 token。校验器对
    `scope_end` token 检查「锚 == region root ∧ 锚 FE == token FE ∧ ty == binder
    ty ∧ binder ∈ region params」。
  - 验收：`hir_effects` 白盒——正例「scope-end Unique 绑定进 `observed_effect`」
    （观察 `hostmod.log` 可观察析构的 binding 使 `cleanupEffect` / `observedEffect`
    携带 destructor，不再 null → `Top`）与「纯读析构的 footprint 可丢弃」（
    `cleanupDiscardable(let)` 由 false 转 true）、「owned Unique 参数函数摘要精确」
    （纯析构 = `pure`、可观察析构 = total 且非 effect-free，均不再是 `Top`）、校验器
    对 mis-anchored scope token 的拒绝；`hir_simplify` 白盒——ANF 合成绑定无
    `scope_end` token；`hir_simplify` 迁移原保守断言至新语义：unused Unique 绑定 + 纯
    析构可删（`simplify_unique_dead_pure`，原名
    `simplify_unique_drop_hook_kept` 改义），`simplify_anf_unique_transfer` 改用
    可观察 effect 的 `make` 保持「转移绑定不产生析构」的触发前提。新增
    `probes/scope_end_cleanup.st`（源级 Unique `let` 的 scope-end 析构、owned 参数
    normal-exit 析构、被弃 Unique 语句物化后仍在语句处析构；全部印出）进全语料
    `--simplify` × `--seg` 四组合解释器差分、pass smoke 与 SEG budget；实测 CLI 四
    组合输出逐字相等（`1\n1\n2\n2\n3\n4\n4\n`）。`zig build test` 全绿
    （1234/1234）。effects.md §11.2 / hir.md §5.6–§5.7 同步改写，SEG budget 基线随
    语料更新（58 程序 / 4551 节点 / 2404 islands / 86 轮 / 94 次重写 / ≈93 ms，仍
    断言收敛）。

- [x] **16. HIR canonical 文本的 round-trip 闭合**（[hir.md](hir.md) §4.4 / §4.5 / §4.10）
  - 现状：文本形态已知缺口（均已实测复现）——(a) `hir_print.printType` 会打印
    `box(T)`，但 `hir_parse.parseType` 没有 `box` 分支；(b) `struct_make` /
    `field_get` / `variant_make` 无成员身份的文本形态，printer 直接报
    `NotSerializable`；(c) 解构 `let`（`Region.pattern != null`）的 printer 只打印
    `params[0]`、忽略 pattern，**静默损坏**；(d) 值位置模块链叶（`access_hops`
    非空）报 `NotSerializable`（刻意）；(e) 带 region 且无命名形状的 op 报
    `NotSerializable`（设计预留）。
  - 已完成：为三个 aggregate op 定义成员身份文本形态——`struct_make(e, …) : ty`、
    `field_get[member](e) : ty`（struct 字段名或 tuple 下标，由基类型解析）、
    `variant_make[Variant](e, …) : ty`；printer 与 parser 双向实现，成员不存在 /
    数目不符即报错（绝不静默降级）。结果类型始终显式，故 `ExprNode.ty` 逐字
    保留。解构 `let` 按 §4.3 打印 pattern（`let <pattern> = <init> in <body>`），
    parser 先解析 init 得其 scrutinee 类型、再回头解析 pattern（init 排除；
    pattern 无 binder 类型标注）；`printPattern` 补上 struct 名、list rest 取
    list 类型而非元素类型。补 `parseType` 的 `box(T)` 分支与函数类型的参数模式
    （`move` / `borrow`）。一并修正语料 round-trip 暴露的既有不对称：
    `parseNumeric` 裸 pattern 字面量的早退、整数声宽范围校验（builder 可在窄
    类型下保留超范围 bits）、浮点字面量只在刚发射的字面量里找 `.`、泛型 host
    实例化的 `fnref : ty`（节点类型≠ SerCtx 声明类型时才写）、lambda 仅当声明
    返回 ≠ body 类型时补 `-> ret`、`call` / 空 operand 列表的 `)` 与多实参
    comma 循环、typed 比较行的结果类型（`bool` 而非 operand rep）、`and`/`or`/
    `if` 的 `unifyJoin` 结果类型、`#refs` 键的数字段（`list.index_of_from.11`）、
    opaque 泛型的 arity、`drop` 结果类型、引用字典去重。顺带修正 IIFE 调用的
    结果类型（callee 为 lambda 表达式时 callee_ty 缺失回退到 `void`；改从建好的
    callee 节点取类型），使 `and %c then call(never) else false` 等 shape 的
    node 类型 round-trip 一致。§4.6 派生标注仍为设计预留（无消费者，未做）。
  - 依赖：无。
  - 验收：新增 `hir_tests.corpusRoundTrip`——`probes/` + `examples/` 每个 built
    函数根逐个 `print`→`parseText`→`hir_validate`→`alphaEq`→canonical reprint，
    全部通过；白盒新增 aggregate 成员身份 / box / 解构 let / 函数类型模式 /
    多实参 call / 裸 pattern 字面量 / 宽无符号 / 实例引用键的 round-trip 正例与
    aggregate 成员校验负例。CLI `--emit-hir` 覆盖完整 `probes/` + `examples/`
    语料（实测 0 失败），`build.zig` 的失败探针改指仍不可序列化的模块链叶
    （`probes/cases/intrinsic_load_member_compacted_index.st`），`main.zig` 的
    render 测试改为「aggregate 可打印」+「模块链叶失败并具名」。`zig build test`
    全绿（1230/1230）。[hir.md](hir.md) §4.3–§4.5 / §4.10 同步更新并删除旧缺口
    说明。

- [x] **15. 跨 FE 的 let 折叠（契约准入）**（[hir.md](hir.md) §8.3 / §8.7）
  - 范围：按 β 的 boundary-rewrite 契约模式（而非 island 成员资格）为
    `ruleLet` 的 FE 安全子集增加准入：dead-let 要求 init `isDiscardable`；
    used-once forwarding 要求 init 的 island 成员资格（Copy、cleanup-free）；
    trivial-atom forwarding 要求原子 init `isDuplicable`（补上 borrowed-view
    原子的准入证明）；合成结果不得跨 FE 移动清理。
  - 依赖：**第 7 项**（已落地）。
  - 已完成：`hir_seg.zig` 新增三条规则声明——`let_dead_rule`（legality
    `.discardable`，`preserves_cleanup = binder_destruction`）、
    `let_forward_rule`（`EvaluationCountPreserved` + `may_reorder`、
    `maps_full_expr`、`cleanup_free_subtree`）、`let_atom_rule`
    （`.duplicable` + `maps_full_expr`）——由 `ruleLet` 三分支经
    `rewrite_contract.check` / `checkCleanup` 消费；pass 驱动层让**非 island**
    节点也尝试 `ruleLet`（`applyRules` 的 boundary 分支），其余普通规则仍受
    island 门约束。dead 分支改用 `isDiscardable(init)`（一个查询覆盖 trap /
    效果 / `discard_view(observed_effect)` 折叠的 init 全表达式清理面）+
    `binder_destruction`；used-once 分支保留 `encOf(init)`（Copy、单一 FE、
    cleanup-free、过 ownership gate）并新增「本轮未被改写」守卫——改写过的节点
    其 island 判定描述的是死形状，折叠延后到下一轮，§8.7 的例子因此晚一轮闭合；
    atom 分支新增 `isDuplicable`（借用的 view 过不了 ownership gate，`Q` 过不了
    no-`Q` 子句）。forwarding 搬移的 init 子树按 `maps_full_expr` 重盖使用点的
    FE（`restampFe`；island 资格已证明整棵子树单一 FE），atom 复制的每一处按
    使用点盖 FE；三处折叠都把 region root 的清理 token 重映射到存活节点
    （`remapCleanupOrigin(body, id)`）。匹配层另外拒两种形状：binder 被
    `move` / `drop` 当 operand 读（它们从 operand 节点自身的 binder payload
    下降，只有 `local` init 可搬入该槽）与 binder 类型 ≠ init 节点类型
    （`let b: any = %value` 的隐式强制转换，替换会抹掉它）。
  - 验收：`hir_seg_tests.zig` 新增「source-level let folds across the
    full-expression boundary」——改写前先用 `analysisOf` 断言每个 init 的派生
    查询结论（dead 的 `isDiscardable`、forward 的 `isSegSafe` + `cleanupFree`、
    atom 的 `isDuplicable`，以及 borrow / Unique / trap / effectful 四个负例与
    coercion 的 `init.ty != binder.ty`）且三个正例的 init FE ≠ `let` FE；
    `probes/seg.st` 的 `unused_let`（dead）→ `%B0`、`forward_once`（forward）→
    `mul.i32(add.i32(%B0, 1i32), 2i32)`、`atom_twice` → `add.i32(%B0, %B0)`
    三个正例逐字文本，加 `borrowed_kept` / `trapping_kept` / `observable_kept` /
    `coerced_kept` / `unique_kept` 五个负例（`let` 保留）；改后断言
    `maps_full_expr`（forward 的整棵被搬移子树与目标 FE 一致、atom 两处副本是
    不同节点且同 FE）。`probes/seg.st` 扩为可运行差分语料（每个形状都
    `print`，`--simplify` × `--seg` 四组合解释器输出逐字相等）。§8.7 的例子
    现在真的折叠，`seg.st` 的 `unused_let` 不再固定边界。`SEG budget` 基线随
    语料与轮数更新（57 程序 / 4491 节点 / 2395 islands / 85 轮 / 94 次重写 /
    ≈86 ms，仍断言收敛），`zig build test` 全绿。

- [x] **14. `never_returns` must 事实与后缀删除**（[effects.md](effects.md) §10.1、
      §12.4；hir_effects.zig / hir_simplify.zig / hir_lower_expr.zig）
  - 范围：推导 `never_returns`（取不到即 false，递归 SCC 用 greatest-fixpoint
    语义）；调用点后同一直线区域的后缀不可达，可整段删除（含该区域的 FE 清理）。
  - 已完成：`hir_effects.Analysis` 新增 must 事实 `never_returns[]` + 结构谓词
    `exprNever` 与查询 `neverReturns`。后者是调用图上从「全 true」出发、每轮
    Jacobi 同时更新、单调下降的 **greatest fixpoint**（coinductive：
    `fn f() -> void { f() }` 真的不返回，least fixpoint 会漏掉），至多
    `#funcs + 1` 轮收敛；惰性求值（首次 `neverReturns` / `exprNever` 触发）。
    `exprNever` 是迭代后序（显式栈，无递归）的 must 谓词：`ty == never`、
    `call` 的可解析目标集全为 never（inline λ 用其体、host 用签名 ret）、
    `if`/`and`/`or`/`match` 的头或全臂、其余 strict op 的任一 operand/region
    都判；未证明一律 false。memo 按轮清空，越界（本轮新 append 的节点）视为
    false。`hir_simplify.zig` 新增第三条消费者 `neverSuffix`（先于 dead-let /
    ANF 运行）：`seq` 在首个 never-normalizing operand 处截断，`let` 的 init
    never 时用 init 内容替换整节点（body 死），并把这些节点与「类型特化为
    `never`」的节点的清理 token 退役（`Retire` 集合，轮末统一置 `no_expr`）——
    被删节点不可达，`cleanupEffect` 本就不计入，退役是 token 表卫生 +
    `cleanupOriginsReachable` 不变量。`Stats.suffix_deletions` 计数。
    `hir_lower_expr.expr` 新增结构规则：任何 `ty == never` 的节点求值后终止块并
    发射 `trap`（置于 `dropCreatedRange` 之前）；对既有 never 节点是 no-op
    （直接 call 走 `emitCall` 的 ret、value/host 走签名 ret、`panic` / 全臂
    `if` 直接 trap），故无 golden churn。
  - 依赖：**第 7 项**（已落地：删后缀时的 FE 清理归属依赖节点级 FE 标注）。
  - 验收：`hir_effects.zig` 白盒（签名 / 结构 never、正常返回路径、recursive
    SCC greatest-fixpoint 真 / 假、`let`-init / 全臂分支 / 未解析 callee 的
    `exprNever`）；`hir_simplify.zig` 白盒正例（`seq` 后缀删除、`let` init 删除）
    与负例（正常返回 callee 不删）；`hir_simplify_tests.zig` 断言 pre-optimizer
    AIR on/off 不同并各自 round-trip；新增 `probes/never_suffix.st`（`void` 的
    structural-never callee、let-init 情形、正常返回 callee 保留；注册进
    `probe_corpus.panics`）进全语料 `--simplify` on/off 解释器差分与 pass smoke。
    SEG budget 基线随语料更新（57 程序 / 4372 节点 / 2360 islands / 70 轮 /
    ≈71 ms，仍断言收敛）。

- [x] **13. rewrite 契约形式化**（[effects.md](effects.md) §10.3–§10.4）
  - 范围：把 §10.3 的 applicability / legality 两层与 §10.4 的 `RewriteContract`
    落为类型：`RewriteRule { match, build, applicability, legality: [Requirement] }`、
    `Requirement = Discardable | Duplicable | SwapOperands |
    EvaluationCountPreserved`、`RewriteContract { effect, maps_scope,
    maps_full_expr, preserves_cleanup }`；先用 β 与 hir_simplify 的 dead-let 做
    首批实例，行为逐字不变。
  - 已完成：新增 `passes/rewrite_contract.zig`，落地的形状：
    `RewriteRule { name, applicability, legality: [Requirement], contract }`、
    `Requirement = discardable | duplicable | swap_operands |
    evaluation_count_preserved`、`Applicability = typed_opcode | shape`、
    `RewriteContract { effect: Effect（bool 集合）, maps_scope, maps_full_expr,
    preserves_cleanup: ?CleanupProofKind }`。通用 legality 引擎
    `check(analysis, rule.legality, subjects)` 唯一的 `switch` 在**声明的要求标签**
    上，每个分支只调用派生查询（`isDiscardable` / `isDuplicable` /
    `canSwapOperands`）——**没有 `switch(op)`**；
    `evaluation_count_preserved` 是规则自证的结构义务（β→let 逐参数嵌套、LTR），
    引擎接受声明。`CleanupProof`（`cleanup_free_subtree: ExprId` /
    `binder_destruction: Type`）+ `checkCleanup(rule, analysis, subject)`：契约声明
    kind，调用点给实例，kind 不符即失败关闭；`checkCleanupProof` 仍只用派生查询
    （`cleanupFree` / `ownershipGate`；`capabilityOf` + `bindingCleanupDiscardable`）。
    首批实例：`hir_seg.beta_rule`（`.shape`，`PreservesEvaluationCount +
    PreservesOrder`，`maps_scope` / `maps_full_expr`，
    `preserves_cleanup = cleanup_free_subtree`）被 `tryBeta` 消费；
    `hir_simplify.dead_let_rule`（`.shape`，legality `{.discardable}`，
    `MayDiscard` + `preserves_cleanup = binder_destruction`）被 `tryDeadLet`
    消费。行为逐字不变：`cleanupFree` / `ownershipGate` 的合取、`isDiscardable`、
    `capabilityOf orelse .unique` + `bindingCleanupDiscardable` 的检查顺序与
    短路均保持；`tryBeta` 显式保留 call 结果与每个实参的 Copy 复查（ownership
    gate 对 λ 节点短路，不能单独承担）。与 sketch 的差异已在 §10.3–§10.4 声明：
    `legality` 是标签列表（静态声明不能携带 `ExprId`，主体由调用点给实例）、
    `match` / `build` 仍是 pass 内规则函数（由 `Rule.name` 指名，不做函数指针表
    驱动）、`effect` 是 bool 集合。η / `ruleLet` / `tryAnf` 仍内联，属后续批次。
    测试：`hir_simplify_tests.zig` 新增「legality engine agrees with the derived
    queries」——四个 requirement 分支逐个与 `isDiscardable` / `isDuplicable` /
    `canSwapOperands` 对账（trap 负例、纯 call / 纯 `add.i32` 正例、缺 swap 主体
    失败关闭），并断言 kind 不符的 `checkCleanup` 拒绝；β / dead-let 的既有
    白盒正负例与全语料 on/off 差分在形式化实现下全部通过（`zig build test`
    1216/1216）。effects.md §10.3–§10.4 的「无统一接口类型」/「契约是设计概念」
    段落改写为落地形态与实现差异；hir.md §8.1 / §8.4 同步。
  - 依赖：无（是现有内联判定的提取，不是新语义）。

- [x] **12. SEG 编译时间预算与默认开启**（应用面；[hir.md](hir.md) §11、
      frontend.zig / main.zig）
  - 范围：以 `Stats` 与 `probes/` + `examples/` 全语料为输入，度量 SEG 编译时间、
    轮数与 island 覆盖并形成预算；据此把 SEG 从 `--seg` 翻为默认开启（保留 opt-out）。
  - 已完成：`hir_seg_tests.zig` 新增 `SEG budget` 测试——逐语料文件 `buildText`
    - `hir_seg.optimize`，断言每个程序都在 `Config.max_iterations` 界内收敛
    （`Stats.converged == true`，CI 稳定 oracle），并汇总时间 / 轮数 / island
    覆盖；实测基线（2026-09-13、macOS/arm64，记录于 hir.md §11）：56 个程序 /
    4306 个可达节点，2347 个 island 成员（≈54%），69 轮、51 次重写，总时间
    ≈70 ms，单文件最慢 `examples/fold`（10 ms / 2 轮）。据此 `stilla` 可执行文件
    默认开启 SEG：`main.zig` 的 `Options.seg` 默认 true，新增 `--no-seg` 保留
    opt-out，`--seg` 仍为显式开启；库 `frontend.Options.seg` 保持默认关（与
    `optimize` 同一约定，避免对约 70 处测试 compile 站点产生 golden churn），
    其文档注释改写为「可执行文件默认开、嵌入者显式设置」。全语料 `--simplify` ×
    `--seg` 四种组合的解释器输出逐字相等由 `corpusDiff` 覆盖：按 AIR 去重（AIR
    逐字相同即同一程序，仅对确有改写的组合重跑比对），并对每种组合的 canonical
    AIR 做 standalone parser round-trip；probes 测试断言 simplify-only 与 seg-only
    两个组合都至少改写了一个程序，避免空跑。CI 实测 `zig build test` 由基线
    ≈108 s 降至 ≈92 s（去重后的运行次数少于旧的 SEG-on/off 两次执行，未回归）。
  - 依赖：**第 11 项**（已落地：有界轮数契约）。

- [x] **11. SEG 终止性：有界轮数契约**（[hir.md](hir.md) §8.2、hir_seg.zig）
  - 范围：为 v1 规则集显式选定终止性契约——每轮严格递减的度量，或「有界轮数、
    非不动点」的显式契约。
  - 已完成：选定**有界轮数契约**，不引入递减度量。度量方案要对含 β 克隆、多
    payload `match`、CSE sharing 三处增节点规则在内的整个规则集构造一个全局严格
    递减的势函数，既不可行又有正确性风险；而有界轮数契约有直接的安全论证——
    每条准入重写都保语义，故任一「重导效果分析 → 原位重写」轮前缀仍是正确程序，
    撞轮界只是错过优化的上界，绝不是正确性上界。`hir_seg.optimize` 至多跑
    `Config.max_iterations`（默认 8）轮后停止；`Stats.converged` 新增，报告退出
    方式（安静轮 = 当前规则集的不动点；否则撞轮界）。hir.md §8.2 与该 pass 头注释
    改写为显式契约，并记各规则的消耗性守卫：`beta_done` 使 β 按 λ 记录有界、每个
    `match` 节点只被消费一次、CSE 绑定至少两处使用且 init 非平凡（`ruleLet` 无法
    撤销）、其余规则严格减小 `costOf`。测试：新增 `probes/cases/seg_multi_round`
    （常量 `if` 折叠把操作数原位改写，父节点 CSE 当轮因 dirty 拒绝，须下一轮才
    共享），断言 `iterations > 1`、`converged == true`、`shares == 1`，且第二遍
    `optimize` 零改写；既有 fixpoint 用例补 `converged` 断言。
  - 依赖：无。为「近期」第 12 项的编译时间预算提供上界依据。

- [x] **10. CSE-style sharing → 合成 `let`**（[hir.md](hir.md) §8.3）
  - 范围：同一 island 内结构相等（`alphaEq`）且 `isDuplicable` 的纯子树合并为
    一个 `let`，后续出现替换为对该绑定量的 `local` 引用；共享子项必须是 island
    成员（`encOf`），合成 `let` 不得改变求值次数与销毁注册。
  - 已完成：`hir_seg.ruleCse` 在 `strict_ltr`、无 region 的 island 节点
    （typed opcode / `call` / `seq` / aggregate maker）的 **operand 列表**里找
    第一对 α-相等（`alphaEq`：region param 按位置映射，未映射的自由 binder 按
    原始 id）的 operand，两者都满足 `encOf`、与父节点同 `full_expr`、非 trivial
    atom、`isDuplicable`（Copy + total + 无可观察效果 + operand 全 `Read` +
    无 `Q`），且本轮未被原位改写（`Rewriter.dirty`）。命中则合成
    `let B = ops[i] in <同一节点，所有 α-相等 operand 改成 fresh local B>`，
    donor 保持不可达。`strict_ltr` 保证每个 operand 恰好求值一次、LTR；候选是
    纯、total、确定性子项，故提前到 init 不改变任何可观察行为。合成 `let` 与
    候选共享父节点 FE，故不跨 FE（源级 `let`-init 对、`seq` 语句 operand 天然
    拒绝）；`isDuplicable` 强制 Copy 与整棵子树 `ownershipGate`，`CleanupToken`
    只为 owned Unique 临时量登记，故不改变销毁注册、donor 无 token 需重映射。
    `!isTrivialAtom` 是抗振荡门：const / local / fn_ref 不值得 binder，且
    `ruleLet` 的 trivial-atom forwarding 会立刻撤销；除此之外绑定至少两处使用
    且 init 非平凡，let 规则无法撤销。`alphaEq` 不比较 `access_hops`（携带它的
    op 都被 island / trivial-atom 门排除）。`Stats.shares` 计共享数。非 sibling
    共享（跨语句 / 分支，即 PRE）不在 v1，属 CFG 优化器；direct call 的 callee 是
    `fn_ref`（无 SEG 编码）故 `call` 不是 island 成员——v1 的共享子项限于纯算术 /
    聚合 island。测试：白盒正例（`mul` 对、`local` 计数、`cleanupOriginsReachable`
    无孤儿 token）、负例（`div` 非 total、跨 FE 的源级 `let`-init 对、Unique
    constructor、声明为 `Write` / `Q` 的 host read 均 `isDuplicable == false` 且
    `shares == 0`）、fixpoint（CSE 绑定稳定，二次运行零改写）、
    `probes/cse.st` 进全语料 on/off 解释器差分与 pass smoke。

- [x] **9. struct 投影规则**（[hir.md](hir.md) §8.3）
  - 范围：在 island 内把已知字段下标（`Payload.field`）的 `field_get` 归约为对应
    operand；下标越界 / base 非 `struct_make` 拒绝。
  - 已完成：`hir_seg.projectStruct`（自由函数；`applyRules` 在 `field_get` 且
    `encOf` 为真时调用）把 `field_get(struct_make(v0, …, vn), i)` 的节点内容替换为
    第 `i` 个 operand。`struct_make` 的 operand 按声明序、payload `field` 是声明
    字段下标（`hir_build_expr.fieldRead`），故直接取该下标即可。越界
    （`i >= operands.len`）与 base 非 `struct_make` 一律拒绝；乱序书写的构造被
    builder 的临时 `let` 链隔开（init 自成 FE，§5.6），字段读取看不到裸
    `struct_make`，本就不触发。result 是 island 成员的 operand，故拷贝内容不跨 FE、
    无清理 token。`Stats.projects` 计归约数。测试：白盒（各字段下标 + 越界 + 非构造
    基）、黑盒（`probes/struct_projection`：每个下标、非恒定 operand、binding base
    与非声明序的拒绝，加 out-of-range payload 与跨 FE 破坏的负例）、on/off 解释器
    差分与 pass smoke。tuple projection 未做（`tuple_make` / `list_make` 是硬边界，
    `seg == null`）。
  - 依赖：无。

- [x] **8. η-reduction**（[hir.md](hir.md) §8.5）
  - 范围：`fn (B0: T) => call(fnref F, %B0)` → `fnref F`。v1 只允许
    `callee = fn_ref`；前提是 exact same fn type（含参数模式）、`B0` 在 callee
    中不自由（不捕获天然满足）、callee total（无效果、无 trap）。结果 `fnref`
    无 SEG 编码，规则不得要求 `encOf(result)`（与 β 的 callee 同一处理）。
  - 已完成：`hir_seg.tryEta` 是与 β 并列的 boundary rewrite——λ 节点只作为
    `FuncRecord.root` 存在，故操作形式是**重定向值位置的 `fn_ref` payload**
    （不改 λ 记录根，否则破坏 lowering 的「函数根是 λ」不变量）。门：op 为
    `fn_ref`；目标记录 kind == `.lambda`；body 恰好是 `call(fn_ref, %B0 …)`，
    实参是自己的参数、按序各恰好一次（同时即捕获条件，`fn_ref` 不闭包
    binder）；wrapper fn type 与 callee 的 `meta.Type.eql`（含参数模式）；
    body call 的摘要 `isTotal ∧ observable_effect_free`（`callBound` 与实参
    无关，即 callee 的摘要 / host 声明）。链 `fid → F → G` 一次调用内解析，
    `max_eta_chain` 拒绝环 / 超长链，故每轮幂等。`Stats.etas` 计重定向数。
    测试：正例（值位置重定向到 member、链式解析到终点、λ 记录根仍是 `lambda`、
    二次运行是 fixpoint）与负例（trap callee / 非 `fn_ref` callee（call 结果）/
    参数顺序不符 / 篡改的 fn type 不符 / 跨模块 access 链回 `Top`）；
    `probes/eta.st` 进全语料 on/off 解释器差分与 pass smoke。
  - 依赖：无。

- [x] **7. 节点级 full-expression 边界标注**（[hir.md](hir.md) §5.6 / §8.1 /
      §8.7、[effects.md](effects.md) §11.2）
  - 范围：builder 在构造时按 FE 切分并给 `ExprNode.full_expr` 赋真值；validator
    增加「节点 FE 与清理 token FE 一致」与「SEG island 不跨 FE」两条不变量；β /
    match 克隆的 FE 改为按真实 FE 映射；顺带解掉 [effects.md](effects.md) §11.2
    中「含 Unique region 绑定子树回 `null`」的 scope-end 保守守卫。
  - 已完成：`hir_build_cleanup.register` 在既有的 FE 切分遍历里把真实 FE id 写进
    每个节点的 `ExprNode.full_expr`（`lambda` 根用其体 FE；FE 0 仅种子默认），
    与 token 的 FE 身份同一事实。validator（`checkCleanupTokens`）新增「live
    token 的 `origin_expr` 节点归属 token 的 `full_expr`」。「SEG island 不跨
    FE」由 `hir_effects.ownershipGate`（`full_expr != root_fe` 即拒）强制，island
    准入因此真的拒绝跨 FE 子树；β 的 `clone_fe = 调用点 FE` 与 match 拼接的 FE
    从此非平凡（克隆节点 FE == 调用点 FE 有白盒测试）。测试：FE 边界正例（同 FE
    的整棵子树 + `let` init 自成 FE 的负例）、跨 FE island 被拒的正 / 负例、β
    克隆 FE 断言、token / 节点 FE 一致性负例；examples/probes on/off 解释器输出
    逐字相等。
  - **有意未做**：scope-end 守卫（`regionOwnsUnique`）**不**随节点级 FE 放开——
    类型匹配的 `origin_expr` 只可能是产出该值的 init 节点，而它自成一个内层 FE，
    语义上正确的销毁点却在外层 FE 末尾，故无法满足新增的「origin 节点 FE ==
    token FE」；`registration_index` 的契约是「该 FE 内创建序中的位置」，scope-end
    绑定不由 FE 临时量的纪律产出。原因记于 [effects.md](effects.md) §11.2；
    真正放开需独立的 scope-end 销毁累加与排序模型。
  - **行为边界**：源级 `let` 的 init 自成 FE，故不再是 island 成员，SEG 的 let
    规则改走 boundary 契约（见「已完成」第 15 项：跨 FE 折叠的契约准入），
    β / match 拼接的 `let` 则仍可在 FE 内继续化简。

- [x] **1. `match` 进 SEG**（[hir.md](hir.md) island/规则集与
      `passes/hir_seg.zig`）
  - 范围：为 `match` op 增加 SEG 编码与 **copy-only、known-variant**
    归约 → `let` 规则；consuming match 与 effectful arm 排除；准入仍走
    `isSegSafe`，不新增 op 白名单。
  - 依赖：无（承接已落地的 SEG v1 四组规则）。
  - 验收：白盒规则用例 + 负例（consuming / effectful arm 拒绝、非法
    variant 拒绝）；examples/probes 全语料 `--seg` 编译 + AIR
    round-trip + SEG-on/off 解释器输出逐字相等。
  - 已完成：`match` / `variant_make` 注册 `SegEncoding`（hir.zig）；
    `hir_seg.zig` 的 `ruleMatch` 把已知 tag 的 `variant_make` scrutinee
    归约为覆盖 arm 的嵌套 `let`，payload 叶只接受 bind / wildcard 并按构造
    次序绑定；测试覆盖正例、consuming / borrowed / effectful / nested 负例、
    单轮 `let` 链（次序实证）与 malformed HIR（越界 tag、arity 不匹配），
    以及 examples/probes 全语料的 `--seg` 编译 + AIR round-trip +
    SEG-on/off bundle-loader 解释器差分（含 panic 前输出与终止）。
    注：多 payload 时节点数可能不降，终止由 `max_iterations` 轮界保证
    （不保证收敛到不动点）。

- [x] **2. host ABI 余项：缓存指纹 + 回调参数化**（[effects.md](effects.md) §13）
  - 已落地：`StillaExecution = Forbidden | MayExecute | Unknown`（缺失 =
    `Unknown`）、符号键 `effects.HostDecl` + `HostEffects.resolve` +
    顺序无关的 `consolidate`、`frontend.Options.host_decls` 贯穿初始分析 /
    SEG / selective ANF / `revalidateHir`、**缺失声明 / `MayExecute` /
    `Unknown` 一律取完整 `Top`**（读集就是 `EffectSummary` 本身，不另设
    读集字段）。
  - 余下范围：(a) 引入 `EffectEnvironmentFingerprint`（host 语义 registry
    generation、effect-domain 注册表、overlap/disjoint 与 `stable` 声明、
    **host 声明集合**）进入 module cache / incremental 编译键——现有
    `frontend_cache.zig` 只缓存解析产物、phase-2/3 每次重导，故这是为
    「缓存 phase-2/3 结果」预留的前置条件；(b) 回调参数化摘要
    （`own ⊔ ⨆ effect_bound(target_i)`，保存后调用归因于实际触发阶段）；
    (c) host_bind typed registry 自动声明接线与宿主侧符号序列化工具。
    注：**不**包含运行时侧契约校验——编译器看不到 host 代码，无法验证，
    也不提供重入能力。
  - 依赖：无；与 CleanupFootprint 相互独立。
  - 验收：指纹随声明集合变化即缓存失效的测试；读取可观察性（声明为
    `Write` 或可观察读）用例；参数化正例 + 未绑定回调回 `Top` 的负例。
  - 已完成的部分验收：`effects.zig` 的三态、符号解析与**矛盾声明顺序
    无关降为 `Top`** 单测；`hir_effects.zig` 的「undeclared host metadata
    is Top」；`interpreter_lifecycle_tests.zig` 的端到端用例（同一程序：
    无声明被拒并断言具体 §7 诊断 + `program == null`；`Unknown` /
    `MayExecute` 配 `pure` 仍被拒；`Forbidden` 在 seg/simplify 四种开关
    组合下均通过）。
  - 已完成：(a) `effects.Environment` +
    `EffectEnvironmentFingerprint.compute`：host 声明集合（含回调契约）、
    effect-domain 注册表（`domains`）与 `stable` / `disjoint` 关系、registry
    generation 折叠为规范指纹（集合排序、整数定宽小端、摘要行先规范化）；
    声明顺序不变，增删改任一维即变。`frontend.Options.resources` 贯穿初始分析 /
    SEG / selective ANF / `revalidateHir`（`effect_domains` /
    `host_registry_generation` 仅指纹用）；`frontend_cache.zig` 暴露
    `SemanticKey`（specifier + 内容 hash + 指纹）并记录最近一次编译的指纹与
    转换计数——解析与 effect 环境无关，解析缓存不随之失效，指纹是
    「缓存 phase-2/3 结果」的语义键。(b) `HostDecl.callbacks` /
    `HostEffects.Entry.callbacks`：`MayExecute` binding 的「同一次调用内、
    只经列出的实参位置」穷尽契约；`.call` 处收紧为
    `own ⊔ ⨆ effect_bound(target_i)`，直接 `fn_ref` / 内联 λ 之外的目标、
    越界位置、缺契约一律 `Top`；`collectCallees` 把实例化目标并入调用图
    （回调递归因此拿到 SCC `Diverge` 种子）；`consolidate` 对同一 binding
    的声明「全等才保留，否则 unknown」。(c) `host_bind.MemberEffects` +
    模块结构体的 `effects` 表：`register` 在 comptime 生成
    `<module>.<member>` 键的 `HostDecl`；`host_bind.declarations` 是宿主侧
    序列化工具；`buildProgram` 把所选 registry 的声明接入 `frontend.compile`。
    测试：指纹顺序稳定 / 各维变键、回调正负例与递归、注册-only 契约、
    可观察读（`Write`）保留 vs 仅 Q 读删除、host_bind 序列化与 embed 接线。

- [x] **3. `CleanupFootprint` / `observed_effect` 清理路径**
      （[effects.md](effects.md) §11.2、[hir.md](hir.md) §5.6 / §10.1）
  - 范围：由 builder 登记 full-expression 清理 token（`origin_expr` +
    type + `registration_index`），使 `isDiscardable` / `canFloatAsTree`
    不再只依赖 cleanup-free MVP，并在变换后重映射 token 并保持相对
    销毁序；`observed_effect` 走完整清理摘要。
  - 依赖：无；**是第 4 项（Unique ANF 物化）的前置**；第 6 项只在
    涉及清理注册变化时需要它。
  - 验收：token 登记不变量（origin/registration_index 一致、变换后
    重映射）；cleanup-aware 查询的正/负例；未建模清理仍失败关闭。
  - 已完成：`hir.CleanupToken`（`origin_expr` / `ty` / `full_expr` /
    `registration_index`）+ `Program.cleanup_tokens` / `cleanup_modeled`；
    builder 清理登记 pass（`passes/hir_build_cleanup.zig`，由
    `hir_build.buildProgramInner` 驱动）按语句 / let 初始化器切分 FE，
    按求值序（子先于父）只为**已转移判定之外**的 Unique 值产生节点登记
    token（consume / let 绑定 / 聚合元素 / 返回根均视为转移；`seq` rest
    与 region body 转发不重复登记）；`hir_effects.cleanupEffect` 逆创建序
    折叠 `drop_effect(T)`，`observedEffect` / `canFloatAsTree` 改走它，
    `cleanupFree` 保持字面语义；未建模 program（`cleanup_modeled=false`）或
    含 Unique region 绑定的子树回 `null` → `Top`（失败关闭）；dead-let 对
    Unique 绑定额外要求 `bindingCleanupDiscardable`；ANF / dead-let / SEG
    clone 经 `Program.remapCleanupOrigin` 重映射 origin 并保留
    `registration_index`。测试：token 不变量（origin/type/FE/registration
    一致 + validator）、已建模纯析构正例、可观察析构负例、未建模失败关闭、
    转移实参不计清理、ANF 重映射 + 序保持。
  - 注：节点级 full-expression 边界标注（`ExprNode.full_expr`）当时仍为身份
    占位；token 自带 FE 身份用于 `registration_index` 的 FE 局部序（第 7 项
    已落地，见下）。

- [x] **4. selective ANF 的 Unique 物化**（[hir.md](hir.md) §5.7）
  - 范围：在清理 token 证明合成 `let` 的销毁点与原匿名临时量的
    full-expression 边界重合后，放开 ANF 只提 Copy operand 的限制。
  - 依赖：**第 3 项**。
  - 验收：Unique operand 物化后的析构点与未改写一致；examples/probes
    on/off 解释器输出逐字相等。
  - 已完成：`hir_simplify.zig` 的 `tryAnf` 放开为「Copy 总可提；Unique 仅在
    `operandUseOf == .consume`（父节点转移）或父节点为 `Class.seq` 的非末位
    operand（被丢弃语句、`discardValue` 就地处弃）时可提」，`Read` / `Borrow`
    仍在树内；新增 `deferrableOperands`：sequence 提升后来 operand 时要求其
    先前 operand 全为 Copy（Unique 绑定的就地处弃不在 `can_float_as_tree`
    的清理模型内，跨过它会推迟一个可观察析构）。顺带修正 `cfg_lower_call`
    的 `lowerCallArg`：绑定局部量的 `move_` 结果未被标记已消费，full-expression
    边界会重复 drop（该路径由合成 `let` 首次触达）。测试：白盒正例（转移、
    丢弃语句）与负例（`borrow` 留在树内）、黑盒正/负例、定向 on/off 解释器
    差分（析构顺序逐字固定）、examples/probes 全语料的 on/off 差分。

- [x] **5. 间接调用目标收窄**（[effects.md](effects.md) §9.2）
  - 范围：需求驱动的局部 fn-ref 目标传播；预算超限即回 `Top`，
    **绝不截断目标集**（截断会低报摘要）。
  - 依赖：无。
  - 验收：目标集精确化的正向用例 + 超预算回 `Top` 的负例；未知目标
    仍保守。
  - 已完成：`hir_effects.Analysis.resolveTargets` 沿 builder 的局部绑定链反向
    解析 callee → `{func, host}` 目标集：字面 `fn_ref`、`local`（经创建期一次
    扫描的 `binder_init` 索引到其单参无 pattern 的 `let` 初始化器）、`if` /
    `match` 各分支 region root、`seq` 末位 operand、`move` / `borrow` 透传；
    其余（函数 / λ 参数、解构 / arm 绑定、`field_get` 逃逸、`call` /
    `module_const` 结果、模块链、`any_cast`）回 `Top`。预算
    `max_indirect_targets = 8` / `max_indirect_steps = 64` 超限即不可证明，
    **绝不返回前 N 个**。`effectBound` / `callBound` / `callbackBound` 与
    `collectCallees` 共用同一解析；调用图因此看到同一目标集（否则经局部
    fn-ref 的递归会漏掉 SCC `Diverge` seed）。`binder_init` 在 `Analysis.init`
    构建一次。测试：let / 分支有限集正向 + 精确值为目标 join、参数与
    `field_get` 仍 `Top`、预算边界（恰好 8 个可解析、9 个回 `Top`——所有目标
    同读一常量，故可区分“截断”与真回 `Top`）、局部 fn-ref 递归 seed
    `may_diverge`、回调解经 let 绑定实参；黑盒：间接调用读较早 module const
    的初始化器被接受；新增 `probes/indirect_targets.st` 进全语料差分。

- [x] **6. effectful β 实参放开**（[effects.md](effects.md) §10.4）
  - 范围：在 β 契约（求值次数与顺序保持 + scope/FE 映射 + cleanup
    证明）下，允许 effectful 实参进入 β；v1 原先只对 Copy 且
    discardable 的实参、cleanup-free 的单表达式 λ 体提供契约实例。
  - 依赖：必须有 cleanup 证明；涉及清理注册变化时依赖第 3 项，
    cleanup-free 子集可单独验证。
  - 验收：契约下单独验证的定向用例；破坏顺序 / scope / FE 的负例；
    on/off 解释器差分。
  - 已完成：`hir_seg.tryBeta` 的 call 级门从完整 `isSegSafe(id)` 收窄为其
    **残余三件**——结果 `Copy`、`cleanupFree(id)`（callee + 实参子树，body
    延迟不计）、`ownershipGate(id)`；实参逐项只再要求 `Copy`。于是 trap /
    diverge / Q / 任何可观察效果的实参都进入 β（β→let 逐参数 LTR 求值一次，
    不删除 / 不复制 / 不重排），而 `move` / borrow 实参仍被 ownership gate 拒，
    effectful λ 体仍被 `isSegSafe(body)` 拒。契约新增的下游义务落在 `ruleLet`：
    dead-let 与 used-once forwarding 现在要求 `encOf(init)`（init 仍是 island
    成员）——否则 effectful init 会被丢弃或搬到使用点，丢掉 / 重排效果；β 克隆
    体与 match 拼接的 `let` 的 init 由构造保证仍在 island 内，不受影响。测试：
    effectful 实参被 β 的正例、unused / used-once 实参的 init 保留（效果不丢）、
    双 effectful 实参 LTR 序（打印序逐字）、fresh-binder scope、full_expr 破坏
    负例；新增语料 `probes/effectful_beta.st` 进 on/off 差分与 pass smoke。

## 长期探索

- [ ] 统一 `EffectDependencyNode`（Function ∪ DropType）单图 fixpoint，
      消掉跨层环回退 `Top` 的精度洞（[effects.md](effects.md) §11.1）。
- **已提升为「近期」：** 真正的 slotted e-graph / extraction 拆为第 21–23 项
      （e-graph 本体、cost model + extraction、覆盖 e-graph 的统计与预算）；v1
      原位树重写器是其前身。
- [ ] `HIRTypeId` canonical 表（[hir.md](hir.md) §3.8 Target）：为 SEG 的 O(1)
      类型相等与摘要 interning 给 `meta.Type` 加一张 canonical 表。
- [ ] source span side table（[hir.md](hir.md) §3.6）：`ExprNode.origin` 的 span
      表尚未落地。
- [ ] Unique / consuming / borrowed 情形进 SEG（需线性等式系统）。
- [ ] Typed HIR Target 形态：monomorphization / ownership 检查在 HIR 上
      完成（[hir.md](hir.md) §2.3 远期边界；未立项）。
- [ ] SEG 的 associativity / commutativity 搜索（正文列为 SEG 之外的
      方向，未立项；结构相等的 CSE sharing 已落地（见「已完成」第 10 项））。
- [ ] effect 域间层级 / alias 例外表（[effects.md](effects.md) §5.6 Target）：
      现只有 `stable` 域集合与显式 `disjoint` 对，域内层级 / alias 例外未建模；
      与「待决」的 overlap/disjoint 具体条目是同一方向的精度补全。
- [ ] 函数摘要的增量失效：标脏 / 世代号 / 依赖传播（[effects.md](effects.md)
      §8.3）。现为全量重算；触发条件是「缓存 phase-2/3 结果」——
      `EffectEnvironmentFingerprint`（「已完成」第 2 项）是已落地的先决条件，本项
      是其剩余部分。
- [ ] `canMove` / `MovementContext` 暴露（[effects.md](effects.md) §10.5）：需先
      建模移动路径上的 FE / lifetime / 清理注册变化事实；在第一个需要 code motion
      的重写出现前，暴露恒 false 的入口无意义。

## 待决（规范措辞与契约）

- [ ] Core teardown 措辞与字段/容器元素级 hook 读的关系：现措辞只约束
      「hook 及其传递调用」，未表达结构销毁链上的读（[effects.md](effects.md) §15）。
- [ ] teardown schedule 是否收紧为「仅较晚 Unique」：现按规范字面禁止
      读一切较晚常量（含从不销毁的 Copy），待规范澄清后回填
      [effects.md](effects.md) §15 与 checker 行为。
- [ ] effect 域间 overlap/disjoint 的具体条目，随真实 host 域出现后
      按需补全（[effects.md](effects.md) §5.6）。
- [x] host 重入契约已定并落地（[effects.md](effects.md) §13）：缺失 =
      `Unknown` 取完整 `Top`，只有显式 `Forbidden` 才让声明逐字生效。
      回调参数化摘要与 `EffectEnvironmentFingerprint` 缓存指纹均已落地
      （见「已完成」第 2 项）；运行时侧契约校验仍不在范围内（编译器看不到
      host 代码，也不提供重入能力）。
