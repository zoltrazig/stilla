# Stilla Effects System — 语义交互摘要模型

> **Status：效果模型与消费者已实现。**
>
> - **已实现**：固定乘积格与派生查询、函数摘要 SCC least fixpoint、精确
>   `drop_effect(T)` 全链、module-const 检查、`StillaExecution` 三态与符号键
>   host 声明解析、间接调用目标收窄（§9.2 局部 fn-ref 传播）、β 的 effectful
>   实参（§10.4，契约下放开求值次数 / 序 / scope / FE / cleanup）、
>   `RewriteRule` / `Requirement` 与 `RewriteContract` 类型（§10.3–§10.4，
>   `passes/rewrite_contract.zig`；首批实例 β 与 dead-let，随后是 `ruleLet` 的
>   `let_dead` / `let_forward` / `let_atom` 三分支，以及 η 与 selective ANF）。
> - **消费者**：dead-let + selective ANF + `never_returns` 后缀删除
>   （`--simplify`，默认关）、SEG v1（可执行文件默认开、`--no-seg` 关；库默认关、
>   `Options.seg` 开启）。
>
> 配套文档：使用该模型的 IR 见 [hir.md](hir.md)。本文自含效果模型所需的全部
> 定义；两者重叠的概念（求值序、值使用、效果）在本文给出权威定义，[hir.md](hir.md) 保留
> 一份便于阅读的自含摘要。
>
> 规范依据（追踪 v1.3 草案）：Core（Module Constants、不捕获、顺序无关与互递归）；
> Types & Ownership（Copy/Unique、参数模式、借用、临时量）；Runtime（初始化与
> 逆序 teardown、求值序、确定性销毁、trap 与数值行为）；LLIR Instruction Set
> （`cvt` 转换语义）；air.md（drop 语义与校验）。

## 1. 问题

### 1.1 一位 `pure / impure` 不够

把表达式标成 `pure / impure` 两位，再派生一批互相打架的布尔标志
（`is_pure`、`has_side_effects`、`can_speculate`、`is_safe_to_remove`、
`can_duplicate`），每加一个优化 pass 就要补一套规则，最终只能靠
`switch(opcode)` 白名单硬编码。Stilla 需要区分的东西远多于一位：

| 需要区分 | 例 | 单一位表达不了的原因 |
| --- | --- | --- |
| trap / panic 与正常返回 | `10 / y` 除零 trap | 需知求值**可能异常终止**，且异常终止时不跑清理 |
| host 访问的资源域 | `os.read` 与 `audio.get_volume` | 同为 host 调用，写文件与读音频可交换性不同 |
| module constant 依赖方向 | 初始化 / teardown 读较早 / 较晚常量 | Core 规则**跨函数 transitive**，按依赖序判定 |
| drop 是否可观察 | 带 drop hook 的临时值 | drop 有可观察效果，不等价于「无副作用」 |
| 求值顺序 | `a() + b()` 必须 a 先 b 后 | 语言语义（LTR、恰好一次），不可从效果推 |
| 是否非确定 | `clock.now()` | 两次求值结果可不同，影响 CSE / 复制 |

### 1.2 想统一的那些散落规则

1. 求值顺序、trap/panic、host 调用、module-const 依赖、调用摘要不再各自特判；
2. Core 的模块初始化与 teardown 两条对称规则由同一份函数摘要驱动；
3. dead-let、selective ANF、SEG-safe、CSE/DCE 的合法性全部**派生**出来，而不是
   `switch(op)` 白名单。

### 1.3 非目标

- **不做 source-level effect type**（如 `!{IO}`）：效果摘要只是编译器内部的
  metadata / refinement，不进入语言类型。
- **不做低层内存效果**（别名、store buffer）：资源是**抽象语义资源**，不是地址。
- **不做可扩展的通用 lattice 引擎**：用一套固定乘积格，只覆盖有限的 mode 与
  `Host(resource, Read/Write)` + `ModuleConst(Read)`。

## 2. 解决方案概览

### 2.1 一句话

> EffectSummary = 一个表达式与**表达式之外**的语义状态发生了哪些交互。

表达式内部的词法 / 数据流（read / move / borrow local）**不进入** EffectSummary
——它们属于 ownership / 数据流维度（Unique 至多 move/drop 一次、borrow 不转移
ownership，由独立维度负责）。

### 2.2 一个 op 的语义是四个正交维度

```text
HIR semantics(op) =
    Type                // capability（Copy/Unique）与具体类型
  × EvalPolicy          // 求值顺序：语言语义（§3）
  × OperandUse          // 每个 operand 的值使用 / ownership（§4）
  × EffectSummary       // 与表达式外部语义状态的交互（§5）
```

| 维度 | 回答什么 | 归属 | 关键区分 |
| --- | --- | --- | --- |
| `Type` | 值能复制吗、具体类型 | 类型系统 | Copy / Unique |
| `EvalPolicy` | 子表达式以什么顺序、求值几次 | op descriptor | 语言语义，与效果正交 |
| `OperandUse` | operand 是被读、借用还是 consume | operand 位 | 每个 operand 一个 |
| `EffectSummary` | 求值会与外部状态交互吗 | 节点 interned 摘要 | 资源访问 + 控制位 |

两个正交性例子：

- `move.effects == {}` 完全合理：move 的重要语义是 `OperandUse = Consume`
  （linearity 属于 ownership，不是 runtime effect）；
- `builtin.print(...)` 是 runtime effect，但未必 consume 参数。

### 2.3 EffectSummary 长什么样

```text
EffectSummary {
    accesses:  AccessSet,     // 资源访问集合（∅ / All，见 §5.4）
    may_trap:  bool,
    may_diverge: bool,
    nondeterministic: bool,
}

EffectAccess { resource, mode }     mode = Read | Write | Allocate | Release
```

资源是抽象语义域而非地址（`ModuleConst(C)`、`Host(域)`、`Runtime(域)`、
`Extension(ProviderId, ResourceId)`、`HostAny`（host 资源通配）、`Top`）。典型行：

```text
builtin.print(...)   Write(Host.Output)
os.open(...)         Allocate(Host.FileSystem) + Write(Host.OS) + MayTrap
clock.now()          Read(Host.Clock) + nondeterministic
module.foo           Read(ModuleConst(foo))
panic(...)           may_trap = true
host.unknown(...)    TOP
```

### 2.4 由此派生的优化属性

模型只存**事实**（EffectSummary + 派生所需的类型 / use / view），不存
`is_pure = true` 这类布尔；所有优化属性由查询函数推导（详表见 §10.1）：

| 属性 | 判定要点 |
| --- | --- |
| `total` | `!may_trap ∧ !may_diverge` |
| `observable_effect_free` | 无 `Write/Allocate/Release`、无未知资源；读默认不构成可观察交互 |
| `discardable` | `total` + 无可观察效果 + 清理上下文下 `discard_view(observed_effect) == Pure` + ownership 门——**不要求 !Q** |
| `duplicable` | `discardable` + 结果 Copy + operand 全 `Read` + **无 Q** |
| `speculatable` | `total` + 无有序 / 可观察效果 + **无 Q**；**上下文属性** |
| `reorderable(a,b)` | **位置上下文**：sibling 对能否交换由父 EvalPolicy + operand 位判定 |
| `seg_safe` | Copy + total + 无可观察效果 + 无 Q + cleanup 安全 + 递归子树同判 + ownership 门 |

每个查询都组合「效果 × operand uses × 结果 capability/view × ownership /
lifetime 门」——`move.effects == {}` **不**使 move 变得 discardable /
duplicable / speculatable。`speculatable` / `reorderable` 不是表达式自身的
unary / binary 属性：查询须参数化目标位置（§10.5 的 `canMove` /
`canSwapOperands`），本节表格只为可读性简写。

### 2.5 模型消费方与文档导航

- **dead-let / selective ANF / SEG 准入**：用 `discardable` /
  `can_float_as_tree` / `seg_safe` 派生判定，替代 `switch(op)`（§12）；
- **module constant 依赖检查**：用 `Read(ModuleConst)` 读集驱动 Core 两条对称
  规则（§7）；
- **优化重写合法性**：所有 rewrite 的效果要求走派生查询（§10.3–§10.4）。

阅读顺序：§3–§5（求值序、值使用 + 效果核心）→ §6（组合）→ §7–§9（module 依赖
与调用摘要）→ §10（派生查询）→ §11–§12（销毁可观察性与消费者）→ §13–§14
（host metadata 与范围 / 验收）→ §15（开放问题）。

## 3. EvalPolicy：求值顺序维度

Stilla 规定子表达式**恰好一次、从左到右**求值。`a() + b()` 即便
`effects(a) = effects(b) = {}`，语义仍是 a 先 b 后。求值顺序是**语言语义**，
效果摘要是**优化 legality 事实**，二者不互相归约。

```text
EvalPolicy =
    StrictLTR     // operands 按序恰好一次（call / add / struct / tuple / list …）
  | ShortCircuit  // and / or
  | Branch        // cond 先；只求值一个 region（if）
  | Match         // scrutinee 先；只求值一个 arm region（match）
  | Region        // region 体按需 / 延迟求值的其余情形（descriptor 自声明）
```

- **region 是惰性分支**：`if` / `match` 的 region 体只在被选中时求值；
  `call` 与聚合构造的 operands 全部求值且 LTR。两者合起来，求值顺序与次数由
  **结构**决定。
- **可交换是可证明的派生事实**：`reorderable` 可能证明某两个 operand 可交换，
  但语义默认仍保持 LTR；要利用交换的重写必须走显式的 `reorderable` 查询，不能
  用「两者摘要相等」推断。

## 4. OperandUse：值使用 / ownership 维度

每个 operand 声明一个 occurrence 级值使用模式。ownership 的 law（Unique 至多
move/drop 一次、borrow 不转移所有权）由独立维度负责，不进入 EffectSummary。

```text
OperandUse = Read | Borrow | Consume    // 一个具体 operand occurrence 如何消费值
BinderMode = Value | Move | Borrow      // 源级 parameter / binder 契约（[hir.md](hir.md) §3.4）
```

- `OperandUse` 是 operand 位的 occurrence 事实（每个 operand 一个）；
- `BinderMode` 是声明侧契约（move 参数 / consuming pattern 绑定为 `Move`、
  borrow 参数为 `Borrow`）。
- 两者分层，不再有第三套 `CopyRead / Move` 词汇。

