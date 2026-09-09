# Stilla HIR — 规范形中间表示（设计提案）

> **Status：设计提案（尚未实现）。**
>
> 本文为编译前端定义一个规范形中间表示 HIR：binder/region 化的单态表达式
> 树、registry 化的 op 语义、文本形式与受限 SEG 投影。文中数据结构与
> pass 均为提案，未进入代码。配套文档：效果语义模型的权威定义见
> [effects.md](effects.md)，本文 §6.2 只保留 HIR 侧的自含摘要。

## 1. 问题

### 1.1 当前直降的痛点

今天前端走：checker 在 AST 上完成名字解析、泛型展开
（monomorphization）与 ownership 注解；CFG lowering（`lower.lowerProgram`）把
这份注解后的 monomorphic AST 直接生成 CFG AIR。直接 lowering 有几个绕不开
的毛病：

- AST 形状贴近源码（`using`、模块路径、泛型、source name 都还在），优化
  与 lowering 耦合在 CFG lowering 的 emit 路径里；
- 想基于等式饱和（equality saturation）做代数优化时，AST 没有
  binder/作用域的一等表示，无法干净地做 α 等价、let 化简、β-reduction；
- 想加一个新 op 或 intrinsic 语义时没有中间层：要么在 AST / emit 里特判，
  要么在效果表与 SEG 白名单里散落补丁（intrinsic 展开、效果行、规则各写一处）。

### 1.2 语言特性给了这条路

Stilla 特别适合「先建规范形 IR、再做受限等式优化」这个方向：

| 特性 | 出处 | 对 HIR 意味着什么 |
| --- | --- | --- |
| 局部绑定不可变 | Core | let 天然可 canonical 成 binder，无赋值扰动 |
| 控制流表达式化、无 loop | Core | 没有 statement IR / 没有基本块级的复杂 |
| 函数单态且不捕获 | Core | 无运行时多态、无 closure capture，作用域可严格切断 |
| 从左到右、恰好一次求值 | Runtime | 求值次数可由**树结构**决定 |
| 显式 ownership（Copy/Unique/borrow） | Types & Ownership | 效果系统与所有权系统可正交 |

### 1.3 设计目标（四条原则）

1. **名字不进入语义 IR——`BinderId` 才是身份。** 变量引用永远是
   `Local(BinderId)`，不是字符串；shadowing 不依赖名字，α 等价在
   binder/region 结构上可判定（SEG 中经 slot 映射成为字面同一）。
2. **Binder 的作用域用一等 `Region` 表示。** `let`、函数/λ 参数、match
   arm 的 pattern 绑定统一为 region 的 params；没有独立 statement IR，
   也没有独立的 pattern 作用域机制。
3. **Op 用 registry 间接扩展，不用无限膨胀的 `union ExprKind`。**
   `ExprNode` 极小，op 语义（验证、效果、ownership、SEG 编码、lower 到
   AIR）挂在 `OpDescriptor` 上。
4. **SEG 只优化安全的纯 island，不接管整个 HIR。** v1 的 SEG 只接受
   Copy、total、无 Unique 子值、无借用的子树。

### 1.4 非目标

- 不做传统大型递归 `enum Expr` AST（`Add(Expr,Expr) | Let(...) | ...`）。
- 不把 SEG 当主 IR：ownership、drop、求值顺序、trap 等语义不能被
  equality saturation 弄乱；SEG 只投影纯 island。
- 不处理 runtime polymorphism：泛型在 monomorphization 时已消解，HIR
  之后全是单态函数。
- 不做通用优化器：HIR 侧是「固定的小规则集 + 受限 SEG island」，不是带
  cost model 的通用 term 重写引擎。

## 2. 方案概览

### 2.1 定位

> **HIR 负责保存 Stilla 的精确语义；SEG 只是 HIR 的一个临时、受限的
> 优化视图。**

### 2.2 目标管线

```text
Source
  │
  ▼
AST
  │  ├─ name resolution（checker，保留现有）
  │  ├─ using 消除 / 模块路径解析
  │  └─ generic inference（checker，保留现有）
  ▼
Typed HIR
  │  ├─ monomorphization（现有 monomorphize 的产出喂入）
  │  ├─ type alias expansion
  │  ├─ ownership verification（现有 checker_ownership 结论搬移）
  │  ├─ effect classification
  │  └─ full-expression marking
  ▼
Monomorphic HIR
  │
  │  ┌───────────────────────────────┐
  │  │  pure / Copy / total islands  │
  │  │              ▼                │
  │  │        Slotted E-Graph        │
  │  │              │                │
  │  │          extraction           │
  │  │              ▼                │
  │  └─────── optimized HIR ◀────────┘
  │
  ├─ ownership view 再验证
  ├─ cleanup / drop planning
  └─ control-flow lowering
  ▼
AIR / CFG（SSA）→ 现有 optimizer → LLIR
```

关键边界：**SEG 发生在 monomorphization 之后、CFG/SSA lowering 之前**。
泛型是编译期 specialization，运行时没有多态，SEG 不需要处理 runtime
polymorphism。

### 2.3 与现状管线的边界

现状管线（已实现，行为基线）没有中间规范形：

```text
module graph → checker（AST 注解：名字/类型/ownership/monomorphization）
    → CFG lowering（lower.lowerProgram：monomorphic AST → CFG）
    → optimizer → LLIR
```

HIR 落在 checker 与 CFG lowering 之间，构成一个**兼容边界**，而不是对
checker 或 CFG lowering 的重写：

- **输入边界** — HIR 构建只消费 checker 的注解输出（已判决的名字解析、
  具体类型、ownership、monomorphize 后的单态体），原样搬移为 HIR 标注，
  不重新推理（静态结论搬移，见 §2.4）；
- **输出边界** — 「HIR → CFG」按现有 CFG lowering 语义逐条对齐：同一输入
  的 AST→HIR→CFG 与现在的直降 AST→CFG 产生语义等价的 AIR（等价门禁，
  见 §10.3）。CFG 层的现有语义参照不因 HIR 引入而改变；
- **范围边界** — 本文描述的 HIR 形态只做规范形（binder/region/pattern
  统一、full-expression 标注、效果摘要），覆盖全部现有语言形态，**不含
  SEG**。SEG（§8）是可选的受限优化视图，按两档范围划分（v1 规则子集与
  match 的 Copy-only known-variant 情形，见 §11）；每档替换后对受影响
  区域局部再验证（§2.4）；
- **远期边界（Target 形态，在本文范围之外）** — 若把 monomorphization
  与 ownership 检查上移到「先建 Typed HIR 再特化」的形态（§2.2 目标管线
  的上半部分），HIR 构建就向上游扩展。本文描述该 Target 形态的架构
  意图；HIR 侧结构与 SEG 契约按此设计，落到 checker 与 CFG lowering
  之间的形态兼容边界与验收见 §11。

### 2.4 两份语义的归属

- **静态结论搬移**：checker 已判决的静态结论（名字解析、具体类型、
  Copy/Unique 结构分类、borrow 合法性、match 穷尽、maybe-unique 状态）
  在 HIR 构建时**搬移**为 HIR 上的标注，不在 HIR 层重算。
- **运行时语义留在 CFG 后**：drop 的展开、LLIR lifecycle 的释放计划保持
  在 CFG 之后——HIR 层只做「计划/标注」，不替代 post-CFG 的 drop lowering
  与 LLIR lifecycle 阶段。CFG 发射契约见 §9。
- **搬移只对初始构建成立**：HIR 上任何变换（含 SEG 的 island 替换）之后，
  必须对受影响区域**重新验证** ownership 与 effects（局部/增量均可），
  不能假定 checker 的静态结论在重写后仍然成立。

### 2.5 阅读导航

先读 §3（数据结构）、§4（文本形式——本文所有 HIR 示例的统一记法）、§5
（绑定/作用域/控制流语义），再读 §6（ownership 与效果摘要）、§7（核心 op
与类型专门化）、§8（SEG 桥与重写合法性）、§9（HIR→CFG 契约）、§10（验证）
与 §11（验收与落地范围）。

## 3. 核心数据结构：arena、间接节点与身份注册

### 3.1 一览

| 概念 | 形态 | 作用 |
| --- | --- | --- |
| 句柄 | 稠密 u32（或 u16/u32 混合）索引 | `ExprId RegionId BinderId PatternId TypeId OpId AttrSetId FullExprId ScopeId SourceOriginId SemanticInfoId` |
| 名字/span | 仅 side table | 不参与结构比较 |
| 容器 | arena + 扁平缓冲 | `exprs / regions / binders / patterns / scopes / full_exprs` + 各 operand/param 扁平缓冲 |
| 节点 | `ExprNode` | 极小：op / ty / operands / regions / attrs / sema / full_expr / origin |
| op | registry | `OpId = (dialect, opcode)` + descriptor |
| 类型 | interner | capability（Copy/Unique） |

### 3.2 容器

```text
HIR
 ├─ expr_buffer:   []ExprId     // ExprNode.operands 的扁平缓冲（见 §3.3）
 ├─ region_buffer: []RegionId   // ExprNode.regions 的扁平缓冲
 ├─ binder_buffer: []BinderId   // Region.params 的扁平缓冲
 ├─ exprs:         Arena<ExprNode>
 ├─ regions:       Arena<Region>
 ├─ binders:       Arena<Binder>
 ├─ patterns:      Arena<Pattern>
 ├─ scopes:        Arena<Scope>    // 词法作用域身份（§5.3）
 ├─ full_exprs:    Arena<FullExpr> // full-expression 边界（§5.6）
 ├─ types:         TypeInterner    // monomorphic HIR 用 cfg.Type；Target 形态再加薄 canonical 表
 ├─ attrs:         AttrInterner    // v1 可为空占位
 └─ ops:           OpRegistry
```

### 3.3 ExprNode

```text
ExprNode {
    op:       OpId,
    ty:       TypeId,
    operands: Range<ExprId>,   // 见下：独立扁平缓冲的切片
    regions:  Range<RegionId>,
    attrs:    AttrSetId,
    sema:     SemanticInfoId,  // ownership view / effects / eval class
    full_expr: FullExprId,     // 所属 full expression（栅栏身份）
    origin:   SourceOriginId,
}
```

