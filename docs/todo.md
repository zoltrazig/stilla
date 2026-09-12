# Stilla frontend TODO — HIR 与 effect 模型

本文件是 HIR / effect 模型未落地工作的**唯一清单**，由
[hir.md](hir.md) 与 [effects.md](effects.md) 的现状章节统一引用。
「近期」内各项的先后是**建议顺序**，不是串行依赖；每项单独列出前置
依赖。设计细节仍在两篇文档正文，本文件只记范围、依赖与验收。

## 近期（建议顺序）

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
  - 注：节点级 full-expression 边界标注（`ExprNode.full_expr`）仍为身份
    占位；token 自带 FE 身份用于 `registration_index` 的 FE 局部序。

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

- [ ] **5. 间接调用目标收窄**（[effects.md](effects.md) §9.2）
  - 范围：需求驱动的局部 fn-ref 目标传播；预算超限即回 `Top`，
    **绝不截断目标集**（截断会低报摘要）。
  - 依赖：无。
  - 验收：目标集精确化的正向用例 + 超预算回 `Top` 的负例；未知目标
    仍保守。

- [ ] **6. effectful β 实参放开**（[effects.md](effects.md) §10.4）
  - 范围：在 β 契约（求值次数与顺序保持 + scope/FE 映射 + cleanup
    证明）下，允许 effectful 实参进入 β；v1 目前只对 Copy 且
    discardable 的实参、cleanup-free 的单表达式 λ 体提供契约实例。
  - 依赖：必须有 cleanup 证明；涉及清理注册变化时依赖第 3 项，
    cleanup-free 子集可单独验证。
  - 验收：契约下单独验证的定向用例；破坏顺序 / scope / FE 的负例；
    on/off 解释器差分。

## 长期探索

- [ ] 统一 `EffectDependencyNode`（Function ∪ DropType）单图 fixpoint，
      消掉跨层环回退 `Top` 的精度洞（[effects.md](effects.md) §11.1）。
- [ ] SEG 从可选变默认，并测编译时间预算。
- [ ] Unique / consuming / borrowed 情形进 SEG（需线性等式系统）。
- [ ] Typed HIR Target 形态：monomorphization / ownership 检查在 HIR 上
      完成（[hir.md](hir.md) §2.3 远期边界；未立项）。
- [ ] SEG 的 associativity / commutativity 搜索与 CSE（正文列为 SEG
      之外的方向，未立项）。

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
      （见「近期」第 2 项）；运行时侧契约校验仍不在范围内（编译器看不到
      host 代码，也不提供重入能力）。