```text
move         uses = [Consume]    effects = {}
borrow       uses = [Borrow]     effects = {}
add.i32      uses = [Read, Read] effects = {}
drop File    uses = [Consume]    effects = drop_effect(File)   // §11
```

结论：`move` 是 **linear effect** 但不是 **runtime effect**；`print` 是 runtime
effect 但不一定 consume。两者正交。

结果侧还有 capability / view 规则（Copy 结果、借用视图、销毁视图等），与
operand 的 use 共同构成 ownership 门，被 §2.4 的每个派生查询消费。本文不展开
view 的完整数据流——那是所有权系统的事；效果模型只要求在派生查询里**组合**
ownership 门。

## 5. EffectSummary：资源访问 + 控制摘要

### 5.1 结构

```text
EffectSummary {
    accesses: AccessSet,       // 规范化访问集合；∅ / All 见 §5.4
    may_trap: bool,
    may_diverge: bool,
    nondeterministic: bool,    // 同式两次求值结果可不同
}

EffectAccess { resource: EffectResource, mode: EffectMode }

EffectMode = Read | Write | Allocate | Release
```

控制摘要使用 **may 语义**——所有实际结果必须被收敛后的摘要覆盖。

**effect 层中 panic = trap**：二者都置 `may_trap = true`，运行时都不正常返回、
跳过销毁。此合并只服务于优化合法性，不改变 Runtime / Core 的指令、诊断或终止
行为；不另设 `may_panic`。

### 5.2 资源是抽象语义资源，不是地址

```text
EffectResource =
    ModuleConst(ConstId)                // 模块常量槽（§7）
  | Host(HostDomainId)                  // host 域：Output / FileSystem / Clock / OS / GPU …
  | Runtime(RuntimeDomainId)            // 运行时域
  | Extension(ProviderId, ResourceId)   // 扩展模块自注册的域
  | HostAny                             // host 资源的通配
  | Top                                 // 未知资源（TOP 摘要用）
```

资源间的关系不能只按 Id 判等——两个域是否重叠需要一张 alias / overlap 表
（§5.6）。

### 5.3 摘要层记法

`{}` **只表示 `Pure`**；`{ MayTrap }` 等简写是在 `Pure` 上增加可能效果（故除法
仍可能正常返回）；无条件 panic 的摘要即 `{ MayTrap }`。

### 5.4 乘积格、偏序、join/meet 与顺序 / 候选组合

**格与偏序。** 设 `K` 是已注册的有限资源 Id 集，`M` 是固定的四种 mode。每个
mode 的资源集合格为 `P(K) ∪ {All_m}`：普通集合按包含序，`All_m` 严格高于所有
普通集合（包括 `K` 本身），并覆盖未知 / 后续资源。
`AccessSet = ∏(m ∈ M) (P(K) ∪ {All_m})`，join/meet 按 mode 做并/交：
`All_m ∪ S = All_m`、`All_m ∩ S = S`。

行的排序只为规范化与 interning，**不表示执行顺序**。`Read(Top)` 是 Read 分量的
`All_Read`；缺失摘要直接使用完整 `Top`。资源 overlap 只影响冲突查询，不改变格
的包含序；普通域 Id 按标识集合计算，Top 才按通配规则计算。

```text
E = (A, T, D, Q)     A = accesses  T = may_trap  D = may_diverge  Q = nondeterministic

L = AccessSet × Bool × Bool × Bool
E ≤ F  iff  A_E ⊆ A_F 且每一布尔位 E_i ≤ F_i（false ≤ true）
E ⊔ F  = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
E ⊓ F  = (A_E ∩ A_F, T_E ∧ T_F, D_E ∧ D_F, Q_E ∧ Q_F)

Pure = (∅,   false, false, false)   // 格底，兼「已证明纯」
Top  = (All, true,  true,  true)    // 所有资源、控制与非确定性均未知
```

- `⊔` 是候选路径 / 目标的最小上界，`⊓` 是最大下界；二者满足交换、结合、幂等与
  吸收律。只有每个输入都覆盖实际行为时，meet 才能用于**合并独立证明**，不能拿
  meet 代替分支 join。
- 对当前分析固定有限的资源注册表与 mode 集，格为有限高度；新资源注册后须失效
  重算。未知资源始终保留通配。
- **meet 不进入业务 API**：`⊓` 的公式与格律保留给 law test（内部
  `latticeMeet()`）；优化 / 分析查询面只暴露 join、sequence、conflict 与投影。
- **摘要不跟踪 `may_return_normally`。** 正常返回是默认假设；`Bottom` 与
  `Pure` 同值，「推导下界 ≠ 已证明纯」的区分由 §8.2 的 `Pending` /
  `Ready(summary)` 状态机承担（不在格内）。后缀 DCE 的合法性由独立 must 事实
  `never_returns` 恢复——该 must 事实已落地（§10.1，hir_effects.zig 的
  greatest fixpoint），后缀删除在 M2b 消费者（hir_simplify.zig，`--simplify`）；
  摘要代数不变，`;` 合并仍保守并入后缀位。

**顺序组合与候选 join：语义角色不同，may-公式同式。**

```text
E ; F = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
E ⊔ F = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
```

- 访问集合、非确定性位与控制位都保守地并入整个后缀 / 候选，即使后缀不可达或
  候选未选中；它们只会阻止更多优化，也保留 module-const 依赖检查所需的保守
  读集合。
- **may-摘要遗忘顺序**：上式全由并 / 或构成，`E ; F == F ; E`——`;` 与 `⊔`
  同式、可交换、结合、幂等，`Pure` 是左右单位元兼格底。这只说明摘要不携带顺序
  信息，**绝不**表示两个程序可互换；程序级可交换一律由 `reorderable(a, b)`
  判定（§10.1）。
- descriptor 仍必须按 EvalPolicy 写出真实的组合结构（顺序用 `;`、候选用 `⊔`）：
  这是模型的保真性要求——未来引入顺序敏感事实时二者会再次分化。

组合法则：分支摘要为 `effects(cond) ; (effects(then) ⊔ effects(else))`；有限
callee 集用 join；有序 drop / cleanup 用 `;`。空 join（不可达）与空顺序（零步
执行）同值于 `Pure`。

**total 与最小代数验收例。** 正常终止、异常终止、发散覆盖全部执行结果，故对
已完成且保守的摘要，`total = !T ∧ !D` 保证必然正常终止；`Pending` 中间近似不能
参与此查询（查询失败关闭，§8.2）。

```text
Panic   = (∅, true,  false, false)
Diverge = (∅, false, true,  false)

Panic ⊔ Pure            = (∅, true, false, false)    // 不 total
Panic ; Pure            = Panic
Panic ; Diverge         = (∅, true, true, false)     // 后缀控制位并入
Diverge ; Panic         = (∅, true, true, false)     // 顺序差异不再可表达
Pure ; E = E ; Pure     = E
Pure ⊔ E                = E                          // Pure 是格底
```

实现时除上述例子外，还须检查 join/meet 格律、两参数单调性、`;` 与 `⊔` 的同式
及摘要层交换，并配负例：**摘要相等不得单独放行交换 / 删除 / 复制**——程序级
变换必须组合 `reorderable` / `discardable` 等门。

### 5.5 nondeterministic 与域稳定性

- `clock.now()`、随机数等两次求值可给不同结果：置 `nondeterministic = true`。
- 它阻断 `Read(R) vs Read(R)` 的 commute 与 CSE（同形合并），也阻断
  duplicable；**不阻断 discardable**（结果不稳定只影响被丢弃的结果，§10.1）。
- **表示位置**：`nondeterministic` 放在摘要控制位 `Q`，不做 access 级或域级
  标注——位版本让 join / interning 零改动。已知精度损失：同一摘要内混有稳定与
  不稳定读时（如 `clock.now()` 与 `stat()` 同体），稳定读的 Read/Read 交换被
  连坐。
- **域稳定性声明**：host / extension 域声明可**可选**携带 `stable`（默认
  mixed）。对声明 `stable` 的域 `R`，Read/Read 交换与 CSE 查询不受摘要级 `Q`
  连坐；声明只在查询层消费，格与 interning 不变。声明错误是 host 的 bug
  （受信契约，§13）。
- `stable` 只细化**资源对查询**，**不撤销摘要级 `Q` 对表达式整体的否决**；也
  不表示跨 `Write` 不变。

### 5.6 冲突、可交换与资源域粒度

**冲突规则**（派生 `reorderable(a, b)` 的输入）：

```text
Read(R)  vs Read(R)   => 可交换   （且 R 稳定：无 nondeterministic）
Read(R)  vs Write(R)  => 冲突
Write(R) vs 任何       => 冲突
Allocate/Release       => 与其他域内操作冲突（对同一资源域）
R1 != R2               => 默认可交换，**前提是可证不相交**
```

- **不同 Id ≠ 自动不相交**：需要资源域的 overlap / alias 关系表；未解析的
  overlap 一律按冲突处理（安全优先）。
- 实现：`Conflict` / `conflictOf` / `orderCompatible` / `stableReadPair` +
  `ResourceRegistry`（`stable`、`disjoint` 对）。
- **注册表形式**：域 Id 由各宿主 / 扩展模块在自身 metadata 中声明（§13），
  会话开始时统一 intern 并**冻结**。落地形态只有两项：**`stable` 域集合**与
  **显式 `disjoint` 对**（`ResourceRegistry`）；没有层级 / alias 表。disjoint
  不具传递性；跨提供方或未声明的对一律按冲突处理——disjoint 声明是 opt-in
  精度：漏声明只少优化、不损 soundness。域内层级 / alias 例外是 Target。

**为什么域粒度、而不是单个 IO bit**：

```text
Read(Host.Audio)      vs Read(Host.FileSystem)  → 可交换
Read(Host.Clock)      vs Read(Host.Clock)       → 不可交换（nondeterministic）
Write(Host.Output)    vs Read(Host.FileSystem)  → 可交换
Write(Host.OS)        vs Read(Host.OS)          → 冲突
```

## 6. 效果在表达式上的组合

一个 op 的效果由其 descriptor 的 `own_effect` + `transfer` 递归汇总得出。

### 6.1 组合公式

记 `effects(expr)` 为求值该表达式的效果，不隐式附加当前 full-expression 的清理：