```text
Node
  │
  ├─ op --------> OpRegistry（单表：核心 opcode + rep-typed 实例 + descriptor）
  ├─ operands ---> 扁平 ExprId 缓冲（expr_buffer）
  ├─ regions ----> RegionArena
  ├─ attrs ------> AttrArena
  └─ ty ---------> TypeInterner
```

**澄清（与朴素 arena 图的差别）**：`ExprNode.operands` 是
`expr_buffer` 里的一段 `{start, len}` 切片，不是 `exprs` arena 的连续
下标；region 的 params 同理（切 `binder_buffer`）。子节点按源码顺序在
节点创建时 append——求值顺序因此在结构上可枚举（配合 op 的 EvalPolicy，
§5.5）。

### 3.4 Region 与 Binder

```text
Region {
    params: Range<BinderId>,
    root:   ExprId,        // region 体；可见性沿词法父链向上，
}                          // 但止于最近的函数/λ 边界（见 §5.3）

Binder {
    ty:     TypeId,
    mode:   BinderMode,    // value / move / borrow（参数模式，Types & Ownership）
    source: SourceBindingId?,  // 仅诊断用
}

BinderMode =                 // 源级 parameter / binder 契约（Types & Ownership）
    Value          // Copy 或 fresh Unique 绑定
  | Move           // move 参数 / consuming pattern 绑定
  | Borrow         // borrow 参数 / 非 consuming match 的借用视图（Core）
```

例（Core 的 `double`）：内部结构是一个 `lambda` 节点，带一个参数 region
（params = [B0: i32]，root = mul）；同一函数按 §4 的规范文本写：

```text
fn (B0: i32) => mul.i32(%B0, 2i32)
```

source name 是否叫 `x` 对 HIR 无意义；两个只差参数名的函数结构相同
（仅 binder id 占位不同）。注意：原始 HIR 里这是**可判定的 α 等价**，
不是字面同一项——真正的合并发生在 SEG 投影把 BinderId 映射为 slot 之后
（§8）。

### 3.5 Op、OpId 与 OpDescriptor

```text
OpId {
    entry: OpEntryId,     // OpRegistry 单表条目：核心 opcode 或 rep-typed 实例
}
```

**身份只有三类；类别不由前缀承担，而由注册表归属承担。** 句法统一为点段
标识符，但每个名字恰好落入以下三类之一：

1. **核心 opcode**——OpRegistry 的普通条目：单段小写名，必要时用 `_` 连词：
   `const` `local` `fn_ref` `module_const` `let` `seq` `lambda` `call` `if`
   `match` `move` `borrow` `drop` `struct_make` `field_get` `variant_make`
   `tuple_make` `list_make` `any_pack` `any_cast` `num_cast` `panic` …
2. **rep-参数化（typed）opcode**——同一张 OpRegistry 的实例：opcode 与一个
   rep（标量类型）配对，**类型写在 opcode 之后作后缀**（与 LLIR 指令名同款
   拼写）：`add.i32` `div.i64` `mul.u32` `add.f32` …。类型是 opcode 的参数，
   不是命名空间，更不是前缀。
3. **(module, member) 函数目标**——stdlib 模块函数（`list.length`、
   `math.sqrt`）、host 绑定（宿主模块里的无体声明）、模块常量与模块值：
   **不是 op**，不进 OpRegistry。resolution 后只以解析结果存在：
   `fn_ref(FunctionId)` / `module_const(ConstId)` / host binding Id（§7.4）。
   调用一律是 `call` 的 callee；host binding 在 AIR/LLIR 投影为 `syscall`
   （air.md、LLIR Instruction Set）。intrinsic 是 (module, member) 形态的
   无体 stdlib 声明，在 lowering 早期展开（Intrinsics Specification），
   canonical HIR / AIR / LLIR 均无 intrinsic 痕迹。

`host`、`list`、`math` 不是类别，而是**模块**：其成员按类别 3 解析。
新增能力只有两条正规通道：新增 opcode（改核心指令面，走 spec 流程），或
新增模块成员函数 / intrinsic。

每个 op 在 registry 注册一个 descriptor（语义维度的权威定义见
[effects.md](effects.md)；本文 §6.2 给自含摘要）：

```text
OpDescriptor {
    verify,               // 结构/类型校验
    eval_policy,          // StrictLTR / ShortCircuit / Branch / Match / Region
    operand_uses,         // []OperandUse，按 operand 序（Read / Borrow / Consume）
    result_policy,        // 结果 capability/view 规则
    effect_transfer,      // 由 (ctx, ExprId) 得 EffectSummary（递归汇总）
    constant_fold,        // 按 TypeId 的常量折叠
    seg: Optional<SegOpDescriptor>,   // 能否进 SEG + 符号与 rewrite 规则
    lower_to_air,         // HIR → CFG 的发射规则
    print,
}
```

扩展的 `array.map`（stdlib 模块函数）与 host binding 调用不需要触碰 HIR 核心
结构——它们是类别 3 的 call 目标（§7.4），经 resolution 落到 fn_ref / syscall。

**descriptor 的结构性护栏。** OpDescriptor 的字段会随新 op 越滚越宽
（语言语义、printer、parser、lowering、优化各要一块）；facet 化的方向：

```text
OpDescriptor {
    semantics:  SemanticDescriptor,   // eval_policy / operand_uses /
                                      // result_policy / effect_transfer /
                                      // verify —— 语义 ground truth
    syntax:     SyntaxDescriptor?,    // printer / parser 形状
    optimization: OptimizationDescriptor?,  // seg 编码与规则（可空）
    lowering:   LoweringDescriptor,   // HIR → CFG 发射
}
```

registry 启动时跑 `validateRegistry()`（校验列表进 §10.1）：所有 op 必有
semantics；可出现在 monomorphic HIR 的 op 必有 lowering；`seg_encoding !=
null` 时必有对应 SEG 类型契约；typed-op effect 行完整；printer/parser
形状对称。v1 不必全拆，但上述检查从 registry 存在起就生效——否则
registry 化只是把 switch 从代码移到一张更难验证的表。

### 3.6 SemanticInfo 与 TypeId：view、效果、capability 分离

```text
SemanticInfo {
    ownership_view: OwnershipView,   // 值/视图状态（运行时可见）
    effect:         EffectSummaryId, // 语义交互摘要（见 §6.2）
}

OwnershipView = Owned | Borrowed | DestructionView
```

语义按正交维度组织：`EvalPolicy`（在 op descriptor 上，非节点上）、
`OperandUse`（operand 的 Read/Borrow/Consume）、`EffectSummary`（节点上
的 interned 摘要）。**不存派生的 bool**（is_pure 之类）：total /
discardable / duplicable / speculatable 全部由查询从摘要推导（§6.2）。

类型本身只带 **capability**（Copy / Unique，结构性分类，Types &
Ownership §10.3 的 least-Copy fixpoint）：

```text
TypeInfo { capability: Copy | Unique }
```

capability 是类型属性，view 是值/借用状态——规范正是这样区分的：类型
决定 Copy/Unique，borrow 本身不是 owner（Types & Ownership）。

### 3.7 HIR 是树，禁止 DAG

Monomorphic、let 化的 HIR 里大子树天然只有一个父（每个 `let` 的 init、
每个 operand 恰好一个位置）；共享只可能来自构建期 CSE 或重复内嵌同一棵
子树——v1 两者都不需要。因此：

> **构建期即树：validator 拒绝同一个 `ExprId` 出现在多个 operand
> 切片里。** 需要值复用时用显式 `let` 建立——这也是 SEG extraction 把
> CSE 结果 materialize 成 `let` 的原因（§8.3）。

结构 = 求值次数：求值计数只由 HIR 树的结构与顺序决定；pass 可按
`ExprId` 自由缓存，drop/清理注册天然逐 occurrence。若未来允许共享
（构建期 CSE），语义仍如下：

> **结构共享不是运行时 memoization。** 共享节点每出现一次仍按其位置
> 求值一次——不能因共享而少求值（违反「恰好一次」）或多求值（effect
> 重复）。

### 3.8 TypeId 与常量

monomorphization 后每个具体类型有一个 canonical `TypeId`：

```text
TypeId ->
    Primitive(int32, int64, u32, u64, f32, f64, bool, …)
  | NominalStruct(DefId, [TypeId])
  | NominalUnion(DefId, [TypeId])
  | Opaque(DefId, [TypeId])     // 如 Array[T]、HashMap[K,V]（Core）
  | List(TypeId)
  | Box(TypeId)
  | Tuple([TypeId])
  | Fn(Signature)
  | Any                       // 顶层类型，Unique（Types & Ownership）
  | HostData
  | Never
```

常量 op 携带编译期值（按 TypeId 解释）；`fn_ref` 携带单态
`FuncInstanceId`。

**TypeId 词汇与 AIR/LLIR 一致性**：monomorphic HIR 直接复用现有
`cfg.Type`——名义类型
走 moduleinfo 名-interner 的 `TypeId`，结构类型（list / box / tuple /
function）是 `cfg.Type` 结构值，不引入第二个类型世界。Target 若需要
O(1) 类型相等（SEG 的 typed-opcode 查表、effect 摘要 interning），对
`cfg.Type` 加**薄 canonical 表**即可：`intern(cfg.Type) → HIRTypeId`
（结构哈希去重）。cfg.Type 保持为发射到 AIR/LLIR 的**唯一 ground truth**，
「与 AIR/LLIR TypeId 一致」因此退化为恒等映射，无需跨世界一致性论证。
cfg.Type 中 CFG 层专属的 tag（如 `cleanup`）不在 HIR 表内。

## 4. HIR 文本形式（打印与解析）

前几节定义的是内存里的数据结构（arena、ExprNode、Region/Binder）。本节定义它们的
**规范化文本表达**——同一棵 HIR 在屏幕 / 磁盘上的形态，是 printer 与 parser 的
共同契约。用途：

