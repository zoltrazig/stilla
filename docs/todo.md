# Stilla frontend TODO — HIR 与 effect 模型

本文件是 HIR / effect 模型未落地工作的**唯一清单**，由
[hir.md](hir.md) 与 [effects.md](effects.md) 的现状章节统一引用。
「近期」内各项的先后是**建议顺序**，不是串行依赖；每项单独列出前置
依赖。设计细节仍在两篇文档正文，本文件只记范围、依赖与验收。
已完成的历史条目按原编号归档于「已完成」节，供跨文档交叉引用；
「近期」从第 12 项续起，新增项一律追加到队尾。

## 近期（建议顺序）

- [ ] **12. SEG 编译时间预算与默认开启**（应用面；[hir.md](hir.md) §11、
      frontend.zig）
  - 现状：`--seg` 默认关，pipeline 位置在 `--simplify` 之后、各自跟一次
    `revalidateHir`（frontend.zig）；`hir_seg.Stats` 已记
    `iterations / islands / beta / etas / folds / algebra / lets / conds / matches`，但
    没有语料级时间 / 预算基线。
  - 范围：以 `Stats` 与 `probes/` + `examples/` 全语料为输入，度量 SEG 编译时间、
    轮数与 island 覆盖并形成预算；据此把 SEG 从 `--seg` 翻为默认开启（保留 opt-out）。
  - 依赖：**第 11 项**（已落地：有界轮数契约）。
  - 验收：语料级 SEG 编译时间 / 轮数基线记录；默认开启后 `--simplify` × `--seg`
    四种组合的 on/off 解释器输出逐字相等；CI 时间预算不回归。

- [ ] **13. rewrite 契约形式化**（[effects.md](effects.md) §10.3–§10.4）
  - 现状：两层判定（applicability 按 typed opcode vs operational legality 走派生
    查询）已经分开，但只是内联在规则函数里——`RewriteRule` / `Requirement` 与
    `RewriteContract` **在代码中不存在**，β 的契约由 `hir_seg.zig` 的 `tryBeta`
    内联强制。
  - 范围：把 effects.md §10.3 的 applicability / legality 两层与 §10.4 的
    `RewriteContract` 落为类型：`RewriteRule { match, build, applicability,
    legality: [Requirement] }`、`Requirement = Discardable | Duplicable |
    SwapOperands | EvaluationCountPreserved`、`RewriteContract { effect,
    maps_scope, maps_full_expr, preserves_cleanup }`；先用 β 与 hir_simplify 的
    dead-let 做首批实例，行为逐字不变。
  - 依赖：无（是现有内联判定的提取，不是新语义）。
  - 验收：规则层 applicability 仍按 typed opcode 分派、legality 引擎无
    `switch(op)`；β / dead-let 现有正负例在形式化实现下逐条通过；
    [effects.md](effects.md) §10.3–§10.4 的「现状：无统一接口类型」段落随实现
    删除或改写。

- [ ] **14. `never_returns` must 事实与后缀删除**（[effects.md](effects.md) §10.1）
  - 现状：`never_returns(f)` 设计为**独立于摘要的 must 事实**（签名 `-> never`
    或结构推导），代码中**不存在**；由它驱动的后缀不可达删除也未实现。摘要代数
    不变，`;` 合并仍保守并入后缀位。
  - 范围：推导 `never_returns`（取不到即 false，递归 SCC 用 greatest-fixpoint
    语义）；调用点后同一直行区域的后缀不可达，可整段删除（含该区域的 FE 清理）。
  - 依赖：删后缀时的 FE 清理归属依赖第 7 项（节点级 FE 边界标注，已落地）。
  - 验收：`-> never` callee 后的语句与清理被删除；有正常返回路径的 callee 不
    删；递归 SCC 的 greatest-fixpoint 用例；on/off 解释器差分。

- [ ] **15. 跨 FE 的 let 折叠（契约准入）**（[hir.md](hir.md) §8.3 / §8.7）
  - 现状：节点级 FE 标注落地后（第 7 项），源级 `let` 的 init 自成 FE，故不是
    island 成员，SEG 的 let 规则只在 β / match 拼接的 `let`（init 与 `let` 同
    FE）上触发；源级 dead-let 由 `--simplify` 的 `hir_simplify.tryDeadLet`
    承担（不经 island 门）。§8.7 的跨 FE 折叠（`let B1 = %B0 in %B1 → %B0`）
    因此仍被推迟，且 `seg.st` 的 `unused_let` 现在固定的是边界本身。
  - 范围：按 β 的 boundary-rewrite 契约模式（而非 island 成员资格）为
    `ruleLet` 的 FE 安全子集增加准入：dead-let 要求 init `isDiscardable`；
    used-once forwarding 要求 init 的 island 成员资格（Copy、cleanup-free）；
    trivial-atom forwarding 要求原子 init `isDuplicable`（补上 borrowed-view
    原子的准入证明）；合成结果不得跨 FE 移动清理。
  - 依赖：**第 7 项**（已落地）。
  - 验收：契约正例（源级纯 init 的 dead / forward / 原子复制）+ 负例
    （Borrowed view / Unique / 可观察 init）；on/off 解释器差分。

## 已完成（归档，原「近期」第 1–11 项）

> 以下条目均已落地，按完成时的编号保留，供 [effects.md](effects.md) 等正文
> 交叉引用；新工作从「近期」第 12 项续起。

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
    规则只在 β / match 拼接的 `let` 上触发；源级 dead-let 仍由 `hir_simplify`
    承担（见「近期」第 15 项：跨 FE 折叠的契约准入）。

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
- [ ] 真正的 slotted e-graph / extraction（[hir.md](hir.md) §8.2 Target）：
      e-class、union-find、saturation、SLOT 编号、extraction、cost model；v1 原位
      树重写器是其前身。
- [ ] `HIRTypeId` canonical 表（[hir.md](hir.md) §3.8 Target）：为 SEG 的 O(1)
      类型相等与摘要 interning 给 `meta.Type` 加一张 canonical 表。
- [ ] source span side table（[hir.md](hir.md) §3.6）：`ExprNode.origin` 的 span
      表尚未落地。
- [ ] SEG 从可选变默认（前置：近期第 12 项的编译时间预算基线）。
- [ ] Unique / consuming / borrowed 情形进 SEG（需线性等式系统）。
- [ ] Typed HIR Target 形态：monomorphization / ownership 检查在 HIR 上
      完成（[hir.md](hir.md) §2.3 远期边界；未立项）。
- [ ] SEG 的 associativity / commutativity 搜索（正文列为 SEG 之外的
      方向，未立项；结构相等的 CSE sharing 已落地（见「已完成」第 10 项））。

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