```text
effects(seq e1; e2)        = effects(e1) ; effects(e2)
effects(call f, args)      = effects(f) ; seq(effects(arg_i), LTR) ; effect_bound(f)
effects(if c, t, f)        = effects(c) ; (effects(t) ⊔ effects(f))
effects(match s, arms)     = effects(s) ; ⨆ effects(arm_i)
effects(a and b / a or b)  = effects(a) ; (Pure ⊔ effects(b))
```

- `effects(f)` 是**求出函数值**的效果；`effect_bound(f)` 是**调用所得函数值**的
  效果——二者不得互相替代。
- callee 即便会 print / trap，也必须先于实参求值；已由 ANF 绑定的 callee 引用
  本身可以是 `Pure`。
- 当前 full-expression 的清理由其边界恰好组合一次：
  `observed_effect(expr, ctx) = effects(expr) ; cleanup_effect(expr, ctx)`。
  内部嵌套 FE 边界仍递归计入各自清理；函数体摘要也必须包含体内正常退出的自动
  销毁。**不得给每个 call 重复附加同一清理栈**（§11）。

### 6.2 descriptor 样例

```text
add.i32   eval = StrictLTR  uses = [Read, Read]  result = Copy  effects = {}
div.i32   eval = StrictLTR  uses = [Read, Read]  result = Copy  effects = { MayTrap }
move      eval = StrictLTR  uses = [Consume]                    effects = {}   // linear 效果在 OperandUse
host.print eval = StrictLTR uses = [Read]                       effects = { Write(Host.Output) }
if        eval = Branch     effects = effects(cond) ; (effects(then) ⊔ effects(else))
```

### 6.3 typed opcode 的效果表

类型专门化后的 opcode 让 descriptor 可以表化——每个 typed op 的摘要基本是静态
常量。数值 trap 语义因此只写一处：

```text
add.i32 / mul.i32 / add.i64 …      {}            // wrapping、无 trap
div.i32 / rem.i32                  MayTrap       // 仅除零（min/-1 回绕）
div.i64                            MayTrap       // 除零 + int64_min / -1
rem.i64                            MayTrap       // 仅除零（int64_min rem -1 = 0）
u32/u64 的 div 与 rem               MayTrap       // 仅除零
div.f32 / div.f64 / rem.f32 …      {}            // IEEE 754
num_cast（数值转换）                 {}            // LLIR cvt：截断 / 就近舍入，永不 trap
any 恢复（any → T 不匹配）           MayTrap       // invalid any recovery
host binding 调用（call → syscall）  TOP 或 host metadata
```

- **数值转换永不 trap** 依据 LLIR Instruction Set 的 `cvt` 定义；即便如此每个
  typed 转换 opcode 仍走 descriptor，便于未来 spec 变化。
- **整数型代数恒等式与 float 准入分离**：float 可进 SEG 不代表整数规则自动适用；
  SEG 规则集按 typed opcode 写死合法性。

## 7. Module constant 依赖（Core 两条对称规则）

把 module constant 读放进效果框架，统一规范的两条对称规则。

### 7.1 初始化顺序限制（含跨函数传递）

> 初始器只可引用较早声明的模块常量；**不得 transitive 调用一个会读取声明较晚
> 常量的函数**（Core，编译期拒绝）。

用函数摘要：`Read(ModuleConst(C))` 集合 + 按**已解析的模块身份与 schedule** 判定
（不是跨模块的全局 `const_index` 大小比较）。检查：

```text
对 effects.reads(ModuleConst) 中每一项 C：
    要求 C 在本模块声明序中先于当前初始器，或属于已初始化模块
```

- 间接调用若含未知目标（`Read(Top)` 可能指向较晚常量），按最坏假设拒绝或要求
  独立证明（不能把未知 read set 当空，§9.4）。
- 放行仅经两条通道——**编译期证明**（§9.2 的目标收窄）或 **embedding host
  声明**（§13，受信契约）。
- 语言级检查的判定对象是**源程序形态**；HIR 优化不得作为规避通道——先删除含
  违规读的路径再检查不构成放行；变换后的重验证必须在新程序形态上从头进行。

### 7.2 teardown 的对称限制

> teardown 按**逆声明序**销毁 Unique 常量；某常量的 drop hook 及其传递调用不得
> 读取已先被销毁的较晚常量（Core）。

检查对象是**完整销毁链**：hook（若有）之后还有 Unique 字段与容器元素的逆序
销毁；嵌套字段 / 元素的类型若有自己的 drop hook，同样在 teardown 期间运行并读
模块常量。因此判定用类型级 `drop_effect(type of C)` 的读集合（§11.1，hook 与
结构销毁一并计入），**不是只查 hook 的读**：

```text
对 drop_effect(type(C)) 的读集合中每一项 D：
    要求 D 在逆序销毁 schedule 中晚于 C 被销毁（即尚未销毁）
```

- 实现：`Analysis.checkModuleDependencies`（hir_effects.zig）；`checkInitReads`
  读函数摘要，`checkTeardownReads` 用 `drop_effect(type(C))` 全链；`initOrderOf`
  比较同模块声明序。它取代了 checker_validate.zig 的 AST 级 `InitOrder` walk
  ——后者只走查类型直 hook 及其传递调用，容器元素携带的 drop hook（如
  `list[File]` 常量）未走查，完整 `drop_effect` 链闭合了该缺口。`InitOrder` 已
  从 checker 删除。
- 实现选择：未知读集（来自间接调用 / 模块链的 read 通配）在 **nominal** 类型上
  保守拒绝；`any` / `hostdata` / 未解析 named 的 drop_effect 本身为 `Top`，其
  通配不对应具体常量、无归因，退回与旧 walker 相同的「不归因」位置。

**两点与规范措辞相关的待决事项**（§15）：

- Core 现措辞只提「hook 及其传递调用」，按字面会漏掉字段 / 元素级 hook 的读；
- teardown schedule 只含 Unique 常量——Copy 常量从不销毁、teardown 期读取并无
  运行期危害，而 Core 现措辞按字面禁止读一切较晚常量（含 Copy）。编译器检查
  先按规范字面执行。

### 7.3 相关不变量

- **函数引用与初始化序无关**：`fn_ref` 本身不产生 `Read(ModuleConst)`；只有
  函数**体**的执行摘要里会含它，由调用关系推导。
- **未知目标的保守**：间接调用或缺失 host metadata 的读集合取 `Read(Top)`——
  与「可能读任意较晚常量」同义。
- **`module_const(ConstId)` 仍非字面量**：读它依赖 module init 已按 schedule
  执行。只有求值已被 constant folding 具体化且无可观察初始化依赖时才允许折叠；
  v1 的 SEG 不碰 `module_const`。

## 8. 函数摘要与调用

### 8.1 效果是内部 metadata

v1 不把 effect 写进 source 函数类型。函数值在编译器内部附带摘要：

- **概念形态**：`CallableInfo { signature, effect_bound }`；
- **落地形态**：**没有 `CallableInfo` 结构**——摘要在 `Analysis` 的
  `summary` / `known` / `cur` / `comp_of` 表中按函数索引，`effect_bound` 由
  `effectBound` 查询得到（`fn_ref→func` 取函数摘要、`fn_ref→host` 取 host
  声明、`lambda` 取体摘要、其余取 `Top`）。

Source 类型仍是 `fn(int32) -> int32`；HIR refinement 才是「类型 + effect_summary」。
未来若加 source effect typing，直接建在这层上。

### 8.2 SCC least fixpoint（含递归发散）

函数体摘要在调用图上推导。允许 direct 与 mutual recursion，因此在函数 call
graph 的 SCC 上做 least fixed point：

```text
E_f := Bottom                          // 对 SCC 中每个函数
seed_f := Diverge if recursive_SCC(f) else Bottom
repeat simultaneously:
    next_f := E_f ⊔ seed_f ⊔ summary(body_f, current_callee_summaries)
    E_f := next_f
until stable
```

- **实现**：`solveSummaries`（Kosaraju `finishOrder` / `dfsCollect` 排序，
  `solveComponent` 做 callee-first Kleene / Jacobi 迭代；同 SCC 读 `cur`、已完成
  读 final），递归 SCC 播种 `may_diverge`。注册表在本轮推导期间固定，单调
  transfer 与有限高度保证收敛。
- **调用图构成**：SCC 建在分析实际使用的调用图上——`collectCallees` 为可直接解析
  的 callee（直接 `fn_ref`、§9.2 局部收窄得到的有限目标集，以及 `drop` 的类型
  hook）加边，可以是跨模块的调用环。不可证明的未知目标（经参数传递 / 高阶 /
  逃逸）不进图、取 `Top`。
- **从 Bottom 迭代本身不能发现发散**：`f → f` 必须额外 seed。**递归 SCC 一律
  保守标 `may_diverge = true`**，只有另有独立终止证明才可取消。
- **分析状态不属于格**：使用 `Pending` / `Ready(EffectSummary)`；SCC 内部可读
  本轮近似，但优化器只能使用 Ready。尚未收敛时查询失败关闭——`Bottom` 与
  `Pure` 同值，「未推导 ≠ 已证明纯」由 `Pending` 承担。未知目标、外部摘要缺失
  或分析放弃时发布 `Ready(Top)`。
- 推导风格与类型系统对递归 Copy/Unique 分类的 least-Copy fixpoint 一致
  （Types & Ownership，type_shape.zig 的 `ownershipOf`）。

例：

```stilla
fn a() { b(); }              effects(a) = effects(b) = { Write(Host.Output) }

fn f() { g(); }              f、g 在同一 SCC：
fn g() { f(); host.foo(); }  两者均 may_diverge = true；访问仍保守含 host.foo
```

### 8.3 失效与重算

摘要随 HIR 变换失效（任何变换之后都要对受影响区域重新验证 ownership 与
effects）。

> **现状：全量重算，无增量失效。** `solveSummaries` 每次开始时清空 memo /
> summary，`analyze` / `validate` 从头重导；没有标脏、世代 / 版本号或调用者
> 传播。原设计的增量失效模型（下方）**未实现**，因为当前消费者每轮都从头
> 重导（hir_seg.zig）与 `revalidateHir`。

设计意图（待需要时落地）：

- **存储与求解**：函数级 memo 缓存每函数摘要；被改写函数所属递归 SCC 需重算时
  **联合重算**——从种子重新迭代，**不在旧摘要上继续 join**（重写会减少
  effects，增量向上合并永远降不下来）。