- **调试**：人可读地 dump 一棵 HIR；
- **等价测试与文本 round-trip**（§10.3）：print → parse 语义等价，仅 binder /
  interner 重新编号；
- **SEG 验收与 golden 文件**（§8.2 tie-break）：规范文本相等即 α-等价。

设计原则：无歧义、可解析；**名字自由**（binder 是符号占位，见 §5.1）；求值次数
可由结构读出；region 与 full-expression 边界可见。文本是**优化前/后、CFG 之前**
的 HIR 形态，不要与 CFG AIR 的文本（spec/air.md）混淆。

### 4.1 约定

- **前缀 + 显式括号、无优先级**：一切歧义靠括号消除。pretty 打印可缩进换行，但
  缩进无语义，parser 忽略空白。
- **名字自由（binder 编号确定化）**：printer 用单一确定性遍历给 binder 连续编号
  `B0, B1, …`（按首次引入序：先进入 region 的 params，后其 body 中新引入的
  binder；整体即文本出现序）。因此 α-等价的
  程序文本相同——文本相等即 α-等价。parser 把这些文本 binder 重新映射进 arena
  的 fresh id（§4.9）。
- **声明 vs 引用**：绑定声明写裸 `Bk`；local 引用写 `%Bk`。
- **全表达式边界默认不加标记**（便于 diff）；需要断言「优化不跨 FE」时用
  `fe[ … ]` 包裹（SEG 验收专用，§4.6）。
- **派生标注不是语义**：effect / ownership view 等一律以 `//` 注释出现，parser
  忽略；用于文本相等比较的 canonical 打印**不带**派生标注。

### 4.2 词法（token）

```text
标点     ( ) { } [ ] , : = -> => @ _ .. ::
数字     [0-9]+   |   0x[0-9a-fA-F]+
标识符   [A-Za-z_][A-Za-z0-9_]*（可带点段：opcode / 名义路径用点连接）
Binder   B[0-9]+，引用带前缀：%B[0-9]+
FuncRef  F[0-9]+
HostRef  H[0-9]+（host binding 引用，与 FuncRef 同以 `fnref` 前缀打印）
ModConst C[0-9]+
关键字   let in fn if then else match panic seq fe void true false fnref module
         box byte any hostdata never
注释     // 到行尾   /* … */
字符串   "…"（含转义，仅出现在字面量）
```

词法注意：`.` 同时出现在 typed opcode 后缀（`add.i32`）与名义路径
（`std.option.Option`）里，按
**最长点段标识符**匹配；`::` 用于 variant 路径（pattern 里的
`Option::Some`，Core），`..` 用于 list pattern 的 rest
（`[head, ..tail]`）。`[ … ]` 既作类型实参也作列表类型，由语境区分（类型 /
pattern 里是列表或类型实参，表达式里只在类型标注后出现）。

`Fk` / `Ck` / `Hk` 是**打印局部身份**：号码只在本文本内有意义，跨文本 /
跨 invocation 的身份由 §4.8 的引用字典（稳定语义键）承担。

### 4.3 表达式语法

```text
expr    := lit
         | ref                             // %Bk
         | 'panic'
         | op '(' (expr (',' expr)*)? ')'  // eager operands，源码序=LTR，可空
         | 'let' binder '=' expr 'in' expr // let：init 是 eager operand，在 region 外求值
         | 'fn' '(' binderList? ')' '=>' expr   // lambda 值：一个参数 region
         | 'if' expr 'then' expr ('else' expr)? // if：cond + 两个惰性 region
         | 'match' expr '{' armList '}'         // match：scrutinee + arm regions
         | '(' expr ')'                         // 分组，无语义

lit      := 'void' | 'true' | 'false' | IntLit | FloatLit | StringLit
op       := 点段标识符（核心或 typed opcode，见 §4.4）
binder   := BinderId ':' ty ('@' mode)?   // 默认 value；mode ∈ value|move|borrow
binderList := binder (',' binder)*
pattern  := '_'                          // wildcard
          | Binder                        // 绑定 pattern：即该 arm region 的参数
          | lit                           // 字面量 pattern
          | '(' pattern (',' pattern)* ')'          // tuple pattern
          | '[' pattern (',' pattern)* ('..' pattern)? ']'  // list pattern（可带 rest）
          | NomPath '{' (fieldPat (',' fieldPat)*)? '}'     // struct pattern
          | VariantPath ('(' pattern ')')?          // variant pattern（`::` 路径）
          | ty Binder                               // type-test pattern（Core）
fieldPat := ident (':' pattern)?          // 字段名缩写或全 pattern
arm      := (pattern '=>')? expr          // pattern 绑定的名即该 arm region 的参数
armList  := arm (',' arm)*                // 或换行 / ';' 分隔
```

pattern 形状与 Core 一致；绑定身份一律是裸 `Bk`（§4.1），解构
细节登记在 pattern arena，不产生独立作用域机制（§5.4）。

要点：

- `let Bk: ty = <init> in <body>`：`<init>` 是唯一 eager operand；`Bk` 只在其
  `<body>` 作用域内可见，`<init>` 不得引用它（§5.3 初始化排除）。它等价于通用
  region 形 `let(<init>){ Bk: ty => <body> }`。
- `fn (…) => …` 是 lambda **值**，出现在它被构造处（通常作 `call` 的 callee）；其
  参数 region 的 params 即括号里的 binderList。
- `if` 的 then/else 是两个**无参 region**（body 即 region root）；`else` 缺省表示
  void 分支（块的 if 无 else 时）。
- `match` 的每个 arm 是一个 region：`pattern` 决定 discriminator 与绑定名，`=>`
  后是 body（body 是 region root）。无 pattern 的占位 arm 可省略 `pattern =>`。
- eager apply 的 operands 按**书写序**求值（LTR）；结合 op 的 EvalPolicy（§5.5），
  求值顺序与次数由结构唯一决定。
- **结果类型标注**：当 opcode 自身不含类型（`struct_make`、`field_get`、`match`、
  `fn` 等）时，printer 用尾缀 `: ty` 标出该节点类型；typed opcode（`add.i32`）
  结果类型由符号直接确定、可省。parser 用标注或 binder/op 类型重建节点 `ty`。

### 4.4 op → 文本形态

HIR op 列给出注册表条目（§3.5）：核心 opcode 写单名；typed 实例带类型后缀
（`add.i32`）。模块函数与 host 绑定是 `call` 目标而非 op（§7.4）；intrinsic
在 canonical 文本里不出现（Intrinsics）。

| 类别 | HIR op | 文本形态 | 例 |
| --- | --- | --- | --- |
| 原子 | `const` | 类型化字面量（§4.5） | `1i32` `1.5f64` `"hi"` `true` |
| 原子 | `local` | `%Bk` | `%B3` |
| 原子 | `fn_ref` | `fnref Fk` | `fnref F0` |
| 原子 | `module_const` | `module Ck` | `module C2` |
| binding | `let` | `let Bk: ty = e in e` | `let B1: i32 = add.i32(%B0, 1i32) in %B1` |
| sequencing | `seq` | `seq(e, e, …)` | `seq(call(%f), panic)` |
| function | `lambda` | `fn (params) => body` | `fn (B0: i32) => mul.i32(%B0, 2i32)` |
| function | `call` | `call(callee, arg, …)` | `call(fn (B0: i32) => %B0, %x)` |
| control | `if` | `if c then t else e` | `if %c then 1i32 else 0i32` |
| control | `match` | `match s { arm, … }` | 见 §4.7 |
| aggregate | `struct_make` | `struct_make(e, …) : ty` | `struct_make(%a) : P` |
| aggregate | `field_get` | `field_get(e) : ty` | `field_get(%s) : i32` |
| aggregate | `variant_make` | `variant_make(e) : ty` | `variant_make(%v) : U` |
| aggregate | `tuple_make` / `list_make` | `tuple_make(e, …)` / `list_make(e, …)` | `tuple_make(%a, %b)` |
| ownership | `move` / `borrow` / `drop` | 一元前缀 | `move(%f)` `borrow(%f)` `drop(%f)` |
| dynamic | `any_pack` / `any_cast` | 一元前缀 | `any_pack(%x)` `any_cast(%a)` |
| conversion | `num_cast` | `num_cast(e) : ty` | `num_cast(%b) : i64` |
| runtime | `panic` | `panic` | |

不是原子也不属于 §4.4 命名形状的 op（即携带 region 的结构 op）回退到通用形
`op(args){ params => body }`（region 逐个 `{…}`）。命名形状只是通用形对
let/fn/if/match 这几个常见 op 的语法糖；v1 内建 op 都有命名形状，通用形主要供未来
新增的带 region opcode 使用。

### 4.5 类型与字面量

```text
ty := 'i32'|'i64'|'u32'|'u64'|'f32'|'f64'|'bool'|'byte'|'void'|'never'|'any'|'hostdata'
    | '(' ty (',' ty)* ')'        // tuple
    | '[' ty ']'                  // list[T]
    | 'box' '(' ty ')'            // box[T]
    | NomPath                     // 名义类型：std.option.Option[i32] 等
    | 'fn' '(' (ty (',' ty)*)? ')' '->' ty      // 函数类型
```

字面量带类型后缀（const 节点的类型即由后缀给出）：`5i32`、`-7i64`、`0x1Fu32`、
`1.5f32`、`2.0f64`、`true`/`false`、`"text"`、`void`。

短名 ↔ `cfg.Type` 标量映射：`int32→i32`、`int64→i64`、`uint32→u32`、
`uint64→u64`、`float32→f32`、`float64→f64`、`bool→bool`、`byte→byte`（与 typed
opcode、LLIR 记法一致）。若作者偏好，也可约定整份文本统一用 `int32` 等长名——
二选一，混用视为错误。

### 4.6 派生标注与 full-expression 边界

canonical 文本（用于相等比较、golden）**只含 §4.3 的结构**。附加信息以注释 /
可选开关给出：