- **标脏**：标脏被改写函数，并用世代 / 版本号阻断一切缓存旧摘要的查询。
- **传播**：重算后 interned id 与旧值相等即短路；传播范围由「摘要是否真的变了」
  决定，不由「哪个函数被改」决定。
- **边界**：id 短路只作用于效果摘要；ownership / cleanup / call-target 等派生
  事实各有依赖与失效规则——§10 的查询组合它们，不等于它们随 effect id 自动免
  失效。

## 9. 一等函数与间接调用

### 9.1 间接调用缺省 = TOP

```text
callback.f(x)   // 目标静态未知
```

目标无法由 §9.2 收窄时取 `Top`：`accesses = All`，`may_trap`（含 panic）、
`may_diverge`、`nondeterministic` 全 true。不能只是「有副作用」一位，也不能遗漏
发散或非确定性。

### 9.2 数据流收窄：局部 fn-ref 传播

```text
FnValueInfo { type: FnTypeId, effect_bound: EffectSummaryId }
```

若 callee 操作数静态可见地绑定到有限目标集 `f ∈ {foo, bar}`，则
`effect_bound(f) = summary(foo) ⊔ summary(bar)`。

**已落地的一档**：`hir_effects.Analysis.resolveTargets` 沿 builder 生成的
**局部**绑定链把 callee 值反向解析成 `{func, host}` 目标集，命中以下形态即收窄：

- 字面 `fn_ref`（首个目标）；
- `local` → 其绑定 `let` 的单参、无 pattern 初始化器（`Analysis.binder_init`
  索引，创建期一次扫描）；
- `if` / `match` 的**各分支 region root**（有限集并集；任一分支解析不出即整
  体失败）；
- `seq` 转发到末位 operand、`move` / `borrow` 透传 operand 0。

其余一律是边界并回 `Top`：函数 / λ 参数、`match` arm 与解构绑定、`field_get`
（值已逃逸进结构体）与任何 `call` / `module_const` 结果、value-position 模块
链、`any_cast` 恢复。这同时就是“**不跨函数边界、无逃逸路径**”的实现：解析只
沿绑定链走，遇到不是 `let` 的绑定点即停。

**需求驱动**：只在真实消费点现场解析——`effectBound` / `callBound` /
`callbackBound`（摘要推导）与 `collectCallees`（调用图构图），不建全局缓存。

**预算是精度预算，不是截断**：超过 `max_indirect_targets`（不同目标数）或
`max_indirect_steps`（节点访问数）即返回“不可证明” → 调用点取 `Top`，**绝不
返回前 N 个目标**（截断是 under-approx，soundness bug）。

**调用图必须看到同一目标集**：`collectCallees` 用同一份 `resolveTargets` 把收窄
得到的有 `FuncId` 目标加进 call graph（host 目标照 §13 契约实例化回调实参），
否则经局部 fn-ref 的递归会漏掉 SCC `may_diverge` seed。`resolveTargets` 本身不读
任何摘要，故构图期无循环。

### 9.3 host 元数据缺失 → TOP

host 函数的摘要来自 embedding metadata（§13）；缺失一律 TOP。

### 9.4 间接读 module const 的保守

初始化检查中，间接调用若 `effect_bound = Top`，其读集合视为「可能读任意较晚
常量」——不能当作空读集合放行（§7.3）。

## 10. 派生查询与优化合法性

### 10.1 事实表：不存 bool

**只保存事实（EffectSummary + 派生所需的类型 / use / view），不保存
`is_pure = true` 这类 bool。** 所有优化属性由查询函数推导：

| 属性 | 判定（由 EffectSummary 及 ownership 门组合） |
| --- | --- |
| `total` | `!may_trap ∧ !may_diverge` |
| `observable_effect_free` | 无 `Write / Allocate / Release`、无未知资源（Top）；资源**读**默认不构成可观察交互 |
| `discardable` | `total` + `observable_effect_free` + 给定清理上下文下 `discard_view(observed_effect(expr, ctx)) == Pure`（§11；discard_view 忽略 Q）+ ownership 门——**不要求 !Q** |
| `duplicable` | `discardable` + 结果 Copy + `OperandUse` 全 `Read` + **无 Q** |
| `speculatable` | `total` + 无有序 / 可观察 effect + **无 Q**；**上下文**：可移动性相对目标位置（§10.5），`isIntrinsicallySpeculatable` 只是必要非充分 |
| `reorderable(a,b)` | **位置上下文**：由 `canSwapOperands` / `canMove`（父 EvalPolicy + operand 位 + 路径屏障，§10.5）判定 |
| `seg_safe` | `Copy(type)` + `total` + `observable_effect_free` + 无 Q + cleanup 安全证明 + 递归子树与 region 同判 + ownership / lifetime 门（§12.3） |
| `can_float_as_tree` | selective ANF 准入：`total` + `observable_effect_free` + 清理上下文 |
| `never_returns(f)` | **must 事实、独立于摘要**：签名 `-> never` 或结构推导；递归 SCC 取 greatest fixpoint（见下） |

**强约束**：`move.effects == {}` **不**使 move 变得 discardable / duplicable /
speculatable——每个公开查询都要组合 effect、operand uses、结果 capability/view、
ownership 可用性与 lifetime 栅栏，**缺一不可**。

**代码中的查询名**：`readySummary` / `observedEffect` / `isTotal` /
`observableEffectFree` / `canFloatAsTree` / `isDiscardable` / `isDuplicable` /
`isSegSafe` / `hasSegEncoding` / `isSegAdmissible` /
`isIntrinsicallySpeculatable` / `canSwapOperands` / `canMaterializeOperand` /
`orderCompatible` /
`cleanupFree` / `ownershipGate`；间接调用目标收窄的 `resolveTargets` /
`effectBound` / `targetCallBound`；纯摘要级 `effects.isTotal` /
`isObservableEffectFree` / `discardView` / `isPure`。**没有** `is_droppable` /
`drop_is_observable` 这类额外查询。没有「facts table」缓存——查询按需从
`readySummary` 计算。

- **`never_returns(f)`（已实现）**：f 无正常返回路径——签名 `-> never`，或结构
  推导（`hir_effects.exprNever`：`never` 型节点、严格求值子项、全臂分支、可解析
  callee 集）。推导保守（取不到即 false）；递归 SCC 取 **greatest fixpoint**
  （coinductive：`fn f() -> void { f() }` 真的不返回，least fixpoint 会漏掉）。
  调用点后同一直行区域的后缀不可达，M2b 消费者（`hir_simplify.zig`，
  `--simplify`）整段删除（§12.4）并退役该区域的 FE 清理 token。被删节点不可达，
  故 `cleanupEffect` 的 `in_subtree` 本就不再计入，退役是 token 表卫生 +
  `cleanupOriginsReachable` 不变量。结果类型特化为 `never` 后由 `hir_lower_expr`
  的「`never` 型节点终止块」规则落地为 `trap`。摘要代数不变，`;` 合并仍保守并入
  后缀位。
- **结果不稳定（Q）与可观察交互分离。** `nondeterministic` 只描述「同式两次
  求值结果可不同」——它需要**结果**参与的判定（duplicable、CSE、speculate /
  move 前移）才要求 `!Q`；它本身**不构成可观察交互**：

```text
discardable      : 不要求 !Q      // let x = clock.now() in 0 → 0 合法
duplicable / CSE : 要求 !Q
speculate / move : 要求 !Q
```

资源**读是否可观察是 host 契约决定**（§13）：默认读非可观察；宿主把读本身
声明为可观察时以 `Write` 或可观察读标注出现，discardable 自然拒绝。Q 仍留在
格内，discard 判定只经 `discard_view` 投影忽略它。

### 10.2 MayTrap 是 effect：dead-let 的通用化

```stilla
let x = 10 / y;
0
```

若 `x` 未使用，`let x = 10/y in 0 → 0` 看起来像 dead-let；但整数除零 trap，
变换不合法。于是 `effects(div.i32) = { may_trap: true }`，dead-let 规则自动成为：

```text
let x = v in body  →  body
    若 x ∉ FV(body)  ∧  discardable(v)        // discardable(div(..)) == false
```

不再需要 dead-let pass 特殊认识 `/`；实现见 `tryDeadLet`（hir_simplify.zig）。

### 10.3 rewrite legality 统一接口

**两层判定必须分开**（否则「不 `switch(opcode)`」会被误读为所有 rewrite 都与
opcode 无关）：

- **Rewrite applicability**：typed opcode / 代数语义 / 值谓词。引擎在**规则匹配
  层**认识 opcode 没问题：`x + 0 → x` 能否做首先取决于它是 `add.i32` 还是
  `add.f32` / decimal / vector——这是代数可适用性。
- **Operational legality**：discard / duplicate / reorder / effect / ownership /
  lifetime。**通用 legality 引擎不认识 opcode**，合法性只来自派生查询。

「优化器永远不 `switch(opcode)` 决定合法性」的精确含义是后者：legality 引擎
没有 per-opcode 分支；applicability 是规则库内部事实，随 typed opcode 注册。

**现状：两层已落地为类型**（`passes/rewrite_contract.zig`）：
`RewriteRule { name, applicability, legality: [Requirement], contract }`、
`Requirement = Discardable | Duplicable | SwapOperands | EvaluationCountPreserved
| Materializable`。
`check(analysis, rule.legality, subjects)` 是通用 legality 引擎——它唯一的
`switch` 在**声明的要求标签**上，每个分支只调用派生查询（`isDiscardable` /
`isDuplicable` / `canSwapOperands` / `canMaterializeOperand`），**没有
`switch(op)`**。
`EvaluationCountPreserved` 是规则自证的结构义务（引擎无法验证）：引擎接受声明，
warrant 在规则自身的构造里（β→let 逐参数嵌套、LTR，不删除 / 不复制 / 不重排）。
`applicability` 记录规则匹配层允许读什么：`.typed_opcode`（折叠 / 代数规则，按
`add.i32` vs `add.f32` 等 typed rep 分派）与 `.shape`（结构匹配，如 β 的
`call(fn_ref→λ, args…)`、dead-let 的 `let` 单参形状）。

与设计 sketch 的差异（实现形态选择）：`legality` 是**要求标签**列表——规则声明
是静态值，不能携带派生查询需要的 `ExprId`，主体在调用点以 `Requirement` 实例
给出；`match` / `build` 仍是 pass 内的规则函数，由 `RewriteRule.name` 指名，v1
不做函数指针化的表驱动；`effect` 落为 bool 集合结构体（一条规则可同时持有多个
保证）。首批实例是 β（hir_seg.zig）与 dead-let（hir_simplify.zig）；随后是 SEG
的 `ruleLet` 三分支（`let_dead` / `let_forward` / `let_atom`，hir_seg.zig），
以及 η（`eta_rule`）与 selective ANF（`anf_rule`，hir_simplify.zig）。
`Materializable` 是这两批之后新增的标签：`canMaterializeOperand(parent, slot)`
（§12.1 的 ANF 准入）判定「slot 处的 operand 可提为合成 `let` 的 init」——
其前的 operand 可被推迟（`Class.seq` 时更要求 Copy，因就地处弃的 Unique 会被
推后）且被提 operand 的析构点不动（Copy，或父节点已 `Consume` / 就地处弃它）。
它的主体是 `Subjects.hoist`（parent + slot），与 `swap_operands` 的复合主体同一
形态。`Subjects.expr` 仍是单表达式义务的主体。

例：

```text
Rule add_zero_i32   match: add.i32(x, 0)   applicability: true   legality: EvaluationCountPreserved(x)
x * 0 → 0           要求 Discardable(x)          // host.read() * 0 不能变 0
x + x → 2 * x       要求 Duplicable(x) 或显式 EvaluationCountPreserved
```

### 10.4 rewrite 的 effect contract（正式概念，两类重写）

**两类重写**：普通 SEG 重写必须 full-expression-preserving；**boundary
rewrite**（v1 唯一实例是 β）把 callee 体从 λ 内部边界搬进调用点，必须逐条声明
契约后才准入。契约的 effect 面：

```text
RewriteContract {
    effect: { PreservesEvaluationCount | PreservesOrder
            | MayDuplicate | MayDiscard | MayReorder }
    maps_scope / maps_full_expr: bool
    preserves_cleanup: ?CleanupProof   // cleanup_free_subtree | binder_destruction
}

β-to-let    : PreservesEvaluationCount + PreservesOrder + scope/FE 映射
              + preserves_cleanup = cleanup_free_subtree
let-unused  : MayDiscard(init) → 引擎自动要求 discardable(init)
              + preserves_cleanup = binder_destruction
let-forward : PreservesEvaluationCount + MayReorder + maps_full_expr
              + preserves_cleanup = cleanup_free_subtree
let-atom    : MayDuplicate + maps_full_expr（原子可 `duplicable`）
```

**现状：契约已落地为类型**（`passes/rewrite_contract.zig`）。`RewriteContract`
的三个映射字段声明规则会做什么，`preserves_cleanup` 声明它需要哪种清理证明；
`RewriteRule.contract` 携带声明，`checkCleanup` 按声明的 kind 检查调用点给出的
证明实例（kind 不符即失败关闭），`checkCleanupProof` 只用派生查询：

- `cleanup_free_subtree(id)`：被求值的子树 `cleanupFree` 且过 `ownershipGate`
  ——β 的实例（call 结果 Copy、实参 Copy 由 `tryBeta` 显式复查，因为 ownership
  gate 对 λ 节点短路）；
- `binder_destruction(T)`：删除绑定同时删除它的 scope-end 析构，仅当该析构本身
  可丢弃（或 binder 是 Copy、根本没有析构）才准入——dead-let 的实例。

β 的 `beta_rule`（hir_seg.zig）据此声明：`effect = PreservesEvaluationCount +
PreservesOrder`、`maps_scope` / `maps_full_expr` 为真、
`preserves_cleanup = cleanup_free_subtree`。**实参不要求 total / 无可观察效果**：
β→let 不删除、不复制、不重排实参，故 effectful 实参逐字保留（求值次数与 LTR 序
不变）。`let` 三分支同样据此声明并由 `ruleLet` 消费：`let_dead_rule`
（`.discardable` + `binder_destruction`）、`let_forward_rule`
（`EvaluationCountPreserved + MayReorder`、`maps_full_expr`、
`cleanup_free_subtree`）、`let_atom_rule`（`.duplicable`、`maps_full_expr`）——
它们是与 β 并列的 boundary rewrite（§8.7）。仍留在匹配层（`tryBeta` 内联）的是
结构性事实：λ / 单 region / 形参实参 arity、λ 体是 seg-safe 的单表达式（非
`seq` root）、λ 只经 `fn_ref` 可达、以及 `beta_done` 的消耗性守卫；`ruleLet`
的匹配层额外拒 `move` / `drop` 的 binder 槽与非同型 binder（隐式强制转换）。
η 与 selective ANF 的契约同样已落地：`eta_rule`（hir_seg.zig）声明
`PreservesEvaluationCount`，只重定向值位置的 `fn_ref` payload，不求值、不删除、
不复制、不重排、无清理注册变动，故无 cleanup 义务；`anf_rule`
（hir_simplify.zig）声明 `PreservesEvaluationCount + MayReorder`，legality 是
`materializable`——合成 `let` 与源级 `let` 不同，**不跨 FE**（init 沿用父节点的
FE，不重盖），其唯一额外义务是析构点重合，由 `canMaterializeOperand`
（§12.1）经派生查询出证。两者的匹配层（λ 形状 / 链界 / 类型相等 / 全性，
以及“首个不可浮动 operand”）仍是结构性 applicability。详见
[hir.md](hir.md) §8.4–§8.5。

`(fn(x) { x + 1 })(host.read())` 整体仍不能进纯 term 的 equality saturation
——但 β 本身不删除、不复制、不重排 `arg`，契约（求值次数 / 序 / scope / FE /
cleanup）证明后**已允许** effectful 实参：`host.read()` 作为 λ 外实参按原序求值
一次。随之而来的义务落在下游规则：β 生成的 `let` 可能绑一个非 island 的
init，因此 forwarding / 原子复制只有在 init 仍是 island 成员 / `isDuplicable`
时才可把它搬移或复制，否则会丢掉或重排效果；dead-let 改用更强的
`isDiscardable(init)`（允许可丢弃的 Unique init，同时折叠其全表达式清理面）——
皆见 `hir_seg.zig` 的 `ruleLet` 与 §8.3。

### 10.5 实现形态（Zig）

设计 sketch：

```zig
const OpSemantics = struct {
    eval: EvalPolicy,
    operand_uses: []const OperandUse,
    result_policy: ResultPolicy,
    infer_effects: *const fn (ctx: *EffectContext, expr: ExprId) EffectSummary,
    seg: ?SegDescriptor,
};

const EffectSummary = struct {
    accesses: EffectRowId,   // interned 行：有序去重 EffectAccess
    // 不设默认值：构造点必须显式选择 pure / top 或完整摘要
    may_trap: bool,          // 包括 panic
    may_diverge: bool,
    nondeterministic: bool,
};
```

构造器 `pure()` / `top()` / `bottom()` / `may_trap` 严格按 §5.4 的四元组赋值；
不可依赖 Zig `.{}` 或空访问行推断摘要。Pending / Ready 包在摘要之外。

**实际落地的 descriptor 形状**（`OpDescriptor` 定义见 [hir.md](hir.md) §3.5）是上述
sketch 的语义等价映射：

| sketch | 落地字段 |
| --- | --- |
| `eval` | `policy`（`EvalPolicy`） |
| `operand_uses` | `uses`（`UsePolicy`：`operand_capability` / `callee_params` / `static_list` / …）+ 可选显式 `operand_uses` 切片 |
| `infer_effects` | `own_effect`（op 自身摘要）+ `transfer`（`TransferKind`，由 `hir_effects.compute` 按标签组合 operand / region / callee） |
| `seg` | `seg: ?SegEncoding` |
| `result_policy` | 由既有 capability / view 数据承担 |

`uses` / `own_effect` / `transfer` 必填、无默认值（省略即编译错误）。

公开查询（每个都组合 effects × uses × capability/view × ownership 门；Pending
或 cleanup 证明缺失均返回 false）。**speculate / reorder 是上下文属性**，公开面
把上下文显式参数化，只保留一个弱无上下文谓词：

```zig
// 表达式自身事实的弱判定：无 intrinsically blocking 条件。必要非充分。
fn isIntrinsicallySpeculatable(ctx: *HIR, expr: ExprId) bool;

// 交换同一 parent 下两个 operand slot（v1 先限相邻的 eager operand）。
fn canSwapOperands(ctx: *HIR, parent: ExprId, lhs_slot: u16, rhs_slot: u16) bool;

// 把 expr 从 from 位置移到 to 位置。
fn canMove(ctx: *HIR, expr: ExprId, from: EvalPosition, to: EvalPosition,
           mctx: MovementContext) bool;

fn isDiscardable(ctx: *HIR, expr: ExprId, cleanup: CleanupCtx) bool;
fn isDuplicable(ctx: *HIR, expr: ExprId) bool;
fn isSegSafe(ctx: *HIR, expr: ExprId) bool;

const EvalPosition = struct { parent: ExprId, slot: u16, fe: FullExprId };
const MovementContext = struct { /* 路径上的 effect / trap / condition / borrow
    lifetime / FE 边界、目标 binder 可见性、求值次数与销毁注册变化 */ };
```

- **`canMove` 尚未暴露**（FE / lifetime 路径事实未建模，暴露恒 false 的入口无
  意义）。
- `canSwapOperands` 组合父节点 operand 位、full-expression 边界、两 operand 的
  cleanup / ownership 门，再经 `orderCompatible`（资源冲突、trap/diverge 顺序、
  `Q`）。
- 旧的 unary `isSpeculatable` / binary `canReorder` 签名作废：EvalPolicy 是
  **parent + operand 位置**的属性，二元签名无法消费「EvalPolicy 允许」。

## 11. 完整销毁的可观察性

### 11.1 drop_effect(T)：类型系统与效果系统的桥

```text
drop_effect(T) -> EffectSummary
```

- `Copy(T)` → `{}`；
- `struct File { drop(file) { os.close(file.fd); } }` →
  `effects(File.drop_hook) ; seq(drop_effect(unique fields…), 逆声明序)`；
- `tuple[A, B]` → `drop_effect(B) ; drop_effect(A)`；
- `list[T] / box[T]` → 结构性递归（元素 / 内层 + 容器本身）；
- host opaque / `hostdata` → `Release(Host …)`；**未知 opaque 与 `any` 的装载
  内容销毁未知**，取保守摘要；