```text
// { view: Owned | Borrowed | DestructionView }   → 语义：ownership view
// { eff: E<n> | Pure | Top }                     → 效果：interned 摘要
// { fe: #<n> }                                   → 所属 full-expression
```

要断言「某段优化不跨 full-expression 边界」时用 `fe[ … ]` 显式包裹每个 FE root
（SEG 验收输出带此开关）。普通 diff / golden 不带，靠 §10.1 校验器保证不跨边界。

### 4.7 完整示例

以下示例都是 §4.3–§4.4 语法的合法文本（`fe` 注释仅示意所属 full expression，
不是正文）。

```text
// 1) double——纯算术 λ，只有一条函数体全表达式：
fn (B0: i32) => mul.i32(%B0, 2i32)

// 2) match（borrow 视图的 Option，对应 §5.4）：arm 用 pattern 绑定 B1
fn (B0: Option[i32]) =>
  match(%B0) {
    Option::Some(B1) => add.i32(%B1, 1i32),   // B1: i32（由 variant 声明推出）
    Option::None => 0i32
  }

// 3) λ + call + let（等价 §8.7 的 SEG 例；函数体内两条全表达式边界）：
fn (B0: i32) =>
    let B1: i32 =
        call(fn (B2: i32) => add.i32(%B2, 0i32), %B0)   // fe#0：整个 init
    in mul.i32(%B1, 1i32)                                 // fe#1：result * 1
```

编号都符合首次引入序：例 3 里 `B0`（外层参数）先于 `B1`（let）、`B2`（λ 参数）；
pattern 绑定（例 2 的 `B1`）也按该顺序参与编号。绑定声明写裸 `Bk`，体内引用一律
`%Bk`，读起来不会混。

### 4.8 打印（canonical 输出）

- printer 走 ExprNode 前序：先 opcode / 字面量，再按序 operands，再 regions（每个
  region 先 `{`、其 params 各 binder、`=>`、root）。op 的形状由其
  `descriptor.print` 决定，但输出必须落在 §4.3–§4.4 的语法内。
- 每层缩进 2 空格；一个节点放不下一行时，operand / region 各占一行（缩进只影响
  观感，不影响语义）。
- binder 编号、type/字面量拼写、注释开关全部确定性；同一 HIR 两次打印逐字相等。
- **引用字典（F/C/H 的稳定身份）**：正文若含 `fnref Fk` / `module Ck` /
  host 引用，canonical 输出在正文前附字典段，把每个打印号映射到**稳定
  语义键**（模块限定名 + 类型特化参数；host 为绑定名）：
  `#refs: F0 = string.concat, C1 = config.x, H0 = host.clock.now`。打印号按
  字典的稳定键**排序**分配，与内部 FuncInstanceId / ConstId 数值 id 无关——
  同一源码在不同编译 invocation / 模块加载序下正文逐字相等（golden 稳定），
  字典保证 round-trip 身份不丢。名字只出现在字典这个 serialization 表面，
  不进 IR 结构（§1.3 的名字自由原则不受影响；这与 binder 的 printer-local
  重编号是同一思路，只是把不可靠的内部编号换成稳定键排序）。
- 输出不含 side table 里的 source span / 原始名字（除 §4.6 的注释诊断模式
  与上述引用字典）。

### 4.9 解析与重建（round-trip）

- parser 是递归下降 + 分派到 `OpRegistry`：opcode 先查 registry 再按 descriptor
  的元数/形态解析 operands 与 regions；未知 opcode 报错。
- **binder 重编号**：文本 `Bk` 只是局部符号。parser 在 region 边界把 `Bk` 映射到
  arena 新分配的 BinderId，并在作用域栈里登记；`%Bk` 解析为 `local BinderId`。
  因此 round-trip 不要求与原内存 HIR 的 BinderId 一致——只要解析后过 §10.1 校验。
- 名义类型 / 名义 op（`std.option.Option[i32]` 等）解析回类型 interner 的 canonical
  id；`Fk`/`Ck`/`Hk` 按 §4.8 引用字典的**稳定键**解析回已解析的
  `fn_ref(FuncInstanceId)`/`module_const(ConstId)`/host binding id——出现在
  正文但不在字典里的号码是错误，不得按数值顺序猜测身份（号码只具打印局部
  意义）。
- `fe[ … ]`（若出现）只用于把节点分组到 FullExpr，普通模式忽略。
- **round-trip 验收**：`parse(print(hir))` 通过 §10.1 校验器、并与原 hir 逐节点
  α-等价（binder 编号不同也通过）。文本 round-trip 即 §10.3 的等价门禁
  （覆盖 monomorphic HIR 无 SEG 阶段）。

### 4.10 工具与测试归属

- printer / parser 作为 HIR 属主模块的普通代码（printer 复用 `descriptor.print`）；
  golden / 双向 round-trip 测试放 hir 自有套件与独立的 seg 套件（§10.2）。
- 规范文本是 §8.7 这类示例与 SEG 抽取结果的**可比面**；示例段落逐步改用本节语法，
  不再用散落的不一致示意。

## 5. 绑定、作用域与控制流语义

### 5.1 BinderId 即身份

```stilla
let x = 1;
{
    let x = x + 1;   // 内层块遮蔽：右侧 x 引用外层的 B1
    x
}
```

（示意：外层与内层两个 `x` 在 HIR 中互不相干。）

### 5.2 let 是 binder，不是语句

Stilla block 是表达式，`let` 不可变，因此 canonical 成
`let x = init in body`：

```text
Let
 ├─ operand: init        // 在 region 之外求值
 └─ region:
       bind x
       body
```

```stilla
{
    let x = foo();
    let y = x + 1;
    y * 2
}
```

HIR（fnref F0 = foo；这里 init 与各局部取 i32 为例）：

```text
let B0: i32 = call(fnref F0) in
    let B1: i32 = add.i32(%B0, 1i32) in
        mul.i32(%B1, 2i32)
```

IR 里只有 `Let / Seq / Expr` 三种形状，没有 statement IR。这与 SEG 的
`bind`/`var` 几乎同构（§8）。

**解构 let（M1a 修订，PROGRESS "S4 设计决定"）**：`let (a, b) = e` 这类多叶
不可反驳解构保持为 `let` region —— region 的 `params` 是 pattern 的绑定叶，
`Region.pattern` 记录不可反驳的 pattern 形状（与 match arm 同机制，仅允许
不可反驳形态：wildcard / bind / tuple / struct / list；literal、variant、
type-test 可反驳，只属于 match arm）。纯标识 `let x = e` 仍是原来的
单 binder、无 pattern 形式。

### 5.3 Region 的作用域规则

- **可见性**：region 的 params 在其 `root` 子树内可见；内层 region 的
  params 可遮蔽外层同名 *source name*，但 BinderId 不同，结构上无歧义。
- **初始化排除**：`let` 的 init operand 位于其 region **之外**——init 里
  出现的 `x` 引用外层 binder，绝不是正在定义的这个（对应 `let x = x + 1`
  的语义）。
- **父链**：每个 region 恰好被一条 expr 拥有（该 expr 的 `regions` 切片
  引用它）；「外层 region」由词法父链确定。需要时在 Region 上缓存 parent
  指针，否则由 expr 树推导。
- **函数边界（查找必须在此停止）**：binder 引用沿词法父链解析，但遇到
  最近的函数/λ region 根就必须停止——λ/函数体只能引用自身 region 的
  params 以及**体内**嵌套 let 引入的 binder，绝不可引用外层函数、外层 λ
  的任何局部（不捕获，Core）。若查找越过该边界，捕获语义就
  悄悄回来了；HIR 校验把越界引用判为无约束引用一并拒绝。
- **绑定作用域 ≠ 销毁作用域**：Region 只定义「绑定对谁可见」；销毁点不
  挂在 region 上。局部 owner 绑定在词法作用域（`ScopeId`，含其函数归属）
  结束时销毁（正常路径，Static Semantics Destruction），临时量在
  full expression 结束时销毁（Runtime）——见 §5.6。同一 `let` 的
  init 若产生临时量，销毁注册属于 init 所在的 full expression，与绑定
  自身的作用域无关。
- **不捕获校验**：模块成员在 HIR 里解析成 `fn_ref` / `module_const`
  （§7.4），因此「λ/函数体内引用自身 region 之外、函数之内的局部
  binder」在 HIR 里就是**无约束引用**，由 HIR 校验拒绝——不捕获是结构
  不变量，不是事后检查。
- **shadowing 合法性**由 checker 已判决；HIR 构建只负责无损搬移。
- SEG 免除一部分 α 机制（不需显式 α-rename / free-var e-class
  analysis），但 **HIR 仍需作用域一致性检查，extraction 仍要分配 fresh
  binder**（§8.2）——SLOT 号只在单 island 内有局部意义。

### 5.4 match arm 是 binder region；pattern 绑定

```stilla
match (x) {
    Option::Some(v) => v + 1,
    Option::None => 0
}
```

```text
// x 是 Option[i32] 的一个借用视图（B0 由外层绑定）；pattern 绑定名即 arm region 的参数
match(%B0) {
    Option::Some(B1) => add.i32(%B1, 1i32),
    Option::None => 0i32,
}
```

不是 `Pattern { name = "v" }`。pattern binder 与 let binder、λ 参数完全
统一（arm-scoped 规则由 region 结构天然给出）。pattern 的形状（解构路径、
variant tag、`_`）仍保留在 pattern arena，但**绑定身份**一律走 region
params。

### 5.5 求值顺序：EvalPolicy 与 region 惰性

Stilla 要求子表达式恰好一次、从左到右（Runtime；Static Semantics）。HIR 不能把 `call(f, g(), h())` 的孩子当数学上无序的集合。
descriptor 声明 EvalPolicy：

```text
EvalPolicy =
    StrictLTR      // operands 按序恰好一次（call / struct / tuple / list / 二元 op…）
  | ShortCircuit   // and / or
  | Branch         // cond 先，只求值一个 region（if）
  | Match          // scrutinee 先，只求值一个 arm region（match）
  | Region         // 其余按需/延迟求值的情形（descriptor 自声明）
```

要点：

- **region 是惰性分支**：`if`/`match` 的 region 内容只在被选中时求值；
  `call`/聚合构造的 operands 全部求值且 LTR。两条规则合起来，求值序与
  求值次数由结构决定。
- 求值顺序是**硬约束**：HIR 层任何优化（含 SEG）不得重新排序 effectful
  子表达式。
- EvalPolicy 是**语言语义**，与 effects 正交：可交换是可证明的派生事实
  （`reorderable`），默认语义仍保持 LTR（§6.2）。

> **M1a 实施修订（随 S5 落地）**：`and`/`or` 在 §7.1 登记为独立 control 行
> （`ShortCircuit`，1 operand + 2 regions，与 `if` 同构），不再编码为
> `if (lhs) { rhs } else { false }` 形状。原因：HIR→CFG lowering 的等价格门
> （§10.3）要求 `and`/`or` 复刻直降的短路菱形结构（`rhs`/`false_` 块与 join），
> 与 `if`（`then`/`else` 块）不是同构的 CFG 发射；且源码 `if c {x} else
> {false}` 与 and 形状在 HIR 中不可区分，猜形不可取（§12 认可门禁驱动的表述
> 缺口补正）。

### 5.6 full-expression 栅栏

Unique 临时量在所属 full expression 结束时销毁、反向创建序（Runtime；Types & Ownership；Core 定义 full expression）。因此：

- 每个 `ExprNode` 带 `full_expr: FullExprId`（或显式 full-expr 包装
  节点）；
- **SEG 第一阶段绝不跨越 full-expression 边界**，否则
  `foo(make_unique()); bar();` 这类代码的 drop timing 会被无意改变；
- `FullExpr` 记录入口/出口与登记在其清理栈上的临时量（entry/exit
  元数据）；每条登记是带 **origin_expr**（创建它的 occurrence）与
  registration_index 的 token（CleanupFootprint，effects.md §11.2）；
  A-Normal Form 合成、SEG 准入与 CFG lowering 都以它为准，不重算。

**HIR / CFG 分界**（与 effects.md §11.3「drop_effect ≠ 有序销毁计划」一致）：
HIR 持有 full-expression 身份、临时量的创建/所有权事实、清理候选（token
登记）与 FE 内顺序约束；CFG lowering 消费这些事实**重新构造可执行销毁
计划**——同一 FE 内临时量沿用 per-expression 临时栈在表达式尾反向销毁的
现有机制（[cfg-lowering.md](cfg-lowering.md)），maybe-unique 的 join 边
drop 与条件路径清理由 CFG 侧计划。HIR 不重算「谁属于哪个 FE」，CFG 也
不重算 ownership 事实；HIR 的标注不是把 CFG 的临时栈整个搬上来，而是它
的上游事实源。

### 5.7 Selective A-Normal Form（而非全面 A-Normal 化）

为了兼顾 SEG 与求值语义：

> **effectful / 可能 trap / Unique 的表达式提为 let；纯 Copy 表达式保留
> 树结构。**

```stilla
f(host.read(), a + b * c)
```

HIR canonical：

```text
let B0: i32 = call(fnref H0) in      // host.read（host binding）→ fnref；effectful：提为 let
    call(fnref F0, %B0, add.i32(%B1, mul.i32(%B2, %B3)))   // 纯 Copy：保留树
```

host binding 调用（源级名字 `host.read()`）被钉在固定位置；`a + b * c` 仍是
可送 SEG 的表达式树。
「提还是不提」由派生查询 `can_float_as_tree` 决定（total /
observable_effect_free / 清理上下文，§6.2），不硬编码 op 名单。
注意此改写假定 callee（`f`）是已求值的原子引用（`fn_ref` 或已绑定的
`local`）；若 callee 本身是需要求值的表达式，先按 LTR 绑定 callee，再
按序提实参。**绝不**从惰性分支（未选中的 region）内部向外提升。

合成 let 的规则（防临时量生命周期被拉长）：

- 合成 let 只能从**同一 full expression 内**提子表达式，且保持 LTR；
- 合成 let **不改变临时量的销毁注册**：init 产生的 Unique 临时量仍登记在
  原 full-expression 的清理栈上（销毁点与未改写时一致）。不要为此发明
  内层 full-expression 边界——那会提前销毁仍在使用的临时量。

## 6. ownership、效果与借用

### 6.1 capability 与 view 分离（§3.6）

- 类型：`Copy | Unique`（结构分类）。
- 值/view：`Owned | Borrowed | DestructionView`，记在 SemanticInfo。
- 每个 operand occurrence 记录 **`OperandUse`**（`Read` / `Borrow` /
  `Consume`，权威定义 effects.md §4）；声明侧是 **`BinderMode`**（§3.4，
  `Value` / `Move` / `Borrow`，源级 parameter/binder 契约）。全文只用这两
  个词汇，不再有 `UseKind = CopyRead | Borrow | Move` 这类第三套 kind。

```stilla
consume(move file);
```

```text
call(fnref consume, move(%B0))     // linearity 显式：实参 move，consume 具 consume 参数模式
```

### 6.2 效果维度摘要（HIR 视角，自含）

HIR 采用的效果模型是 **`Type × EvalPolicy × OperandUse × EffectSummary`**
四维正交。前两维在 HIR 里看：类型带 capability，EvalPolicy 见 §5.5；
每个 operand 的 `OperandUse = Read | Borrow | Consume`。表达式内部词法
（read/move/borrow local）不进入 EffectSummary——它们是 ownership/数据流
维度。

EffectSummary 记录一个表达式**与表达式外部语义状态的交互**：

```text
EffectSummary {
    accesses:         资源访问集合（Read/Write/Allocate/Release，按抽象语义域）
    may_trap:         bool    // 可能异常终止，含 panic
    may_diverge:      bool    // 可能发散（非终止调用 / 递归）
    nondeterministic: bool    // 两次求值结果可不同
}
```

要点（权威定义在 companion 文档，此处给出 HIR 使用所需的结论）：

- **effect 层中 panic = trap**：都置 `may_trap = true`；运行时都跳过销毁。
  不改变 Runtime/Core 的指令、诊断与终止行为。
- **摘要不跟踪 `may_return_normally`**：正常返回是默认假设；后缀 DCE 由
  独立 must 事实 `never_returns`（签名 `-> never` 或结构推导）恢复。
- **may-摘要遗忘顺序**：顺序组合 `E ; F` 与候选 join `E ⊔ F` 当前公式
  相同（`;` 与 `⊔` 同式、摘要层可交换）。这只说明摘要不携带顺序信息，
  程序级交换仍只由 `reorderable` 查询放行，不得据「摘要相等」推断。
- `effect_transfer` 组合：callee 表达式求值 → LTR 实参 → 所得 callable 的
  `effect_bound`；函数体摘要含正常退出清理；当前 full-expression 清理由
  边界计入一次。间接调用、缺失摘要、缺失 host metadata 一律 `Top`。
- 递归函数在 call-graph SCC 上求 least fixpoint，递归 SCC 保守 seed
  `may_diverge`；任何 HIR 变换后摘要失效并重算。

**Typed-opcode 的静态效果行**（数值 trap 语义只写一处，随 Runtime）：

```text
add.i32 / mul.i32 / add.i64 …        {}               // wrapping、无 trap
div.i32 / rem.i32                     MayTrap          // 仅除零（min/-1 回绕）
div.i64                               MayTrap          // 除零 + int64_min / -1
rem.i64                               MayTrap          // 仅除零（min rem -1 = 0）
u32/u64 div 与 rem                     MayTrap          // 仅除零
div.f32 / div.f64 / rem.f32 …         {}               // IEEE 754，永不 trap
num_cast                               {}               // LLIR cvt，永不 trap
any 恢复（any → T 不匹配）              MayTrap          // invalid any recovery
host binding 调用（call → syscall）     TOP 或 host metadata
```

**派生查询（不存派生 bool；每个都组合 effects × uses × capability/view ×
ownership 门，缺一不可）：**

| 属性 | 判定要点 |
| --- | --- |
| `total` | `!may_trap ∧ !may_diverge` |
| `observable_effect_free` | 无 `Write/Allocate/Release`、无未知资源；读默认非可观察（Q 不在此判定内） |
| `discardable` | `total` + 无可观察效果 + 清理上下文下 `discard_view(observed_effect) == Pure`（忽略 Q）+ ownership 门——**不要求 !Q** |
| `duplicable` | `discardable` + 结果 Copy + operand 全 Read + **无 Q**（求值可重复） |
| `speculatable` | `total` + 无有序/可观察效果 + **无 Q**；**上下文属性**：相对移动目标（effects.md §10.5） |
| `reorderable(a,b)` | **位置上下文**：sibling 对 + 父 EvalPolicy（effects.md §10.5 的 `canSwapOperands`/`canMove`）；输入是资源无冲突 + 无顺序可观察差异 |
| `seg_safe` | Copy + total + 无可观察效果 + 无 Q（结果稳定）+ cleanup 安全 + 递归子树同判 + ownership 门 |

**强约束**：`move.effects == {}` **不**使 move 变得 discardable /
duplicable / speculatable——每个公开查询都要组合 effect、operand uses、
结果 capability/view、ownership 可用性与 lifetime 栅栏，缺一不可。
`speculatable` / `reorderable` 两行是**上下文属性**（能否 speculate /
交换取决于相对「移动到哪里」：目标位置的 effect / borrow / trap / FE
屏障与父 EvalPolicy），API 形如 `canMove` / `canSwapOperands`，不是
unary/binary 谓词；此表仅为可读性简写，权威定义见 effects.md §10.5。
**Q 与可观察交互分离**（effects.md §10.1）：`discardable` 不要求 `!Q`（
`let x = clock.now() in 0 → 0` 合法，结果未使用）；`duplicable` / CSE /
speculate / move 要求 `!Q`。资源读是否可观察是 host 声明项（默认读非可
观察，§13），不是编译器的语言层假定。

### 6.3 move / drop 显式，且是 SEG 禁区