- union 候选 variant 用 `⊔`，实际销毁步骤用 `;`；list 的未知长度须覆盖零元素
  （`Pure`）及所有可能元素销毁序列；
- 递归类型 → 在类型 SCC 上求 least fixpoint（重入同类型返回格底，见下）；深度
  超 `max_drop_type_depth` 即回 `Top`。**分析收敛 ≠ 运行时销毁终止**：收敛不
  授权去掉 `may_diverge`。

**落地形态：**

| 实现 | 状态 | 行为 |
| --- | --- | --- |
| `hir_effects.dropEffectOf(ty)` / `dropEffectInner` | **生产路径** | 精确全链，见下 |

`drop` descriptor 的 `own_effect` 是 `pure`、`transfer = .drop_effect`；
`Analysis.compute` 的 `.drop_effect` 分支调用**精确的** `dropEffectOf(operand
类型)`，再 `; effects(operand)`。module-const teardown 检查（§7.2）也用它。
这是唯一路径：M1b 遗留的极简 `effects.dropEffect`（Copy → `{}`，其余 / null →
`Top`）已删除（docs/todo.md 第 20 项）。

`dropEffectInner` 的递归：

- Copy 值短路 `{}`；`any` / `hostdata` / 未解析 → `Top`；
- struct：自身 hook 摘要 `;` Unique 字段按逆声明序递归；
- union：候选 payload 用 ⊔，实际销毁用 `;`；tuple 逆序；list / box 元素递归；
  opaque → `Release(Host(host_id))`；
- 命名类型递归按**类型身份截断**：下降中重入同一类型即返回格底 `Pure`。实现
  论证这与「有限展开的 join」同值（may-摘要幂等），即 least fixpoint，无需显式
  迭代；**不做 memoization**（被截断时的结果是 under-approximation，不可复用）；
- 安全网 `max_drop_type_depth = 64`：非正规实例化链超过深度即回 `Top`。

类型摘要与 drop hook 函数摘要**独立求解**：drop hook 是普通函数，其摘要在函数
SCC（§8.2）中推导；`dropEffectOf` 经 `functionSummary` 读 hook 摘要。**跨层环
没有专门检测**：hook 的 SCC 尚未求解时 `functionSummary` 返回 `Top`（保守）。

**长期演化（未立项）**：函数摘要与 `drop_effect(T)` 各自在 call-graph SCC /
类型 SCC 上求不动点，本质是同一格上的单调函数。若跨层环成为常见模式，把依赖
节点统一为 `EffectDependencyNode = Function(FuncId) | DropType(TypeId)`，在一张
统一 dependency graph 上做 least fixpoint，可消掉回退 `Top` 的精度洞。

### 11.2 full-expression 清理与 observed_effect

Unique 临时量在所属 full expression 末尾**逆创建序**销毁。一个表达式的真实
语义不只是 `effects(expr)`，还要含其自动清理——但清理是**上下文相关**的：

```text
observed_effect(expr, cleanup_context) =
    eval_effect(expr) ; cleanup_effect(cleanup_footprint(expr), cleanup_context)
```

**清理栈条目的 occurrence 归属（CleanupFootprint）。** 每条登记必须能回答它
属于**哪个表达式 occurrence**：

```text
cleanup_footprint(expr) =
    { token t | t.origin_expr ∈ subtree(expr)
                ∧ t 登记在 expr 所属 FE 的清理栈上（未被 move / 转入调用消耗） }

CleanupToken { id, origin_expr: ExprId, value: TempId, type: TypeId, registration_index }
```

落地形状（`hir.CleanupToken`）为 `{ origin_expr, ty, full_expr,
registration_index, kind }`：`kind = full_expression | scope_end` 区分两类
销毁计划（见下）；`value: TempId` 与 token 的 `Consumed / Escaped` **状态**
都是路径敏感的，属于 destruction planner / CFG 侧（§11.3），本层不建模。

**scope-end 销毁累加与排序模型。** 除 FE 临时量外，Unique 还因**自动销毁**
在作用域末尾逆创建序析构：非借用 Unique region 绑定（`let` / `match`
arm 的 pattern 绑定 / λ 参数）在构建期各登记一个 `kind = scope_end`
token，锚在**该 region 的 root 节点**上、归属**外层** FE——root 与 token
的 `full_expr` 由此同界，`registration_index` 与 FE 临时量共用同一
FE 内创建序计数器，两类销毁计划因此落到**同一张表、同一套排序**。锚取
region root 而非 init：init 自成内层 FE，而析构点在外层 FE 末尾，只有
root 节点能同时满足「origin 节点 FE == token FE」与「类型/使类型经
binder 携带」。`cleanupEffect(expr)` 的子树归属判定对两类 token 统一为
`origin_expr ∈ subtree(expr)`：含 `let` 的表达式其 scope-end 析构随之
计入，init 单独求值时则不计入（值被转移、不由 init 销毁）。

- `observed_effect(expr, ctx)` 拿的是 **expr 子树对清理栈的贡献**，不是整条 FE
  的清理：`foo(make_file(), pure_expr())` 中 `discardable(pure_expr())` 不得把
  sibling `make_file()` 的 destructor 算进来；`discardable(make_file())` 必须
  计入其临时量在 FE 末尾的 drop。
- MVP 只需 token 的 **origin + type + registration_index**；`Consumed /
  Escaped` 这类**状态**是路径敏感的，属于 destruction planner / CFG 侧（§11.3）。
- `make_file();` 的 full expression 实际含 `drop_effect(File)`——不能凭空
  effects 删除；
- 被 `move` / 转入调用（如 `consume(move make_file())`）的临时量**不在**清理栈
  上，不得重复计清理；
- 清理只在**正常路径**发生：panic / trap 跳过全部销毁；某个 destructor 异常
  终止后不执行剩余清理；
- 清理顺序（逆创建序）用 `;` 折叠，空清理为 `Pure`；cleanup 证明不可用时查询
  失败关闭，需要保守摘要时用 `Top`。**不能把未知清理当 `Pure`**。
- **变换后的 origin 重映射**：任何重写后，被改写区域内存活临时量的 token 须把
  origin 重映射到新节点，registration_index 保持原 FE 内相对销毁序；「合成 let
  不改销毁注册」即此不变量。

> **现状：CleanupFootprint 已落地（MVP 形状）。** `CleanupToken`
> （`origin_expr` / `ty` / `full_expr` / `registration_index`）由 builder 的
> 清理登记步骤（`passes/hir_build_cleanup.zig`，`hir_build.buildProgramInner`
> 末尾对每个函数体 / 常量初始化器登记）填充；`observedEffect` 与
> `canFloatAsTree` 走 `hir_effects.cleanupEffect`（footprint 内各 token 的
> `drop_effect(T)` 按逆创建序折叠），不再只依赖 cleanup-free MVP。三条不变量：
>
> - **建模与否显式区分**。`Program.cleanup_modeled` 未置位的程序，其空 token
>   表是「未建模」：`cleanupEffect` 返回 null，查询失败关闭为 `Top`。空表
>   绝不构成安全证明。
> - **scope-end 清理已建模**。非借用 Unique region 绑定（`let` / `match`
>   arm / λ 参数）在构建期登记 `kind = scope_end` token（锚在 region root、
>   归属外层 FE、`registration_index` 与 FE 临时量同计数器），`cleanupEffect`
>   不再对含 Unique region 绑定的子树回 `null`：锚在求值子树内的 scope-end
>   token 与 FE 临时量按同一逆创建序折叠。destructor 可丢弃（纯）时派生查询
>   精确通过，可观察时照旧拒绝删除 / 浮动——`discardable` / `can_float_as_tree`
>   的答案由此精确化，不再一律保守 `Top`。**路径敏感状态不在本层**：被
>   `move` / 转入调用的绑定其 token 仍登记为保守 may-drop，`Consumed /
>   Escaped` 仍属 destruction planner / CFG 侧（§11.3）。`cleanupFree` 语义
>   保持字面 cleanup-free 不变（`regionOwnsUnique` 仍在其中），仍供 β /
>   speculatability / reorder 使用。**构建期之后**的合成绑定不登记：selective
>   ANF 的 Unique `let` 其合法性契约已证明「父节点转移或序列中就地处弃」，
>   β 克隆体由 `isSegSafe(body)` 保证 cleanup-free，CSE 的共享 init 是
>   `isDuplicable` 的 Copy 值——树内出现这些绑定不产生析构，也不会低报。
>   dead-let 删除绑定（连同其 scope-end 析构）时退役对应 token。
> - **失败关闭**。未分类类型经 `drop_effect(T)` 升为 `Top`；dead-let 对 Unique
>   绑定额外要求 `bindingCleanupDiscardable(bind.ty)`，避免连同绑定删掉
>   其 scope-end 析构。
>
> **边界**：节点级 full-expression **边界标注**（`ExprNode.full_expr`）已落地
> （§5.6）：builder 的清理登记步骤把真实 FE id 写进每个节点，token 的
> `full_expr` 按同样的语句 / let 初始化器切分，用于定义 `registration_index`
> 的 FE 局部创建序；validator 对 `full_expression` token 要求 origin 节点类型
> 与 token 类型一致且归属 token 的 `full_expr`，对 `scope_end` token 要求
> anchor 归属 token 的 `full_expr`、token 类型等于绑定类型且 anchor 确为该
> region 的 root。变换后 `registration_index` 保持不变（相对销毁序）；
> `full_expression` token 的 origin 经 `Program.remapCleanupOrigin` 重映射
> （ANF hoist / dead-let / SEG clone），`scope_end` token **不**remap（其锚是
> region root，绑定身份不变）；**删除**绑定（dead-let）时经
> `Program.retireScopeTokens` 退役其 token。

优化器只问一个谓词：

```text
discardable(ctx, expr)   // 内部组合 total、observable_effect_free 与
                         // discard_view(observed_effect(expr, ctx)) == Pure
```

### 11.3 drop_effect ≠ 有序销毁计划

`drop_effect(T)` 只汇总**可观察性**；真正的有序销毁计划（hook 调用、逐字段
drop、maybe-unique 的 join 边 drop、panic/trap 路径跳过清理）仍由 destruction
planner / CFG 层生成。effect 系统保证 DCE 不会误删带重要 destructor 的临时值，
**不替代计划本身**。

## 12. 效果驱动的前端变换