`move x` 在机器层往往什么也不做，但 HIR 层**必须保留**：对 Unique 它的
语义是 owner 转移 + 源 dead（whole-owner 规则，Static Semantics；
Types & Ownership）。use-after-move 被 checker 拒绝后 HIR 不再产生
它，但 `move`/`drop`/consuming match 的**节点身份**是 drop planning 与
CFG lowering 的输入。

```text
move / drop / consuming match    →  SEG 禁区（v1 起就是）
```

### 6.4 区分「无 trap/无效果」与「可丢弃」是必须的

```text
let B0: i32 = div.i32(1i32, %B1) in 0i32   // B0 未使用；%B1 == 0i32 时 div trap
```

dead-let 的规则因此自动正确（不必特判 `/`）：

```text
let Bk: ty = v in body  →  body
    若 Bk ∉ FV(body)  ∧  discardable(v)
```

由此还推出几条保守原则：

- **Copy 结果 ≠ 操作安全**：纯 Copy 输出只说明结果可复制，不说明求值无
  效果/无 trap。`field_get` 之类在**借用的 Unique owner** 上取值时，结果
  虽 Copy，其合法性仍取决于 owner 的借用 lifetime（Types & Ownership）与 view——每个公开合法性查询都要组合上述门，不能只看结果类型。
- **代数 rewrite 的合法性一律按 typed opcode + 具体语义域判定**（integer
  wrapping、除法 trap、IEEE 754、`str` 拼接各不相同，见 §7.2），SEG 规则
  不带「通用 BinaryOp」。
- **λ 创建效果与潜在调用效果分离**：λ/fn_ref 的**创建**无效果、total
  （不捕获，Core）；`call` 先组合 callee 表达式与 LTR 实参的求值
  效果，再组合 callee 的 `effect_bound`。直接调用用 callee 摘要；间接调用
  v1 取 `Top`。这让 `let f = fn(x){...} in ...` 中创建本身可自由移动/复用，
  而调用保持效果边界。

### 6.5 module_const 不是字面量

模块常量有运行时语义：模块 storage 与初始化（Runtime，module init
按声明序求值）。因此：

- 模块路径在 resolution 后解析成 `module_const(ConstId)` /
  `fn_ref(FuncInstanceId)`，**不再**走 `field(field(...))` 值流（模块值
  不能进入普通局部值流，Core）；
- 但 `module_const` **不自动是编译期字面量，也不自动 total**：读它依赖
  module init 已按 schedule 执行。`ModuleConst(C)` 是一个 EffectResource：
  函数摘要里的 `Read(ModuleConst)` 集合直接驱动 Core 的两条对称规则
  （初始化顺序限制与 teardown 限制，均为跨函数 transitive；含完整销毁链
  与未知目标保守）。只有该 const 求值已由 constant folding 具体化、且无
  可观察的初始化依赖时，才可在 SEG 内折叠；v1 保守地**不**在 SEG 里碰
  `module_const`。

## 7. 核心 Op 清单与类型专门化

### 7.1 v1 核心 op 表

下表为 v1 类别 1 的核心 opcode（§3.5，单名；typed 实例按 `opcode.rep` 拼写，
见 §7.2）。

| 类别 | HIR op | 说明 |
| --- | --- | --- |
| 原子 | `const` | 编译期常量（按 TypeId） |
| 原子 | `local` | `BinderId` 引用 |
| 原子 | `fn_ref` | 单态函数引用 |
| 原子 | `module_const` | 已解析模块常量（见 §6.5） |
| binding | `let` | operand + 单 binder region |
| sequencing | `seq` | 保证求值顺序（作用于副作用节点序列） |
| function | `lambda` | 参数 region（不捕获，见 §5.3） |
| function | `call` | callee + 有序 operands（LTR） |
| control | `if` | cond + 两个惰性 region |
| control | `and` / `or` | 短路分支：cond + 两个惰性 region（与 `if` 同构；M1a 修订：保留为独立行而非 `if` 简写，见 §5.5 注） |
| control | `match` | scrutinee + arm regions（pattern binders 见 §5.4） |
| aggregate | `struct_make` | nominal 构造 |
| aggregate | `field_get` | 字段读取（view 传播见 §6.4） |
| aggregate | `variant_make` | union variant |
| aggregate | `tuple_make` | tuple |
| aggregate | `list_make` | list |
| ownership | `move` | whole-owner consume（显式，SEG 禁区） |
| ownership | `borrow` | 借用视图 |
| ownership | `drop` | 显式销毁（SEG 禁区） |
| dynamic | `any_pack` | T → any |
| dynamic | `any_cast` | any → T |
| conversion | `num_cast` | 数值转换 |
| runtime | `panic` | terminating op |

消解清单（**不**保留到 monomorphic HIR）：`using` 别名、import 语法、泛型
语法、source name、type alias。

host 绑定与 stdlib 模块成员不是 op：resolution 后是类别 3 的 call 目标
（host binding → `syscall`，§7.4）；intrinsic 在 canonical HIR 无表示
（Intrinsics）。

### 7.2 monomorphic 后类型专门化

不用通用 `BinaryOp { op: Add, lhs, rhs }`。monomorphic HIR / SEG 视图里
opcode 本身带 rep——typed 实例拼作 `opcode.rep`（类型后缀，同 LLIR 指令名）：

```text
add.i32  add.u32  add.i64  add.u64
div.i32  div.u64            // trap 行为不同（Runtime）
add.f32  add.f64            // IEEE 754
```

数值语义不是一致的（integer wrapping、除法 trap、IEEE 754 各不相同），所以
每个 rep 是注册表里的独立实例。字符串拼接不是 opcode 族：它是 stdlib 模块
函数 `string.concat`（类别 3 的 call 目标）。类型专门化后的实例让 rewrite
**applicability**（代数/值前提层）判定最简单——适用不适用直接在符号上写
死，如 `add.i32` 可交换；`div.u64` 参与化简需带该类型的 trap 前提（仅除
零）；溢出前提只属 `div.i64` 的 `int64_min / -1`。它与 operational
legality（discard/duplicate/reorder/effect/ownership，由派生查询判定，
legality 引擎不 switch opcode）分开，两层见 effects.md §10.3。静态效果行
见 §6.2 表。

### 7.3 canonical TypeId 与 alias 展开

alias 在进 SEG **之前**彻底展开：SEG 中不出现 `UserId` 与 `int32` 两个
类型并存（若 `UserId` 是 transparent alias）。泛型特化后
`Option[int32]` 直接有一个 canonical TypeId（§3.8）。

### 7.4 模块成员解析为定义 Id

模块值不能进入普通局部值流，只能存在于 module-level const（Core）。
因此 `std.math.sqrt` resolution 后直接是 `fn_ref(FuncInstanceId)`（或模块
常量为 `module_const(ConstId)`），host binding 解析为专用的 host binding Id
（§3.5 类别 3；HIR 层不展开，AIR/LLIR 投影为 `syscall`），普通 `field_get`
只处理真正的 struct 值。HIR 因此干净很多——但要按 §6.5 保留 module init 语义，不能把
`fn_ref`/`module_const` 当无初始化依赖的裸指针。

> **M1a 修订（随 S6a 落地；§4.8 文本不承载）**：dotted 模块值路径穿过
> **module-valued 成员**时（`lib.math.sqrt`——`math` 是 `lib` 的 module 值成员，
> 语料无 ≥3 段路径，S5 门禁未覆盖），直降 `cfg_lower_path.lowerPathValue`
> 逐段重放 `module_ref` + 每 hop 一次 `load_member`（module 身份经 AIR 传递，
> air.md §7），**不是**静态跳到最终模块。HIR 在值位叶（fn_ref/module_const/const）
> 记录**已解析访问路径** `ExprNode.access_hops`（有序的中间 module 值成员：
> 属主模块索引 + 成员名；首 hop 的模块即基座 `module_ref` 所指），HIR→CFG
> 依序重放同款 `load_member` 并把 module_of 记到每个结果上；最终成员的行在链尾
> 值上装载，**绝不新发**最终模块的 `module_ref`。调用位不受影响（直降直接调用
> 按 qname，无行装载）。结构校验限制 path 只挂 const/fn_ref/module_const 叶；
> 文本形式不携带 hop 身份（printer 显式拒绝，绝不静默丢弃）。
>
> **M1a 修订（随 S6a 落地；§7.2 typed 行补齐）**：`byte` 无算术（checker 拒），
> 唯一数值运算是比较，经 u32 家族降级；typed 行补 `lt/le/gt/ge.byte` 四行
> （eq/ne.byte 已在 S4 登记），套件 byte 比较缺行即报未注册。

## 8. SEG 桥与重写合法性

### 8.1 Island 模型与准入谓词

不把整个 HIR 塞进同一个 e-graph。`SegRegionOptimizer` 寻找 SEG-safe
island。准入入口是两个条件（不再 switch(op)）：

```text
op(e).seg_encoding 已注册        // has_seg_encoding
&& isSegSafe(ctx, e)             // 派生查询（§6.2）
```

```text
isSegSafe(e)  ==
    type(e) 及其所有子值 capability == Copy
    && total(e) && observable_effect_free(e)     // §6.2 派生
    && 无 nondeterministic（Q = 0：island 需结果稳定，饱和/抽取才能合并与复用）
    && e 的所有 operand 均非 Borrowed view        // ownership/lifetime 门
    && 对 lazy-branch op：每个可选 region body 亦满足本谓词（递归）
    && e 不跨越 full-expression 边界
```

即 **supported、递归安全的纯 Copy island；不含 Unique / borrow / drop /
host 操作**。准入检查的是**递归属性**：嵌套 region 的 body 与 ownership
依赖都要纳入，不是只看根节点效果与 operand 类型。不属于任何 island 的
部分保持原样，SEG 结果只替换 island 内部。