三个首要消费者，共同点是**合法性全部来自派生查询，任何一个都没有 `switch(op)`
特判**。dead-let 与 selective ANF、`never_returns` 后缀删除在 hir_simplify.zig
（`--simplify`，默认关），SEG 准入在 hir_seg.zig（可执行文件默认开、`--no-seg`
关；库默认关）。

### 12.1 Selective A-Normal Form

```text
if !can_float_as_tree(ctx, expr):     // 派生查询
    materialize let
```

```stilla
f(os.read(), a + b * c)
```

```text
os.read()        effects = Read(Host.FileSystem) + MayTrap   → 提为 let
a + b * c        effects = {}                                 → 保留树

let T0 = os.read() in call(f, local T0, add(a, mul(b, c)))
```

新增 intrinsic（如 `gpu.query`）：在 stdlib 加无体声明并写 lowering 展开；其
效果来自展开出的现有 op 与 host 调用，前端 canonicalizer 零改动。约束保留：
callee 若本身是表达式先按 LTR 绑定；不跨 full expression；不从惰性分支内提升；
不改变临时量销毁注册。**Unique operand 的物化条件**：合成的 `let` 绑定在外层
作用域末尾销毁，只有父节点已 `Consume` 转移该值，或父节点是 `Class.seq` 的
非末位 operand（被丢弃的语句，`discardValue` 就地处弃）时才提——两种情形下
合成绑定与原匿名临时量的析构点重合；`Read` / `Borrow` operand 留在树内。
且 sequence 提升后来 operand 时，其先前 operand 必须全为 Copy：Unique 绑定的
就地处弃不在 `can_float_as_tree` 的清理模型内，跨过它会推迟一个可观察析构。

该准入已落为 `anf_rule`（hir_simplify.zig）：`legality = { EvaluationCountPreserved,
Materializable }`，`Materializable` 分支经 `canMaterializeOperand(parent, slot)`
出证（§10.3），`tryAnf` 在选中首个不可浮动 operand 后由 `check` 消费；
`EvaluationCountPreserved` 是「每个 operand 仍恰好求值一次」的结构自证。

### 12.2 dead-let

见 §10.2——`discardable` 一个查询同时覆盖 trap、效果与清理，规则无需认识 `/`
或任何具体 op。

### 12.3 SEG legality

SEG 入口从 op 白名单改成两个条件（先看该 op 是否带 SEG 编码，再看派生查询）：

```text
admission(expr) ==
    hasSegEncoding(op(expr))           // 注册表带 SEG 编码
    && isSegSafe(expr)                 // 语义谓词；**不含**编码检查
    && 所有 operand / region root 同为 island 成员

isSegSafe(expr)  == ...
    Copy(type(expr))
    && total(expr)
    && observable_effect_free(expr)
    && 无 nondeterministic（Q = 0）
    && cleanup 安全证明（已证明 cleanup-free，或 observed_effect == Pure）
    && 递归：所有 operand 子树同判
    && 对 lazy-branch op：每个可选 region body 同判
    && ownership / lifetime 门：无 Borrowed-view 参与、无未决 Consume、
       不跨越 full-expression 边界
```

准入结果示意：

```text
add.i32 / mul.i32 / add.f32    ✅
div.i32                        ❌  may_trap
any 恢复                        ❌  may_trap
host binding 调用（syscall 目标） ❌
drop / move Unique             ❌
```

职责分离：v1 的 SEG 由 HIR→SEG bridge 的 legality 查询负责准入——检查的是
**递归属性**（region body 与 ownership 依赖都纳入），而非只看根节点。

**本谓词只管普通 island**：boundary rewrite（β，[hir.md](hir.md) §8.4；η，§8.5；
跨 FE 的 `let` 折叠，§8.3 / §8.7）的操作形式不被编码 / 成员资格覆盖，因此绕过
`admission`；但 β 仍**调用** `isSegSafe`（对 call 节点与 λ 体），再叠加 §10.4 的
契约条件，`let` 三分支同样逐条声明并消费 §10.4 的契约。

### 12.4 `never_returns` 后缀删除

独立于摘要的 **must 事实** `never_returns(f)`（§10.1）驱动：调用点后同一直行
区域的后缀不可达，整段删除（`seq` 在首个 never-normalizing operand 处截断；
`let` 的 init never-normalizing 时用 init 替换整个 `let`）。删除的子树其 FE
清理 token 一并退役（`cleanupOriginsReachable` 不变量）。被删除节点不可达，故
`cleanupEffect` 的 `in_subtree` 早已不计入——退役是 token 表卫生，不是正确性依赖。
结果类型特化为 `never` 后由 lowering 的「`never` 型节点终止块」规则落地为 `trap`。
合法性不需要任何效果查询：head 永不返回，后缀永不执行，删除不改变可观察行为。

## 13. Host 接口 metadata（embedding ABI）

> **Status：声明入口、重入契约、缓存指纹、回调参数化与 host_bind 接线均已落地。**
> **已实现**：`StillaExecution` 三态、符号键声明（`effects.HostDecl` /
> `HostEffects.resolve` / `consolidate`）、`frontend.Options.host_decls` 与
> `resources` 贯穿初始分析 / SEG / selective ANF / `revalidateHir`、分析内
> 局部 host 语义注册表（`stable` / `disjoint`）、`HostDecl.callbacks` 回调
> 契约与调用点 `own ⊔ ⨆ effect_bound(target_i)` 收紧、
> `EffectEnvironmentFingerprint` 与 `frontend_cache` 的语义键记录、
> `host_bind.MemberEffects` + `declarations` 的 typed registry 自动声明接线。
> **未实现（有意）**：运行时侧契约匹配校验——编译器看不到 host 代码，声明是
> 受信契约，不提供重入能力，也不校验 embedding 是否真的遵守。

host 是 Stilla 的核心目标。编译器侧模块元数据：

```text
HostFunctionDescriptor {
    signature
    effects:          EffectSummary
    stilla_execution: StillaExecution
}

StillaExecution = Forbidden | MayExecute | Unknown   // 缺失 = Unknown
```

```text
math.sqrt:      effects = {},  stilla_execution = Forbidden
os.open:        effects = { ReadWrite(Host.OS) + Allocate(Host.FileSystem) + MayTrap },
                stilla_execution = Forbidden
builtin.print:  effects = { Write(Host.Output) }, stilla_execution = Forbidden
clock.now:      effects = { Read(Host.Clock), nondeterministic }
unknown host:   Top                        // 无声明
```

立场：

- host 声明是**受信的语义契约**，不是编译器自动验证出的 purity；错误声明是
  host 的 bug。它作为 embedding ABI metadata，**不进 Stilla source syntax**；
  扩展点是 host_bind 的 typed registry。
- **缺失声明默认取完整 `top`**（含 read 通配、`may_trap`、`may_diverge`、`Q`）。
- **读的可观察性是声明项**：默认域 / op 的 `Read` 视为**非可观察**；宿主把
  「读本身有可观察后果」的访问声明为 `Write` 或可观察读。

### 重入契约（host 与模块常量）

**问题。** `host_top` 剔除 `Read(ModuleConst)`，其 soundness 完全取决于一句话：
这个 host binding 不会执行 Stilla 代码。编译器证明不了这件事——host binding 是
embedding 的任意代码，而 interpreter-vm.md / host-bindings.md 把「异步 / 重入
host 调用」列在当前范围之外只是范围，不是「永远不会发生」的保证。所以它是**受信
声明**，不是编译器推出的事实。

- **`Unknown`（缺失声明的默认）与 `MayExecute` 都取完整 `top`**：未知回调要
  覆盖**全部**效果——资源、`may_trap`、`may_diverge`、`Q`、以及
  `Read(ModuleConst)` 通配。§7 的 module-const 检查按「可能读任意较晚常量」拒绝。
  唯一的例外是 `MayExecute` 带**穷尽回调契约**时的调用点收紧（见下文
  「回调参数化摘要」）。
- **只有显式 `Forbidden` 才让声明逐字生效。** `Forbidden` 的语义要覆盖「执行
  相关 Stilla 代码的**所有**通道」。
- **单一事实。** 读集就是 `EffectSummary` 里的 `Read(ModuleConst)`，**不另设**
  独立读集字段。ABI 层只需要一个**稳定符号键**——`<模块限定名>.<成员名>`——
  作为序列化形式：`effects.HostDecl` 按符号声明，会话开始时经
  `HostEffects.resolve` 解析成 `HostBindingId`；符号指不到 binding 的声明被忽略。
- **编译与运行必须用同一份契约。** **编译器不校验运行时是否真的遵守**——这不是
  runtime 侧的重入设计，只是一份编译器消费的受信声明。
- **重复 / 矛盾的声明** 顺序无关地合并：摘要取 join。attestation 不一致
  （`Forbidden` vs `MayExecute`）降为 `Unknown`（即 `Top`）；回调契约不一致只
  撤销回调参数化（不再收紧），两个 `Forbidden` 声明仍用其 join 摘要——
  `Forbidden` 不查契约。不采用「后来者胜」。

**兼容成本。** 严格默认会拒绝原本合法的程序：模块常量的销毁链里带日志
（`drop(t) { builtin.print(...) }`）属于这一类。迁移方式是让 embedding（含测试
的默认 host）显式声明 `builtin.*` 为 `Forbidden`，而不是把默认放宽。

**待决**（[todo.md](todo.md)）：

- **回调参数化摘要（已落地）。** `.call` 处的 `MayExecute` host 调用若带
  **穷尽回调契约**（`HostDecl.callbacks`：同一次调用内、只经列出的实参位置执行
  Stilla 代码），摘要收紧为 `own ⊔ ⨆ effect_bound(target_i)`，`target_i` 限
  直接 `fn_ref` / 内联 λ；缺契约、越界位置、无有限目标一律 `Top`（精度预算，
  不截断目标集）。契约按调用归因：保存后触发的调用没有该实参，故只能是 `Top`，
  绝不把执行记在注册调用上。`unknown` / `forbidden` 不使用该契约。
- **metadata 不是执行许可。** 即使声明 `MayExecute`，允许 host 真正重入还需要
  运行时的安全设计；声明只描述后果，不开启能力。