**两类重写（本节的划分基准）**：上面的准入谓词只管辖**普通 SEG 重写**——
它必须是 full-expression-preserving（不跨 FE、不改求值次数与清理）。β 把
callee 体从「λ 值内部」搬进调用点区域，本质是**改变边界**的重写：它跨过
λ 体与调用点之间的 FE / 作用域边界。§8.1 的准入谓词对 β 不适用、也不应
适用——「SEG 不跨 FE」与「β 可用」不是同一个谓词的两难，而是两类重写：
普通重写默认 FE-preserving；**boundary rewrite 必须逐条声明
RewriteContract**（§8.4：scope 映射、FE 映射、cleanup 证明），由契约门
准入，不走 `isSegSafe`。e-graph 只有在为一条已声明契约的 boundary rewrite
而构建时，才把 call、λ 与 λ 体放进同一可匹配区域；其余会话一律只对
普通 island 饱和。

### 8.2 投影与抽取

```text
BinderId        -> Slot
Local(Binder)   -> var(slot)
Let             -> binder term
Lambda          -> binder term

encode_hir(e, scope) -> SEGTerm?
extract(eclass)      -> ExprId
```

不支持的 op 的 `encode` 返回 `None`，自然形成优化边界。

**extraction 注意**：SLOT 号只在单 island 内是局部身份。extraction 回
HIR 时：

- 需要**分配 fresh BinderId**（可在新开的 id 区间里，按 island 内 slot
  一一映射）；
- island 外的原 binder 引用不得与 island 内 binder 混淆；
- extraction 若想共享子项（CSE），必须 materialize 成显式 `let`（值复用
  一律走显式 let，见 §3.7），绝不产生隐式 memo 或重复的 effect 节点。

**extraction cost model**：v1 用**最小节点数 + 确定性 tie-break**（更小
ExprId / op 规范顺序），不用 per-opcode 权重——v1 规则集只做化简，size
与运行成本不背离；权重是 target 相关负债（同 op 在 LLIR 各目标成本不同），
留到引入「多节点换更快指令」的重写（associativity / strength reduction
随 SEG 范围扩大）再评估。cost 函数实现为 SEG 优化器侧独立函数，不进 op descriptor
（cost 是优化器事实，不是语言语义）；tie-break 确定性是 SEG 文本可比验收
的前提。

### 8.3 v1 重写规则集

| 优化 | v1 | 备注 |
| --- | --- | --- |
| α-equivalence | ✅ | SEG 自动提供（BinderId→Slot） |
| `let x=v in x` → `v` | ✅ | 同一 full expression 内最安全；跨 full-expression 需另证（§8.7） |
| dead let | ✅ | `x ∉ FV(body)` 且 `discardable(v)`（§6.4） |
| trivial let forwarding | ✅ | Copy |
| β-reduction | ✅ | **必须变成 `let`**；boundary rewrite，契约见 §8.4；实参限 Copy 且 discardable |
| η-reduction | ✅ | 严格限制（§8.5） |
| constant folding | ✅ | 按具体 TypeId |
| `x + 0 → x`、`x * 1 → x` | ✅ | integer / safe numeric |
| integer bit identities | ✅ | wrapping 语义好处理 |
| constant `if` | ✅ | |
| known variant `match` | ✅ | Copy-only first（§8.6） |
| struct projection | ✅ | pure Copy struct |
| tuple projection | ✅ | |
| CSE-style sharing | extraction 后 | SEG 不强求直接产生 let；由 extraction materialize（§3.7） |
| associativity | ❌ v1 | 搜索空间爆炸 |
| commutativity | 谨慎 | 仅 total 且不 trap 的 op（如 `add.i32`），按 §7.2 判 legality |
| Unique rewrite | ❌ | 后续（需线性等式系统） |
| host calls | ❌ | |
| `drop` | ❌ | |
| consuming match | ❌ | |
| panic/trap 重排 | ❌ | |

### 8.4 β-reduction 必须生成 let

Stilla 是 strict call-by-value，实参恰好一次、LTR（Runtime）。数学的
`(λx. body) arg → body[x:=arg]` **不能直接用**：

```stilla
(fn(x) { x + x })(foo())
```

直接替换成 `foo() + foo()` 就错了（`foo` 求值两次）。正确的是：

```text
call(fn (B0: i32) => add.i32(%B0, %B0), call(fnref F1))
    →  let B0: i32 = call(fnref F1) in add.i32(%B0, %B0)
```

多参数 λ 保持 LTR，逐参数嵌套：

```text
call(fn (B0: i32, B1: i32) => mul.i32(%B0, %B1), call(fnref Ff), call(fnref Fg))
    →  let B0: i32 = call(fnref Ff) in
       let B1: i32 = call(fnref Fg) in
         mul.i32(%B0, %B1)
```

绝不许交换成 `let B1: i32 = call(fnref Fg) in …`。

**β 是 boundary rewrite，须声明 RewriteContract。** β 把 λ 体从 callee
内部语义边界搬进调用点，与 §8.1 的普通 island 重写（默认
FE-preserving）不是同一类。因此 β 以**显式契约**进入（effect 面见
effects.md §10.4，HIR 侧的映射与证明如下）：

```text
RewriteContract {
    preserves_eval_count: bool,       // 实参恰好一次（β→let 保证）
    preserves_order:      bool,       // LTR：逐参数嵌套 let，不交换实参序
    maps_scope:           BinderMap,  // λ 体 binder → 调用点 fresh binder
    maps_full_expr:       FullExprMap,// λ 体 FE → 调用点 FE（逐条映射）
    preserves_cleanup:    CleanupProof, // 实参侧 + λ 体侧清理证明
}
```

β-to-let 的契约实例（v1 即满足）：

- `preserves_eval_count` + `preserves_order`：β→let 逐参数嵌套、LTR 保持
  （见上例），不复制、不重排实参；
- `maps_scope`：λ 参数与 λ 体内层 binder 全部映射为调用点区域新分配的
  fresh binder（§5.3 不捕获使映射无闭包逃逸）；
- `maps_full_expr`：λ 体的 full-expression 边界**逐条**映射到调用点——v1
  只对已证明 cleanup-free 的单表达式 λ 体做 β，其唯一 FE 并入调用点 FE
  的清理上下文；这一步是显式、受控的映射，不是跨栅栏的自动许可；
- `preserves_cleanup`：实参限 **Copy 且 discardable**（从根排除实参临时量
  的 destructor timing 变化）+ λ 体 cleanup-free（排除体侧清理）。

「校验器每次 rewrite 后重跑」是必要非充分——destructor timing 的变化
校验收不到，所以由**契约准入**兜底：契约每条由构造或证明给出，缺任一
条即拒绝该 β。多语句 / 带清理 λ 的 β 随 `drop_effect` 精化后再提供契约
实例（effects.md §10.4），不作为 v1 行为宣传。

### 8.5 η-reduction 的限制

Stilla 函数单态、函数值是 Copy、λ 不捕获，很适合 η：

```stilla
fn(x: float32) -> float32 { math.abs(x) }
```

```text
fn (B0: f32) => call(fnref abs, %B0)     →   fnref abs
```

前提：

- exact same fn type（含参数模式 exact same）；
- `x` 在 callee 中不自由（本就不捕获，天然满足）；
- callee 求值 total（无效果、无 trap）。

v1 只允许 `callee = FnRef`。不捕获只能说明 callee 内部不含对 `x` 的自由
引用（非捕获 ≠ 参数必然缺席），单靠「λ 不捕获」无法排除更一般的 callee
表达式在 η 展开后改变求值行为；限到 FnRef 最简单且安全。

### 8.6 match 高层保留与 consuming match 排除

`if / match / block` 在 SEG 前**不要过早 lower 成 CFG**——它们本身是
表达式：

```stilla
match Some(3) {
    Some(x) => x + 1,
    None => 0,
}
```

即 `match` 一个已知变体：`match(…){ Some(B1) => add.i32(%B1, 1i32), None => 0i32 }` 可
化成 `let B1: i32 = 3i32 in add.i32(%B1, 1i32)`，再化成 `4i32`。一旦先 lower 成
basic blocks + branch + phi，这种优化反而复杂很多。

但：

- **match Copy 值：✅ 进 SEG**（known variant 化简 → let）；
- **borrowed Unique 的 match：❌**（借用在分支间分流）；
- **consuming match（`match (move file)`）：❌**——ownership transfer，
  条件路径上的 move/drop 构成 maybe-unique 状态（Types & Ownership），编译器必须在未消费分支 join 前插入 destruction；v1 不做，
  留待线性等式系统。

### 8.7 完整例子

```stilla
let result =
    (fn(x: int32) -> int32 {
        x + 0
    })(value);

result * 1
```

HIR（value 为函数参数 B0；init 与 `result * 1` 各是一条 full expression，FE1/FE2）：

```text
let B1: i32 =
    call(fn (B2: i32) => add.i32(%B2, 0i32), %B0)   // FE1：整个 init
in mul.i32(%B1, 1i32)                                 // FE2：result * 1
```

SEG 按 full expression 分岛。FE1 内（init，call 的临时量与合成 binder
都在同一边界里）：

```text
call(fn (B2: i32) => add.i32(%B2, 0i32), %B0)
  →  let B2: i32 = %B0 in add.i32(%B2, 0i32)     // β → let：boundary rewrite（§8.4 契约实例：
                                                 // maps_full_expr λ 体 FE → FE1；cleanup-free
                                                 // 单表达式体 + Copy 实参）
  →  let B2: i32 = %B0 in %B2                     // %B2 + 0 → %B2（普通 island 内）
  →  %B0                                          // let B2=%B0 in %B2 → %B0（同 FE 内）
```

FE2 内（`result * 1`）：

```text
mul.i32(%B1, 1i32)  →  %B1            // %B1 * 1 → %B1
```

优化后 HIR（两条 full-expression 边界原样保留）：

```text
let B1: i32 = %B0 in
    %B1
```

把最外层 `let B1: i32 = %B0 in %B1` 折叠成 `%B0` 会跨越 FE1/FE2 两条
full expression，把 `result` 的销毁/别名语义并入后续表达式——对纯 Copy
的 int32 绑定没有 destructor timing 影响，但 v1「不跨栅栏」的硬边界下，
这一步列为**单独、被证明安全后才放开**的变换（规则表里 `let x=v in x → v`
一行在同一 full expression 内直接可用；跨边界形式需要这份证明），不作为
v1 SEG 的抽取结果宣传。

整个过程：没改 source binding identity；不需要 α-rename；不需要 de Bruijn
shifting；没破坏 call-by-value（β 走了 let）；没改变求值次数；优化始终
停在 full-expression 边界内。

## 9. HIR → CFG/AIR lowering 契约

Monomorphic（或 SEG 优化后）的 HIR 落到现有 CFG AIR。原则：**把 HIR 的
语义不变量翻译成 CFG 结构，不重新发明 CFG 层的职责**。

| HIR 结构 | CFG 发射 |
| --- | --- |
| 有序 `let` / `seq`（LTR operands） | 块内按序指令序列；同一 full expression 内的临时量沿用 per-expression 临时栈在表达式尾反向销毁（销毁计划由 CFG 侧重建，见 §5.6 分界） |
| `if` / `match` 的惰性 region | 条件分支；分支 join 处 phi / 控制汇合；pattern binders → 解构序列（`unpack`、`read_tag` + switch 等现有 lowering） |
| 作用域出口的普通销毁 | normal-path cleanup：scope-end drop（definitely-owned）与 join 处 maybe-unique 的边 drop，沿用现有 conditional destruction 机制 |
| `panic` / trap 路径 | **不做清理**（Static Semantics Panic and traps；现有 `trap` terminator 无 drop） |
| `move` / `borrow` / `drop` | 直接映射现有 AIR ownership op（`move`、`borrow`、`drop`），不优化掉 |

**保持不变的既有责任**：

- post-CFG **drop lowering**——HIR 层只做 drop 的计划/标注，结构/元组/box/
  union 的静态展开仍在 CFG 之后；
- **LLIR lifecycle**（lifecycle plan → edge blocks → 每边 kill 计划）——
  消费的是 CFG，与 HIR 无关。

因此 HIR 引入后，AIR 本身、CFG validator、optimizer 都不需要
动；改的是「进 CFG 之前」的那一段。

## 10. 验证与测试

### 10.1 HIR 自身不变量（validator）

- **作用域**：region params 只在 root 子树可见；`let` init 在其 region
  之外；无约束 binder 引用（不捕获即结构成立）；同一 region 内无重复
  BinderId；extraction 产物无 stale slot。
- **树形（无 DAG）**：同一 `ExprId` 不重复出现在多个 operand / region
  切片（§3.7）。
- **full-expression 栅栏**：每个节点归属一个 FullExprId；SEG 重写不跨
  边界；A-Normal Form 合成 let 不推迟临时量销毁；清理 token 的
  origin_expr 与登记一致（变换后重映射、registration_index 保持相对销毁
  序，effects.md §11.2）。
- **view/ownership 数据流**：每个节点按 operand view 与 OperandUse 给出一致
  的 view；`move` 后源 dead；borrow 不外逃其 lifetime。
- **效果与求值序**（分两级，对应 §11 的落地档）：**结构校验（M1a 起，
  效果分析关闭时）**——节点摘要为合法占位 `Ready(Top)` 或与 descriptor
  的 `effect_transfer` 一致即可；EvalPolicy 与结构一致（惰性 region 不在
  未选中时求值）。**已启用分析校验（M1b 起）**——节点摘要须与
  `effect_transfer` 的递归汇总一致；与函数 SCC fixpoint 摘要一致的要求
  只在 SCC 推导启用（M2b）后生效。`Top` 是合法保守值：缺省 / 递归 / 未知
  目标摘要取 `Top` **不等于**与最精确 transfer 不一致的错误。不存派生
  bool。
- **registry 完整性（validateRegistry）**：启动时对 OpRegistry 跑 §3.5 的
  检查——每个 op 必有 semantics；可出现在 monomorphic HIR 的 op 必有
  lowering；`seg_encoding != null` 时必有对应 SEG 契约；typed-op effect
  行完整；printer/parser 形状对称。

### 10.2 测试分层与文件放置

按 AGENTS.md 的分区约定（白盒在属主模块 `test{}`，黑盒/跨模块在对应
`*_tests.zig` 并由 root.zig 导入）：

- HIR 构建与打印的白盒测试放属主模块；跨模块行为（AST→HIR→CFG 与现在
  AST→CFG 的语义等价）放新的 `hir_tests.zig` 黑盒文件；
- 不要长在 frontend_tests.zig 里：HIR 相关覆盖放进 hir 自有套件；
- SEG 相关测试放独立的 seg 套件，每规则一个定向用例 + 不变量断言
  （fresh binder、full-expr 不跨、无 effect 重复求值、无 borrow 进 island）。

### 10.3 语义等价回归

- 无 SEG 的 monomorphic HIR 落地验收 = 现有全部 suite（`zig build test`）
  不改语义地通过：同一输入，
  AST→HIR→CFG 的 AIR 与现在 AST→CFG 的 AIR 等价（文本 round-trip 可比较
  的输入先比；不可比的比解释执行结果）；
- 每个 SEG 规则用例同时验证「rewrite 后校验通过」与「求值次数/销毁顺序
  不变」——后者靠 §8.4 的准入限定，不由校验器单独保证。

## 11. 验收与落地范围

本文的验收按**落地档**划分——每档是本文所描述形态的一个可独立验收的
里程碑，前档通过才进入后档。效果分析强度沿档递增：M1a 只把效果字段
**带到** HIR（允许占位、无效果判断），M1b 落地效果基础设施本身，M2 才
以派生查询驱动前端变换与 SEG。档位编号（M1a / M1b / M2a / M2b）用于实现
与评审讨论的稳定指称。

**M1a — 结构 HIR（monomorphic、无 SEG、无效果分析）**：以现有 checker
注解为输入，覆盖**全部现有语言形态**：AST → HIR（规范形：
binder/region/pattern 统一、full-expression 标注、OpDescriptor 骨架、
SemanticInfo 携带 ownership view）→ HIR→CFG lowering。本档**不实现任何
效果分析**：`SemanticInfo.effect` 允许 `Ready(Top)` 占位或分析关闭，
无 effect-based 优化；§10.1 只跑结构校验。验收 = §10.3 的语义等价门禁
（现有 suite 全绿 + AIR 文本/解释执行等价）——**本档唯一验收是证明 HIR
是 semantics-preserving frontend seam**；等价门禁稳定后，SEG 与效果优化
才有意义。SEG 不在此档内。

**M1b — 效果基础设施**：落地 effects.md §14 的最小效果模型（MayTrap 含
panic、MayDiverge、nondeterministic、`Host(resource, Read/Write)`、
`ModuleConst(Read)`；OperandUse 独立；不跟踪 `may_return_normally`）与
固定乘积格、`Pending`/`Ready` 门、typed-opcode 基础效果行、
`effect_transfer`、cleanup-aware 查询门（§6.2，effects.md §10–§11）。
函数摘要只做**直接调用**（非递归）的基本传播；递归 / 缺失 / 未知目标
一律保守 `Top`。函数 SCC fixpoint（effects.md §8.2）与 module-const
初始化/teardown 的摘要化检查（effects.md §7）**不在本档**（归 M2b）。
精确 drop 摘要可后置，但**未知 cleanup 阻止删除、浮动、复制与 SEG
准入**，不能只凭结果 Copy 放行。本档验收 = effects.md §14 的 **MVP 前置
条件**齐备并通过不依赖消费者 pass 的代数/law 测试（Bottom/Pure/Top 与
组合、`;`/`⊔` 同式与摘要层交换、Pending/Ready 门、cleanup 拒绝等）；
「dead-let / selective A-Normal Form / SEG-safe 三判定无 `switch(op)`
特判」的验收属 M2b。

**M2 — 优化消费**：

- **M2a（SEG v1 规则子集）**：`const / local / let / lambda / call /
  if / struct_make / field_get` + numeric ops；规则只上 **β（→ let，
  boundary rewrite，契约 §8.4）+ let 化简 + constant folding + integer
  代数化简**（§8.3 的 ✅ 首行子集；β 的 λ 体按 §8.4 限已证明
  cleanup-free 的单表达式）；island 准入（§8.1）+ 替换后局部再验证
  （§2.4）；extraction cost 用**最小节点数 + 确定性 tie-break**（§8.2）；
  默认关，编译时间预算另测。
- **M2b（摘要化消费者）**：dead-let / selective A-Normal Form / SEG-safe
  三个判定以派生查询驱动、无 `switch(op)` 特判（effects.md §12）；函数
  SCC fixpoint（effects.md §8.2）驱动 Core 的初始化/teardown 检查，
  替换 checker 特设分析。
- **match 进 SEG**：Copy-only、known variant → let；验证架构在更大语言
  面上成立（并入 M2a 或紧随其后）。

**再后**（后续方向，超出上述范围，随实现需求另行定义）：

- Unique / consuming / borrowed 情形进 SEG（需线性等式系统）；
- 「先建 Typed HIR 再特化」的 Target 形态（monomorphization / ownership
  检查在 HIR 上完成）；
- SEG 从可选变为默认，并测编译时间预算。

**match 进 SEG**：Copy-only、known variant → let；验证架构在更大语言
面上成立。

**再后**（后续方向，超出上述范围，随实现需求另行定义）：

- Unique / consuming / borrowed 情形进 SEG（需线性等式系统）；
- 「先建 Typed HIR 再特化」的 Target 形态（monomorphization / ownership
  检查在 HIR 上完成）；
- SEG 从可选变为默认，并测编译时间预算。

## 12. 开放问题

本文各节的取舍已成正文规范：HIR 树形禁止 DAG（§3.7）、extraction cost 用
最小节点数 + 确定性 tie-break（§8.2）、TypeId 复用 `cfg.Type`（§3.8）、
效果模型在 §6.2 的自含摘要及其开放问题在效果模型文档
（[effects.md](effects.md)）中
定稿。其余本文级开放点随实现推进（HIR→CFG 的等价格门禁暴露任何表述
缺口时）按需补充。