**缓存指纹（EffectEnvironmentFingerprint）。已落地。** effect metadata 必须
进入 phase-2/3 结果的缓存键，否则声明从 `Pure` 改成 `Write(OS)` 后，旧缓存里按
`Pure` 优化的代码会变得 unsound。`effects.Environment` 把 host 语义 registry 的
generation / 版本、effect-domain 注册表（`domains`）与 `stable` / `disjoint`
关系、以及**本次的 host 声明集合**（含回调契约）折叠为一个指纹；编码显式且
规范：集合排序、整数定宽小端编码、符号带长度前缀、每个摘要行先规范化，不 hash
原始结构字节、指针或会话内 interner id。`frontend.Options` 携带
`host_registry_generation` / `effect_domains`（仅指纹用）与 `resources` /
`host_decls`（后两者进入 `hir_effects.Config` 并影响结论）；`frontend_cache.zig`
记录最近一次编译的指纹，暴露 `SemanticKey`（specifier + 内容 hash + 指纹）并按
转换计数。

**解析缓存不受影响。** frontend_cache.zig 只缓存**解析产物**（`ast.Program` /
`ast.Source`，按内容 hash + 逐字节比对校验），解析不依赖 effect 环境，故指纹变化
不丢弃任何 `Entry`；指纹只是「缓存 phase-2/3 结果」的语义键。

## 14. 模型范围与验收

**最小范围**（固定乘积格与保守查询，不做通用 lattice 引擎）：

```text
MayTrap（含 panic）+ MayDiverge + nondeterministic
+ 不跟踪 may_return_normally（正常返回为默认假设，见 §5.4）
+ Host(resource, Read/Write)     // resource = 抽象域
+ ModuleConst(Read)
+ OperandUse 独立（move/borrow/consume 不进 EffectSummary）
```

用它驱动三个 pass：**dead-let、selective ANF、SEG-safe**。

**当前实现**（模型 effects.zig，HIR 集成 hir_effects.zig）：

- 固定乘积格：每模式的规范化访问行 + `All` 通配；`join` / `sequence` / 内部
  `latticeMeet` / `le`；`Pure == Bottom` 与 `Top` / `host_top`；行与摘要
  interner；`Pending | Ready(EffectSummaryId)` 查询门。
- transfer 按 descriptor 的 `own_effect` + `TransferKind` 组合 operand / region
  / callee；`OperandUse` 由 `UsePolicy` + callee 签名 / operand capability 逐
  occurrence 解析。
- 函数摘要：调用图建在可解析目标上（直接 `fn_ref`、§9.2 局部收窄得到的有限
  目标集；不可证明的未知 Stilla 目标不进图 → `Top`；host 目标只在显式
  `StillaExecution.forbidden` 声明下用声明的摘要，否则 `Top`），Kosaraju +
  callee-first Kleene 迭代（递归 SCC 播种 `Diverge`，同 SCC 读 `cur`、已完成读
  final）；`drop` 把类型的 hook 接入调用图。`validate`
  重跑同一 fixpoint 后拒绝低报 callee 摘要的节点注解。
- `drop_effect(T)` 全链：Copy → `{}`；struct 自身 hook `;` Unique 字段逆声明序
  递归；union 候选 `⊔` + payload 逆序；tuple 逆序；`list` / `box` 元素递归；
  opaque → `Release(Host(host_id))`；递归类型取 least fixpoint；`any` /
  `hostdata` / 未解析仍保守 `Top`。
- cleanup 走已落地的 full-expression footprint（§11.2）：builder 的清理登记步骤
  按语句 / let 初始化器切分 FE，为不转移的 Unique 值产生节点登记 `CleanupToken`；
  `cleanupEffect` 把子树内各 token 的 `drop_effect(T)` 逆创建序折叠，
  `observedEffect` / `canFloatAsTree` 消费它。未建模 program
  （`cleanup_modeled=false`）与含 Unique region 绑定的子树回 `null` → `Top`；
  `cleanupFree` 保持字面 cleanup-free 证明不变。
- 未知目标：无法由 §9.2 收窄的间接调用 / 缺失函数摘要 / 缺失 host 声明取完整
  `Top`；host 声明经
  `frontend.Options.host_decls`（符号键）→ `HostEffects.resolve` →
  `consolidate` 解析；带回调契约的 `MayExecute` host 调用按
  `own ⊔ ⨆ effect_bound(target_i)` 收紧（见 §13），`collectCallees` 同步把
  实例化目标并入调用图。
- `EffectEnvironmentFingerprint`：`effects.Environment`（host 声明集合 + host
  语义 registry generation + effect-domain 注册表（`domains`）与 `stable` /
  `disjoint` 关系）经排序规范化、逐字段小端编码折叠为指纹，
  `frontend.Options` 携带 `host_registry_generation` / `effect_domains` /
  `resources`，`frontend_cache` 记录最近一次编译的指纹与 `SemanticKey`
  （specifier + 内容 hash + 指纹），并按转换计数（解析与 effect 环境无关，
  故解析缓存不失效；指纹是缓存 phase-2/3 结果的语义键）。
- host_bind typed registry 接线：模块结构体的 `effects` 表（`MemberEffects`）
  由 `register` 在 comptime 序列化为 `<module>.<member>` 的 `HostDecl`，
  `declarations` 导出所选 registry 的声明，`buildProgram` 把它接入
  `frontend.compile`；未声明的成员保持 unknown（绝不从 Zig 签名推断纯度）。
- `stable` 域与 `disjoint` 对按 §5.5/§5.6 实现，未声明的不同资源对按冲突处理。
- `canMove` 尚未暴露；`canSwapOperands` 组合父节点 operand 位、full-expression
  边界、两 operand 的 cleanup / ownership 门，再经 `orderCompatible`。
- 隐藏操作审计（未建模但可能有非 pure 行为者一律 `Top` / `MayTrap`）：值位置的
  模块链叶子（`access_hops` 非空）取 `Top`；`let` / `match` 的 pattern 在 HIR
  无节点，transfer 显式序列化其效果：只有 list pattern 非 total（元素访问 lowering
  为边界检查的 `read_index` / `split_list`），其余类别为 total。
- 查询组合按 §10.1 强约束；注解校验先清 per-node memo 再重算摘要，故校验是同
  逻辑的新推导。
- module-const 检查在 `Analysis.checkModuleDependencies`；checker 的 AST 级
  `InitOrder` 已删除。

**MVP 前置条件（不能延期）**：

- 实现 Bottom/Pure/Top、join 与顺序组合，以及 Pending/Ready 查询门；
- 接入 cleanup-aware legality：只有已证明无清理，或已获得保守清理摘要并通过
  相关查询，才允许删除、浮动、复制或 SEG 准入；MVP 可只优化**已证明
  cleanup-free** 的子树，不能仅检查根结果是否 Copy；
- **缺失函数摘要、未知 callee、缺失 host 声明一律使用 `Top`**（§13）。尚未实现
  的精化只降低优化覆盖率，不降低保守性。

**验收标准**：

- 三个 pass 的**合法性判定**没有 `switch(op)` 特判——合法性一律来自派生查询
  （规则匹配层的 applicability 按 typed opcode 分派，§10.3）；
- **negative tests**：`let x = 10/y in 0` 不许删 x；`host.read() * 0` 不许变 0；
  `div.i32` 不许进 SEG；带可观察 / 未建模 drop hook 的临时值不许被 DCE
  （纯析构的临时量经 footprint 可判 discardable，是预期精化）；
- **Q 与 discard 的正 / 负例**：`let x = clock.now() in 0 → 0` 合法；
  `duplicable(clock.now()) == false`、两处同形 `clock.now()` 不许合并；宿主把某
  读声明为可观察读后，同形的 `let x = that_read() in 0` 不许删；
- 条件 panic 的函数调用不许被 DCE；有副作用的 callee 表达式必须先于实参执行且
  不能丢失；未知 cleanup 不许被删 / 浮动 / 复制或进入 SEG；Bottom/Pure/Top 与
  组合满足 §5.4 的代数验收例；另含 `;`/`⊔` 同式与摘要层交换的正断言、「摘要
  相等不单独放行任何程序级交换 / 删除」的负例，以及 `stable` 域读对在整体
  `Q = 1` 表达式中的边界用例（§5.5）。

**里程碑映射**：M1a / M1b / M2a / M2b 见 [hir.md](hir.md) §11。三个消费者判定
均由派生查询驱动、无 `switch(op)` 合法性特判；上述验收例由 effects.zig /
hir_effects.zig / hir_simplify_tests.zig / hir_seg_tests.zig 的正负例覆盖。
未落地项、依赖与验收条件见 [todo.md](todo.md)。

## 15. 开放问题与现状核对

**开放问题**（待决项与验收条件见 [todo.md](todo.md) 的「待决」节）：

- 域间 overlap / disjoint 声明的具体条目：形式见 §5.6，内容随真实 host 域出现
  后按需补全。
- teardown 检查的链与措辞（§7.2）：Core 现措辞只约束「hook 及其传递调用」，字段
  / 容器元素级 hook 的读与 Copy 常量的 teardown 期读取均未表达。待规范澄清后
  回填本节与 checker 行为。
- host 重入契约（§13）：**已定并落地**——缺失 = `Unknown` 取完整 `Top`；只有
  显式 `Forbidden` 才让声明逐字生效。回调参数化摘要与
  `EffectEnvironmentFingerprint` 缓存指纹均已落地（见 §13 与 [todo.md](todo.md)
  的「已完成」第 2 项）；运行时侧契约校验刻意不在范围内。

**现状核对（哪些特设实现已被本文派生查询取代）：**

- **module-const 依赖检查**：checker_validate.zig 的 `InitOrder` 曾是 AST 级
  特设 walker，现由 `hir_effects.Analysis.checkModuleDependencies` 取代——用函数
  摘要的 `Read(ModuleConst)` 集与 `drop_effect(T)` 全链判定，`InitOrder` 已删除。
- **CFG/AIR 的 per-op schema**：cfg.zig 的 op schema 仍有一份 `may_trap` /
  `effects` 两位（派生查询为 `pure()`）；它是 op 级保守位，缺少 typed 精度与
  资源域。本文的 typed-opcode 摘要是对它的精化与统一，按**显式分层**处理：
  HIR 的 typed 行按具体 rep 写死，**不要求**与 CFG 粗粒度位逐位相等（CFG 故意
  过度近似 float 除法）；registry 启动校验只断言 HIR 行自身的 typed 一致性。
- **现有 pass（dead-instr 等）** 仍以 schema 位白名单做判定——正是本文想用派生
  查询替代的形态。
