# Stilla Effects System — 语义交互摘要模型

> **Status：M1b（效果基础设施）已实现；三个消费者 pass 与 SCC
> fixpoint 仍为设计提案。**
>
> 本文为编译前端与优化器定义一个内部的**效果语义模型**（effect
> semantics model）：用一个统一的结构描述「一个表达式求值时，与表达式
> 之外的语义状态发生了哪些交互」，并用它替换当前散落在各 pass 里的
> 特判规则（求值顺序、trap/panic、host 调用、module constant 依赖、
> drop、函数调用摘要、SEG 准入）。**§5 的格与 §10–§11 的查询门已随
> M1b 落地（`effects.zig` / `hir_effects.zig`，见 hir.md §11 M1b 交付
> 记录）**；§6 的 `effect_transfer`、§10.1 的派生查询、§11 的 cleanup
> 门亦已实现。§12 的三个消费者 pass（dead-let / selective ANF /
> SEG-safe）、§8.2 的函数 SCC fixpoint、§7 的 module-const 检查与 §13 的
> host ABI metadata 接线仍为提案，未进入代码。
>
> 配套文档：使用该模型的中间表示（HIR）设计见 [hir.md](hir.md)；本文自含
> 效果模型所需的全部定义，不依赖其章节细节。两者的重叠概念（求值序、
> 值使用、效果）在本文给出权威定义，HIR 侧保留一份便于阅读的自含摘要。
>
> 规范依据（追踪 v1.3 草案）：Core Module Constants（初始化与 teardown
> 的对称依赖规则）、Core（不捕获、顺序无关与互递归）、
> Types & Ownership（Copy/Unique、参数模式、借用、临时量）、
> Runtime（初始化与逆序 teardown）、Runtime（求值序）、
> Runtime（确定性销毁）、Runtime（trap 与数值行为）、
> LLIR Instruction Set（`cvt` 转换语义）、air.md（drop 语义与校验）。

## 1. 问题

### 1.1 一位 `pure / impure` 不够

很多编译器把表达式标成 `pure / impure` 两个位，再据此派生一批互相打架
的布尔标志（`is_pure`、`has_side_effects`、`can_speculate`、
`is_safe_to_remove`、`can_duplicate`）。每加一个优化 pass，就要为这些
标志各自补一套规则，而这些规则往往只能靠 `switch(opcode)` 白名单硬编码。

Stilla 需要区分的东西远多于一位。一个表达式「有没有副作用」回答不了
下面这些问题：

| 需要区分 | 例 | 单一位表达不了的原因 |
| --- | --- | --- |
| **trap / panic 与正常返回** | `10 / y` 除零 trap | 需知求值**可能异常终止**，且异常终止时不跑清理 |
| **host 访问的是哪个资源域** | `os.read` 与 `audio.get_volume` | 同为「host 调用」，前者写文件、后者读音频，可交换性不同 |
| **module constant 依赖方向** | 初始化/teardown 读较早/较晚常量 | Core 规则是**跨函数 transitive** 的，按函数/依赖序判定 |
| **drop 是否可观察** | 带 `drop` hook 的临时值 | drop 有可观察效果，不等价于「无副作用」 |
| **求值顺序** | `a() + b()` 必须 a 先 b 后 | 语言语义（从左到右、恰好一次），不是可从效果推的 |
| **是否非确定** | `clock.now()` | 两次求值结果可不同，影响 CSE / 复制 |

### 1.2 想统一的那些散落规则

目标是把以下「靠 op 特判」的前端判定统一成**由同一模型派生的查询**：

1. 求值顺序、trap/panic、host 调用、module-const 依赖、调用摘要不再
   各自特判；
2. Core 的模块初始化与 teardown 两条对称依赖规则由同一份函数摘要
   驱动；
3. dead-let、selective A-Normal Form、SEG-safe、CSE/DCE 的合法性全部
   **派生**出来，而不是 `switch(op)` 白名单。

### 1.3 非目标

- **不做 source-level effect type**（如 `fn(int32) -> int32 !{IO}`）：
  语言类型保持 `fn(int32) -> int32`，效果摘要只是编译器内部的
  metadata / refinement，不进入语言。
- **不做低层内存效果**（别名、store buffer 一类）：资源是**抽象语义
  资源**，不是地址。
- **不做可扩展的通用 lattice 引擎**：用一套固定的乘积格即可（见 §5.4），
  只覆盖有限的几种 mode 与 `Host(resource, Read/Write)` +
  `ModuleConst(Read)` 这一小集。

## 2. 解决方案概览

### 2.1 一句话

> **EffectSummary = 一个表达式与表达式之外的语义状态发生了哪些交互。**

表达式内部的词法 / 数据流（`read local x`、`move local x`、
`borrow local x`）**不进入** EffectSummary——它们属于 ownership /
数据流维度（Unique 至多 move/drop 一次、borrow 不转移 ownership，由
独立维度负责）。EffectSummary 只描述「越出表达式边界」的交互。

### 2.2 一个 op 的语义是四个正交维度

不要把效果与其它语义塞进同一个集合。一个 HIR op 的语义按四维正交组织：

```text
HIR semantics(op) =
    Type                // capability（Copy/Unique）与具体类型
  × EvalPolicy          // 求值顺序：语言语义（§3）
  × OperandUse         // 每个 operand 的值使用 / ownership（§4）
  × EffectSummary       // 与表达式外部语义状态的交互（§5）
```

四个维度各自的职责与归属：

| 维度 | 回答什么 | 归属 | 关键区分 |
| --- | --- | --- | --- |
| `Type` | 值能复制吗、具体类型 | 类型系统 | Copy / Unique |
| `EvalPolicy` | 子表达式以什么顺序、求值几次 | op descriptor | 语言语义，与效果正交 |
| `OperandUse` | 这个 operand 是被读、借用还是 consume | operand 位 | 每个 operand 一个 |
| `EffectSummary` | 求值会与外部状态交互吗 | 节点 interned 摘要 | 资源访问 + 控制位 |

两个说明正交性的关键例子：

- `move.effects == {}` 完全合理：move 的重要语义是 `OperandUse = Consume`
  （linearity 属于 ownership，不是 runtime effect）；
- `builtin.print(...)` 是 runtime effect，但未必 consume 参数。

### 2.3 EffectSummary 长什么样

```text
EffectSummary {
    accesses:  EffectRow,     // 资源访问集合（∅ / All，见 §5.4）
    may_trap:  bool,          // 可能异常终止（含 panic）
    may_diverge: bool,        // 可能发散（非终止调用 / 递归）
    nondeterministic: bool,   // 两次求值结果可不同
}

EffectAccess { resource, mode }     mode = Read | Write | Allocate | Release
```

资源是抽象语义域而非地址（`ModuleConst(C)`、`Host(域)`、
`Runtime(域)`、`Extension(ProviderId, ResourceId)`、`Top`）。典型行：

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
`is_pure = true` 这类布尔。所有优化属性由查询函数从摘要推导：

| 属性 | 判定要点 |
| --- | --- |
| `total` | `!may_trap ∧ !may_diverge` |
| `observable_effect_free` | 无 `Write/Allocate/Release`、无未知资源（Top）；资源**读**默认不构成可观察交互（Q 不在此判定内，见 §10.1） |
| `discardable` | `total` + 无可观察效果 + 清理上下文下 `discard_view(observed_effect) == Pure`（§11，忽略 Q）+ ownership 门——**不要求 !Q** |
| `duplicable` | `discardable` + 结果 Copy + operand 全 `Read` + **无 Q**（求值可重复） |
| `speculatable` | `total` + 无有序 / 可观察效果 + **无 Q**；**上下文属性**：可移动性相对移动目标判定，不是表达式自身属性（§10.5） |
| `reorderable(a,b)` | **位置上下文**：sibling 对能否交换由父 EvalPolicy + operand 位判定（§10.5）；输入是资源访问无冲突 + 无顺序可观察差异 |
| `seg_safe` | Copy + total + 无可观察效果 + 无 Q（结果稳定）+ cleanup 安全 + 递归子树同判 + ownership 门 |

每个查询都组合「效果 × operand uses × 结果 capability/view × ownership /
lifetime 门」——`move.effects == {}` **不**使 move 变得 discardable /
duplicable / speculatable，缺一不可（详表见 §10.1）。注意 `speculatable` /
`reorderable` 两行不是表达式自身的 unary/binary 属性：**能否 speculate /
重排是相对「移动到哪里」的上下文属性**，查询须参数化目标位置（§10.5 的
`canMove` / `canSwapOperands`），本节表格只为可读性保留简写。

### 2.5 模型消费方与文档导航

这套模型的用户（也是它「有没有价值」的判据）：

- **dead-let / selective ANF / SEG 准入**：用 `discardable` /
  `can_float_as_tree` / `seg_safe` 派生判定，替代 `switch(op)`（§12）；
- **module constant 依赖检查**：用 `Read(ModuleConst)` 读集驱动 Core
  两条对称规则（§7）；
- **优化重写合法性**：所有 rewrite 的效果要求走统一接口（§10.3–§10.4）。

阅读顺序：先读 §3–§5（求值序、值使用两个语义维度 + 效果核心模型），再读 §6（效果在
表达式上怎么组合）、§7–§9（module 依赖与函数调用摘要）、§10（派生查询）、
§11–§12（销毁可观察性与效果驱动的前端变换）、§13–§14（host metadata 与
模型范围/验收）。

## 3. EvalPolicy：求值顺序维度

Stilla 规范规定子表达式**恰好一次、从左到右**求值（Runtime）。因此
`a() + b()` 即便 `effects(a) = effects(b) = {}`，语义仍是 a 先 b 后。
求值顺序是**语言语义**，效果摘要是**优化 legality 事实**，二者不互相
归约。

EvalPolicy 是 op descriptor 上的属性，描述该 op 的子表达式如何求值：

```text
EvalPolicy =
    StrictLTR     // operands 按序恰好一次（call / add / struct / tuple / list …）
  | ShortCircuit  // and / or：第二个 operand 按条件才求值
  | Branch        // cond 先；只求值一个 region（if）
  | Match         // scrutinee 先；只求值一个 arm region（match）
  | Region        // region 体按需/延迟求值的其余情形（descriptor 自声明）
```

两个要点：

- **region 是惰性分支**：`if` / `match` 的 region 体只在被选中时求值；
  `call` 与聚合构造的 operands 全部求值且 LTR。两者合起来，求值顺序与
  求值次数由**结构**决定。
- **可交换是可证明的派生事实**：effect 分析可能证明某两个 operand 可
  交换（`reorderable`），但**语义默认仍保持 LTR**；要利用交换的重写，
  必须走显式的 `reorderable` 查询，不能用「两者摘要相等」来推断。

## 4. OperandUse：值使用 / ownership 维度

每个 operand 声明一个值使用模式（occurrence 级）：`Read` / `Borrow` /
`Consume`。ownership 的 law（Unique 至多 move/drop 一次、borrow 不转移
所有权）由独立维度负责，不进入 EffectSummary。

**术语（全文统一，废除 `UseKind` / `UseMode` 两套旧名）**：

```text
OperandUse = Read | Borrow | Consume    // 一个具体 operand occurrence 如何消费值
BinderMode = Value | Move | Borrow      // 源级 parameter / binder 契约（hir.md §3.4）
```

`OperandUse` 是 operand 位的 occurrence 事实（每个 operand 一个）；
`BinderMode` 是声明侧契约（`move` 参数 / consuming pattern 绑定为 `Move`、
borrow 参数为 `Borrow`，定义见 [hir.md](hir.md) §3.4）。两者分层，不再
有第三套 `CopyRead / Move` 词汇。

```text
move         uses = [Consume]    effects = {}
borrow       uses = [Borrow]     effects = {}
add.i32      uses = [Read, Read] effects = {}
drop File    uses = [Consume]    effects = drop_effect(File)   // §11
```

结论：`move` 是 **linear effect** 但不是 **runtime effect**；`print` 是
runtime effect 但不一定 consume。两者正交。

结果侧还有 capability / view 规则（`result_policy`：Copy 结果、借用视图、
销毁视图等），它与 operand 的 use 共同构成 ownership 门，被 §2.4 的每个
派生查询消费。本文不展开 view 的完整数据流——那是所有权系统的事；效果
模型只要求在派生查询里**组合** ownership 门，不代为实现它。

## 5. EffectSummary：资源访问 + 控制摘要

### 5.1 结构

```text
EffectSummary {
    accesses: EffectRow,       // 访问集合的规范化存储；∅ / All 见 §5.4
    may_trap: bool,
    may_diverge: bool,
    nondeterministic: bool,    // 同式两次求值结果可不同（clock/random/volatile）
}

EffectAccess { resource: EffectResource, mode: EffectMode }

EffectMode =
    Read
  | Write
  | Allocate
  | Release
```

控制摘要使用 **may 语义**——所有实际结果必须被收敛后的摘要覆盖：

```text
may_trap      可能异常终止，包含 panic 和 trap
may_diverge   可能发散（非终止调用 / 递归 SCC，见 §8.2）
```

**effect 层中 panic = trap**：二者都置 `may_trap = true`；运行时都不
正常返回、跳过销毁。此合并只服务于优化合法性，不改变 Runtime / Core 里
的指令、诊断或终止行为；不另设 `may_panic`。

### 5.2 资源是抽象语义资源，不是地址

```text
EffectResource =
    ModuleConst(ConstId)             // 模块常量槽（§7）
  | Host(HostDomainId)               // host 域：Output / FileSystem / Clock / OS / GPU …
  | Runtime(RuntimeDomainId)         // 运行时域（如执行上下文存储）
  | Extension(ProviderId, ResourceId) // 扩展模块/宿主扩展绑定自注册的域
  | Top                              // 未知资源（TOP 摘要用）
```

资源间的关系不能只按 Id 判等——两个域是否重叠需要一张 alias/overlap
表（§5.6）。

### 5.3 摘要层记法

`{}` **只表示 `Pure`**；`{ MayTrap }` 等简写是在 `Pure` 上增加可能
效果（故除法仍可能正常返回）；无条件 panic 的摘要即 `{ MayTrap }`。

### 5.4 乘积格、偏序、join/meet 与顺序 / 候选组合

**格与偏序。** 设 `K` 是本轮分析已注册的有限资源 Id 集，`M` 是固定的
四种 mode。每个 mode 的资源集合格为 `P(K) ∪ {All_m}`：普通集合按包含序
排列，`All_m` 严格高于所有普通集合（包括 `K` 本身），并覆盖未知 / 后续
资源。`AccessSet = ∏(m ∈ M) (P(K) ∪ {All_m})`，join/meet 按 mode 做
并/交：`All_m ∪ S = All_m`、`All_m ∩ S = S`。下文把集合写成访问原子
`(resource, mode)` 的行；`∅` 表示所有 mode 为空，`All` 表示所有 mode
均为 `All_m`。

行的排序只为规范化与 interning，**不表示执行顺序**。`Read(Top)` 是
Read 分量的 `All_Read`，不能当作与具体资源不相交的普通原子；缺失摘要
直接使用完整 `Top`。资源 overlap 只影响冲突查询，不改变格的包含序；
普通域 Id 按标识集合计算，Top 才按通配规则计算。

```text
E = (A, T, D, Q)
    A = accesses     T = may_trap
    D = may_diverge  Q = nondeterministic

L = AccessSet × Bool × Bool × Bool
E ≤ F  iff  A_E ⊆ A_F 且每一布尔位 E_i ≤ F_i（false ≤ true）
E ⊔ F  = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
E ⊓ F  = (A_E ∩ A_F, T_E ∧ T_F, D_E ∧ D_F, Q_E ∧ Q_F)

Pure = (∅,   false, false, false)   // 格底，兼「已证明纯」见下）
Top  = (All, true,  true,  true)    // 所有资源、控制与非确定性均未知
```

`All ∪ A = All`、`All ∩ A = A`。`⊔` 是候选路径 / 目标的最小上界，`⊓`
是最大下界，二者满足交换、结合、幂等与吸收律。只有每个输入都覆盖实际
行为时，meet 才能用于**合并独立证明**，不能拿 meet 代替分支 join。实现
可用按 mode 的通配行表示集合；对当前分析固定有限的资源注册表与 mode
集，格为有限高度，新资源注册后须失效重算。未知资源始终保留通配，不得
因当前注册表中没有对应项而消失。

**meet 不进入业务 API**：`⊓` 的公式与格律保留给 law test（内部
`latticeMeet()`）；优化 / 分析查询面只暴露 join、sequence、conflict 与
投影。meet 只有在「两个独立 sound proof 都覆盖实际行为」时才有意义，
极易被误用成合并 control-flow 的 join——等出现真实 consumer 再开放。

**摘要不跟踪 `may_return_normally`。** 正常返回是默认假设，格不携带
「必然不返回」信息（panic 在 effect 层已并入 `may_trap`，无单独的
panic-return 摘要事实）。`Bottom` 与 `Pure` 同值
（`(∅, false, false, false)`，格底）；「推导下界 ≠ 已证明纯」的区分由
§8.2 的 `Pending` / `Ready(summary)` 状态机承担（不在格内）——`Ready`
下的 `(∅, false, false, false)` 才是已证明纯。后缀 DCE 的合法性由独立
的 must 事实 `never_returns` 恢复（§10.1）：摘要代数不变，`;` 合并仍
保守并入后缀位；优化器先按 `never_returns` 删除调用后同一直行区域内的
不可达后缀，并入的位随之消失。

**顺序组合与候选 join：语义角色不同，may-公式同式。**

`E ; F` 表示先求值 E、只有 E 正常返回才求值 F；`E ⊔ F` 表示二者是候选
（二选一）。两者的**语义角色不同**，但当前 may-摘要的公式完全相同：

```text
E ; F = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
E ⊔ F = (A_E ∪ A_F, T_E ∨ T_F, D_E ∨ D_F, Q_E ∨ Q_F)
```

访问集合、非确定性位与控制位都保守地并入整个后缀 / 候选，即使后缀
不可达或候选未选中；它们只会阻止更多优化，也保留 module-const 依赖
检查所需的保守读集合。不再按正常返回门控后缀——正常返回是默认假设，
故 panic/发散之后代码的控制位一律并入（纯精度损失）。

**may-摘要遗忘顺序。** 上式全部由并/或构成，因此作为集合运算
`E ; F == F ; E`——`;` 与 `⊔` 同式、可交换、结合、幂等，`Pure` 是左右
单位元兼格底，**不是**顺序组合的零元。这只说明摘要不携带顺序信息，
**绝不**表示 `a(); b()` 与 `b(); a()` 两个程序可互换——具体执行序列的
语义由 EvalPolicy 与程序结构持有。优化器不得据「摘要相等」交换或改变
实际求值次数；程序级可交换一律由 `reorderable(a, b)` 查询判定
（§10.1）。descriptor 仍必须按 EvalPolicy 写出真实的组合结构（顺序用
`;`、候选用 `⊔`，角色不得混用）：这是模型的保真性要求——未来引入顺序
敏感事实（must 类、清理精确化）时，二者将再次分化。

组合法则：分支摘要为 `effects(cond) ; (effects(then) ⊔ effects(else))`；
有限 callee 集用 join；有序 drop/cleanup 用 `;`。空 join（无候选路径，
不可达）与空顺序（零步执行）同值于 `Pure`。

**total 与最小代数验收例。** 正常终止、异常终止、发散覆盖全部执行结果，
故对**已完成且保守**的摘要，`total = !T ∧ !D` 保证必然正常终止；`Pending`
中间近似不能参与此查询（不在格内，查询失败关闭，见 §8.2）。

```text
Panic   = (∅, true,  false, false)
Diverge = (∅, false, true,  false)

Panic ⊔ Pure                 = (∅, true, false, false)      // 不 total
Panic ; Pure                 = Panic
Panic ; Diverge              = (∅, true, true, false)       // 后缀控制位并入
Diverge ; Panic              = (∅, true, true, false)       // 顺序差异不再可表达
Pure ; E = E ; Pure          = E
Pure ⊔ E                     = E                            // Pure 是格底
Pure ; (Panic ⊔ Pure)        // 条件 panic，不 total；调用摘要也必须保留 T
```

实现时除上述例子外，还须检查 join/meet 格律、两参数的单调性、`;` 与
`⊔` 的同式及摘要层交换（`E ; F == F ; E`），并配负例：**摘要相等不得
单独放行交换/删除/复制**——程序级变换必须组合 `reorderable` /
`discardable` 等门；另测异常终止后资源访问仍被保守保留。

### 5.5 nondeterministic 与域稳定性

`clock.now()`、随机数等两次求值可给不同结果：置 `nondeterministic =
true`。它阻断 `Read(R) vs Read(R)` 的 commute 与 CSE（同形合并），也
阻断 duplicable；**不阻断 discardable**（删除未使用结果与 Q 无关：结果
不稳定只影响被丢弃的结果，§10.1）。与「稳定读」区分对待，不当作普通
Read 参与 Read/Read 交换。

**表示位置**：`nondeterministic` 放在摘要控制位 `Q`，不做 access 级或
域级标注——位版本让 join/interning 零改动，并能覆盖无法绑定到单一资源
的非确定性（如 host 实现相关的 op）。已知精度损失：同一摘要内混有稳定
与不稳定读时（如 `clock.now()` 与 `stat()` 同体），稳定读的 Read/Read
交换被连坐。恢复手段是域级 `stable` 声明；access 级标注仅在其仍不足时
引入。

**域稳定性声明。** host/extension 域声明可**可选**携带 `stable`（默认
mixed）——`stable` 域内所有 op 均稳定（无 nondeterministic）。对声明
`stable` 的域 `R`，Read/Read 交换与 CSE 查询不受摘要级 `Q` 连坐：即使
摘要因其他域（如 Clock）置 `Q = 1`，`R` 上的读对仍按稳定处理。声明只在
查询层消费，格与 interning 不变；mixed 域保持现状（`Q` 连坐）。声明
错误是 host 的 bug（受信契约，见 §13），与 op 级效果声明同级。

`stable` 只细化**资源对查询**（同一 stable 域上两个读的可交换 / 可合并
判定），**不撤销摘要级 `Q` 对表达式整体的否决**：表达式任一子项非确定
（`Q = 1`）时，整体仍不可 duplicable、不可作整体 CSE、不可跨其重排。
`stable` 也不表示跨 `Write` 不变——同一域上夹有写操作的两个读仍按冲突
处理。

### 5.6 冲突、可交换与资源域粒度

**冲突规则。** 这是派生 `reorderable(a, b)` 的输入：

```text
Read(R)  vs Read(R)   => 可交换   （且 R 稳定：无 nondeterministic）
Read(R)  vs Write(R)  => 冲突
Write(R) vs 任何       => 冲突
Allocate/Release       => 与其他域内操作冲突（对同一资源域）
R1 != R2               => 默认可交换，**前提是可证不相交**
```

两条澄清：

- **不同 Id ≠ 自动不相交**：需要资源域的 overlap/alias 关系表。域支持
  通配与 TOP；**未解析的 overlap 一律按冲突处理**（安全优先）。
- 冲突判定是派生 `reorderable(a, b)` 的输入（§10.1）。

**注册表形式。** 域 Id 由各宿主模块与扩展模块在自身 metadata 中声明
（§13），编译会话开始时统一 intern 并在该会话分析期间**冻结**——§5.4
的「新资源注册后失效重算」只适用于冻结前的注册。overlap/alias 表用
**域内层级**（父 ⊇ 子，判包含求公共祖先）加**显式 disjoint/alias 例外
对**表达；层级不同根分支**不**天然不相交，需显式声明或独立证明；
overlap 不具传递性。跨提供方或未声明的对一律按冲突处理（安全默认）——
disjoint 声明是 opt-in 精度：漏声明只少优化、不损 soundness。

**为什么域粒度、而不是单个 IO bit。** 若只有 `HAS_SIDE_EFFECT`，
`audio.get_volume()` 与 `filesystem.stat()` 永远不能互调顺序。带域后：

```text
Read(Host.Audio)      vs Read(Host.FileSystem)  → 可交换
Read(Host.Clock)      vs Read(Host.Clock)       → 不可交换（nondeterministic）
Write(Host.Output)    vs Read(Host.FileSystem)  → 可交换
Write(Host.OS)        vs Read(Host.OS)          → 冲突
```

域注册表（含通配/TOP 与 overlap 表）由宿主模块与扩展模块持有，核心
前端不用改。

## 6. 效果在表达式上的组合

一个 op 的效果由其 descriptor 的 `effect_transfer` 递归汇总得出：按
EvalPolicy 写出真实组合结构（顺序用 `;`、候选用 `⊔`），并处理对 callee
等子结构的查询。表达式内部词法不产生效果。

### 6.1 组合公式

记 `effects(expr)` 为求值该表达式的效果（`eval_effect` 的简写），不隐式
附加当前 full-expression 的清理。`seq(...)` 按实参顺序折叠 `;`，空序列
为 `Pure`：

```text
effects(seq e1; e2)        = effects(e1) ; effects(e2)
effects(call f, args)      = effects(f) ; seq(effects(arg_i), LTR) ; effect_bound(f)
effects(if c, t, f)        = effects(c) ; (effects(t) ⊔ effects(f))
effects(match s, arms)     = effects(s) ; ⨆ effects(arm_i)
effects(a and b / a or b)  = effects(a) ; (Pure ⊔ effects(b))
```

`effects(f)` 是**求出函数值**的效果；`effect_bound(f)` 是**调用所得函数
值**的效果——二者不得互相替代。callee 即便会 print/trap，也必须先于
实参求值；已由 A-Normal Form 绑定的 callee 引用本身可以是 `Pure`。

当前 full-expression 的清理由其边界恰好组合一次：

```text
observed_effect(expr, ctx) = effects(expr) ; cleanup_effect(expr, ctx)
```

内部嵌套的 full-expression 边界仍递归计入各自清理；函数体摘要也必须
包含体内正常退出的自动销毁。**不得给每个 call 重复附加同一清理栈**
（见 §11）。

### 6.2 descriptor 样例

每个 typed op 的效果大多是可静态写死的常量行；少数（`if`、`call`、
聚合）需要递归组合。例：

```text
add.i32
    eval      = StrictLTR
    uses      = [Read, Read]
    result    = Copy
    effects   = {}                    // control: 必然正常返回

div.i32
    eval      = StrictLTR
    uses      = [Read, Read]
    result    = Copy
    effects   = { MayTrap }           // 除零 trap；i32 溢出回绕、永不 trap（Runtime）

move
    eval      = StrictLTR
    uses      = [Consume]
    effects   = {}                    // linear 效果在 OperandUse，不在 effects

host.print
    eval      = StrictLTR
    uses      = [Read]                // 视签名；不 consume
    effects   = { Write(Host.Output) }

if
    eval      = Branch                // cond 先；一次只求值一个 region
    effects   = effects(cond) ; (effects(then) ⊔ effects(else))
```

### 6.3 typed opcode 的效果表

类型专门化后的 opcode 让 descriptor 可以表化——每个 typed op 的摘要基本
是静态常量。这也是数值 trap 语义只写一处、随 spec 演化自动正确的关键：

```text
add.i32 / mul.i32 / add.i64 …        {}                 // wrapping 语义、无 trap
div.i32 / rem.i32                     MayTrap            // 仅除零（Runtime：min/-1 回绕，不 trap）
div.i64                               MayTrap            // 除零 + int64_min / -1（Runtime）
rem.i64                               MayTrap            // 仅除零（int64_min rem -1 = 0）
u32/u64 的 div 与 rem                  MayTrap            // 仅除零（无符号无溢出情形）
div.f32 / div.f64 / rem.f32 …         {}                 // IEEE 754：x/0.0 得 ±inf/NaN
num_cast（数值转换）                    {}                 // LLIR cvt：截断/就近舍入，永不 trap
any 恢复（any → T 不匹配）              MayTrap            // Runtime：invalid any recovery
host binding 调用（call → syscall）     TOP 或 host metadata
```

两点澄清：

- **数值转换永不 trap** 依据 LLIR Instruction Set 的 `cvt` 定义
  （integer↔integer 截断、int→float 就近舍入等）；即便如此，每个 typed
  转换 opcode 仍走 descriptor，便于未来 spec 变化或新转换域。
- **整数型代数恒等式与 float 准入分离**：float 可进 SEG 不代表整数规则
  （如 wrapping 位恒等式）自动适用于 float；SEG 规则集按 typed opcode
  写死合法性。

## 7. Module constant 依赖（Core 两条对称规则）

把 module constant 读放进效果框架，直接统一规范的两条对称规则（Core
Module Constants）。

### 7.1 初始化顺序限制（含跨函数传递）

> 初始器只可引用较早声明的模块常量；**不得 transitive 调用一个会读取
> 声明较晚常量的函数**（Core，编译期拒绝）。

用函数摘要：`Read(ModuleConst(C))` 集合 + 按**已解析的模块身份与其
初始化/销毁 schedule** 判定（不是跨模块的全局 `const_index` 大小比较；
同一模块内按声明序，跨模块按依赖序与 schedule，Runtime）。模块
常量初始器的检查变成：

```text
对 effects.reads(ModuleConst) 中每一项 C：
    要求 C 在本模块声明序中先于当前初始器，或属于已初始化模块
```

间接调用若含未知目标（`Read(Top)` 可能指向较晚常量），按最坏假设拒绝
或要求独立证明（不能把未知 read set 当空，见 §9.4）。

**规范归口（Core）**：规则禁止的是初始化期可证明地观察较晚常量；
对目标不可判定的调用（间接调用 / 未知回调），编译器按最坏假设处理并
拒绝。放行仅经两条通道——**编译期证明**（§9.2 的目标收窄是 sound 的决策
过程）或 **embedding host 声明**（§13，受信契约，声明 callable 的模块
常量读集合）。teardown 检查（§7.2）同此归口。

语言级检查的判定对象是**源程序形态**（checker 阶段先行完成）；HIR
优化（死代码消除、常量折叠、内联）不得作为规避通道——先删除含违规读
的路径再检查不构成放行；变换后的重验证必须在新程序形态上从头进行。

### 7.2 teardown 的对称限制

> teardown 按**逆声明序**销毁 Unique 常量（Runtime）；某常量的
> drop hook 及其传递调用不得读取已先被销毁的较晚常量（Core）。

检查对象是**完整销毁链**：运行期销毁一个 Unique 模块常量按 Runtime 执行该类型值的结构销毁——hook（若有）之后还有 Unique 字段与
容器元素的逆序销毁；嵌套字段/元素的类型若有自己的 drop hook，同样在
teardown 期间运行并读模块常量，与 hook 本体同一危害类。因此判定用类型
级 `drop_effect(type of C)` 的读集合（§11.1，hook 与结构销毁一并计入），
**不是只查 hook 的读**：

```text
对 drop_effect(type(C)) 的读集合中每一项 D：
    要求 D 在逆序销毁 schedule 中晚于 C 被销毁（即尚未销毁）
```

**现状核对**：现有实现（checker_validate.zig 的 `InitOrder` teardown
方向）只走查类型直 hook 及其传递调用，其注释自认容器元素携带 drop hook
（如 `list[File]` 常量）未走查、延后处理——以完整 `drop_effect` 链判定
即闭合该缺口。

两点与规范措辞相关的待决事项（见 §15）：

- Core 现措辞只提「hook 及其传递调用」，按字面会漏掉字段/元素级
  hook 的读；
- teardown schedule 只含 Unique 常量——Copy 常量从不销毁、teardown 期
  读取并无运行期危害，而 Core 现措辞按字面禁止读一切较晚常量
  （含 Copy）。保留该过保守读法还是收紧为「仅较晚 Unique」待规范决定；
  编译器检查先按规范字面执行。

### 7.3 相关不变量

- **函数引用与初始化序无关**（Core：函数是 monomorphic 代码引用、
  不捕获）：`fn_ref` 本身不产生 `Read(ModuleConst)`；只有函数**体**的
  执行摘要里会含它，且由调用关系推导。
- **未知目标的保守**：间接调用或缺失 host metadata 的读集合取
  `Read(Top)`——在初始化/teardown 检查里 `Top` 与「可能读任意较晚常量」
  同义，按违反或需证明处理。
- **`module_const(ConstId)` 引用仍非字面量**：读它依赖 module init 已
  按 schedule 执行。只有该 const 的求值已被 constant folding 具体化、
  且无可观察的初始化依赖时，才允许折叠；v1 的 SEG 不碰 `module_const`。

## 8. 函数摘要与调用

### 8.1 CallableInfo：效果是内部 metadata

v1 不把 effect 写进 source 函数类型。函数值在编译器内部附带：

```text
CallableInfo {
    signature:    FnTypeId,
    effect_bound: EffectSummaryId,   // 见 §9
}
```

Source 类型仍是 `fn(int32) -> int32`；HIR refinement 才是
`fn(int32) -> int32 + effect_summary`。未来若加 source effect typing，
直接建在这层上；摘要保持内部、不进语言。

### 8.2 SCC least fixpoint（含递归发散）

函数体摘要在模块/调用图上推导。允许 direct 与 mutual recursion
（Core），因此在函数 call graph 的 SCC 上做 least fixed point：

```text
E_f := Bottom                          // 对 SCC 中每个函数
seed_f := Diverge if recursive_SCC(f) else Bottom
repeat simultaneously:
    next_f := E_f ⊔ seed_f ⊔ summary(body_f, current_callee_summaries)
    E_f := next_f
until stable
```

`summary` 按 §5.4 组合：有序求值用 `;`，候选分支/目标用 `⊔`；函数体的
正常退出清理也计入。注册表在本轮推导期间固定，单调 transfer 与有限高度
保证收敛；这求的是加入递归保守 seed 后的最小不动点。

- **调用图构成**：SCC 建在分析实际使用的调用图上，含经实参传递、已解析
  fn-ref 可达的**跨模块运行期调用环**——import 图无环只排除模块间静态
  互递归，不排除函数值形成的运行期环。未知目标按 §9.1 取 `Top`、不进
  SCC；目标集精化（§9.2）改变调用图后须重建 SCC 并失效重算。
- **从 Bottom 迭代本身不能发现发散**：`f → f` 必须额外 seed。**递归 SCC
  一律保守标 `may_diverge = true`**，只有另有独立终止证明时才可取消
  seed。递归性来自调用图结构而非摘要位，不能以当前近似推断没有递归。
- **分析状态不属于格**：使用 `Pending` / `Ready(EffectSummary)`；SCC
  内部可以读取本轮近似，但优化器只能使用 Ready。尚未收敛时查询失败关闭
  （阻止变换）——`Bottom` 与 `Pure` 同值，「未推导 ≠ 已证明纯」由
  `Pending` 承担。未知目标、外部摘要缺失或分析放弃时发布 `Ready(Top)`，
  不再混用 Empty/Concrete/Top 表示计算进度。

推导风格与类型系统对递归 Copy/Unique 分类的 least-Copy fixpoint 一致
（Types & Ownership，type_shape.zig 的 `ownershipOf`）。

**例：**

```stilla
fn a() { b(); }                 effects(a) = effects(b) = { Write(Host.Output) }

fn f() { g(); }                 f、g 在同一 SCC：
fn g() { f(); host.foo(); }     两者均 may_diverge = true；访问仍保守含 host.foo
```

### 8.3 失效与重算

摘要在**初始构建**后随 HIR 变换失效并重算（任何变换之后都要对受影响
区域重新验证 ownership 与 effects，不能假定原结论在重写后仍成立）。
失效模型：

- **存储与求解**：函数级 memo 缓存每函数摘要；被改写函数所属递归 SCC
  需重算时**联合重算**——从 §8.2 的种子重新迭代，**不在旧摘要上继续
  join**（重写会减少 effects，增量向上合并永远降不下来）。
- **标脏**：标脏被改写函数，并用世代/版本号阻断一切缓存旧摘要的查询
  （只标脏不够——所有依赖旧摘要的调用者都必须失效或版本检查失败关闭）。
- **传播**：重算后 interned id 与旧值相等即短路，不向调用者传播；传播
  范围由「摘要是否真的变了」决定，不由「哪个函数被改」决定。
- **边界**：id 短路只作用于效果摘要；ownership / cleanup / call-target
  等派生事实各有依赖与失效规则——§10 的查询组合它们，不等于它们随
  effect id 自动免失效。

## 9. 一等函数与间接调用

### 9.1 间接调用 v1 = TOP

```text
callback.f(x)   // 目标静态未知
```

v1 取 `Top`：`accesses = All`，`may_trap`（含 panic）、`may_diverge`、
`nondeterministic` 全 true。不能只是「有副作用」一位，也不能遗漏发散或
非确定性。

### 9.2 数据流收窄（可选精化）

```text
FnValueInfo {
    type:         FnTypeId,
    effect_bound: EffectSummaryId,
}
```

若 callee 操作数静态可见地绑定到有限目标集 `f ∈ {foo, bar}`，则
`effect_bound(f) = summary(foo) ⊔ summary(bar)`，逐步提高精度而不改
中间表示。

**收窄档位**：v1 间接调用摘要 = `Top`（§9.1）。首个精化档为**局部
fn-ref 传播**：callee 操作数经字面 `fn_ref` / `let` 绑定 / 分支内有限集
可达，且**不跨函数边界、无逃逸路径**时收窄；任何逃逸（存入 host /
opaque、作为实参传出当前函数）立即回到 `Top`。该档**需求驱动**：只对
真实消费点——module-const 初始化/teardown 检查（§7）与优化 legality——
现场、按预算解析，不为全模块跑全局数据流。超限/不可证明是**精度预算**：
必须 over-approximate 回 `Top`，**绝不截取前 N 个目标**（截断是
under-approx，soundness bug）。跨过程目标集分析等局部档落地并出现量化
收益后再做（§14）。

### 9.3 host 元数据缺失 → TOP

host 函数的摘要来自 embedding metadata（§13）；缺失一律 TOP。

### 9.4 间接读 module const 的保守

初始化检查中，间接调用若 `effect_bound = Top`，其读集合视为「可能读任意
较晚常量」——不能当作空读集合放行（§7.3）。

## 10. 派生查询与优化合法性

### 10.1 事实表：不存 bool

**只保存事实（EffectSummary + 派生所需的类型/use/view），不保存
`is_pure = true` 这类 bool。** 所有优化属性由查询函数从摘要推导：

| 属性 | 判定（由 EffectSummary 及 ownership 门组合） |
| --- | --- |
| `total` | `!may_trap ∧ !may_diverge`（正常返回为默认假设，无 N 位） |
| `observable_effect_free` | 无 `Write / Allocate / Release`、无未知资源（Top）；资源**读**默认不构成可观察交互（Q 不在此判定内，见下） |
| `discardable` | `total` + `observable_effect_free` + 在给定清理上下文下 `discard_view(observed_effect(expr, ctx)) == Pure`（§11；discard_view 忽略 Q）+ ownership 门（值可安全弃，不含未完成的 Consume/借用约束）——**不要求 !Q** |
| `duplicable` | `discardable` + 结果 Copy + `OperandUse` 全 `Read`（不 Consume）+ **无 Q**（求值可重复） |
| `speculatable` | `total` + 无有序/可观察 effect（不越过 trap/borrow 边界提前执行不可撤销交互）+ **无 Q**（结果不稳定不可提前采样）；**上下文**：可移动性相对目标位置（§10.5），`isIntrinsicallySpeculatable` 只是必要非充分 |
| `reorderable(a,b)` | **位置上下文**：由 `canSwapOperands` / `canMove`（父 EvalPolicy + operand 位 + 路径屏障，§10.5）判定；资源访问无冲突（§5.6）、无 trap/diverge 顺序可观察差异是输入（默认仍 LTR，见 §3） |
| `never_returns(f)` | **must 事实、独立于摘要**：f 无正常返回路径——签名声明 `-> never`（Core），或结构推导（所有路径以 panic/trap/发散收尾，或全部分支 must-abort，或尾调用 `never_returns` 者）。调用点后同一直行区域的后缀不可达，可整段删除（含该区域 FE 清理，§11 上下文内）。推导保守（取不到即 false）；v1 只做签名与局部结构推导，递归 SCC 成员的推导需 greatest-fixpoint 语义、留待需要时 |
| `seg_safe` | `Copy(type)` + `total` + `observable_effect_free` + 无 nondeterministic（Q = 0，island 需结果稳定）+ cleanup 安全证明 + 递归子树与 region 同判 + ownership/lifetime 门（§12.3） |

**强约束**：`move.effects == {}` **不**使 move 变得 discardable /
duplicable / speculatable——每个公开查询都要组合 effect、operand uses、
结果 capability/view、ownership 可用性与 lifetime 栅栏，**缺一不可**。

**结果不稳定（Q）与可观察交互分离。** `nondeterministic`（Q）只描述「同式
两次求值结果可不同」——它需要**结果**参与的判定（duplicable、CSE、
speculate/move 前移：重复 / 合并 / 提前采样会把「两次值不同」变成可观察
差异）才要求 `!Q`。它本身**不构成可观察交互**：删除一次 total、无
`Write/Allocate/Release`、结果未被使用的求值，不改变程序可观察行为：

```text
discardable      : 不要求 !Q      // let x = clock.now() in 0 → 0 合法
                 （结果未使用，Q 只影响被丢弃的结果）
duplicable / CSE : 要求 !Q
speculate / move : 要求 !Q
```

资源**读是否可观察是 host 契约决定**（§13），编译器不替宿主假定：默认读
非可观察（`stat` 的稳定读与 `clock.now()` 的不稳定读，在「未使用结果」的
删除判定上同等对待）；宿主把读本身声明为可观察（清读寄存器、消费式读、
atime 更新）时以 `Write` 或可观察读标注出现，discardable 自然拒绝。Q 仍留
在格内（§5.4/§5.5 的代数与 `stable` 声明机制不变），discard 判定只经
`discard_view` 投影忽略它。

### 10.2 MayTrap 是 effect：dead-let 的通用化

```stilla
let x = 10 / y;
0
```

若 `x` 未使用，`let x = 10/y in 0 → 0` 看起来像 dead-let elimination；
但整数除零 trap（Runtime），变换不合法。于是 `effects(div.i32) =
{ may_trap: true }`，dead-let 规则自动成为：

```text
let x = v in body  →  body
    若 x ∉ FV(body)  ∧  discardable(v)        // discardable(div(..)) == false
```

不再需要 dead-let pass 特殊认识 `/`；derived 判定让规则随 descriptor
注册自动正确。

### 10.3 rewrite legality 统一接口

**两层判定必须分开**（否则「不 `switch(opcode)`」会被误读为所有 rewrite
都与 opcode 无关——那做不到、也没必要做到）：

- **Rewrite applicability**：typed opcode / 代数语义 / 值谓词。引擎在**规则
  匹配层**认识 opcode 没问题：`x + 0 → x` 能否做首先取决于它是 `add.i32`
  （wrapping）还是 `add.f32` / decimal / vector——这是代数可适用性；
- **Operational legality**：discard / duplicate / reorder / effect /
  ownership / lifetime。**通用 legality 引擎不认识 opcode**，合法性只来自
  派生查询/要求。

「优化器永远不 `switch(opcode)` 决定合法性」的精确含义是后者：legality
引擎没有 per-opcode 分支；applicability 是规则库内部事实，随 typed
opcode 注册，不进入 legality 查询面。

```text
RewriteRule {
    match                  // 模式（typed opcode 形状）
    build
    applicability          // 代数/值前提（按 typed opcode + 具体数值语义）
    legality: [Requirement]     // operational：不再散落特判
}

Requirement =
    Discardable(expr)
  | Duplicable(expr)
  | SwapOperands(parent, lhs_slot, rhs_slot)   // 上下文形式，见 §10.5
  | EvaluationCountPreserved(a, b)
```

例：

```text
Rule add_zero_i32
    match: add.i32(x, 0)
    applicability: true              // add.i32 wrapping 代数成立
    legality: [ EvaluationCountPreserved(x) ]   // 不改变 x 求值次数

x * 0 → 0      要求 Discardable(x)      // host.read() * 0 不能变 0
x + x → 2 * x  要求 Duplicable(x) 或显式 EvaluationCountPreserved
```

### 10.4 rewrite 的 effect contract（正式概念，两类重写）

**两类重写。** 普通 SEG 重写必须 full-expression-preserving；**boundary
rewrite**（v1 唯一实例是 β）把 callee 体从 λ 内部语义边界搬进调用点，
必须逐条声明契约后才准入。契约的 effect 面如下；HIR 侧的 scope / FE 映射
与 cleanup 证明见 [hir.md](hir.md) §8.4：

```text
RewriteContract {
    effect: {
        PreservesEvaluationCount
      | PreservesOrder
      | MayDuplicate      // 未来规则用：v1 引擎自动要求 discardable
      | MayDiscard        // let-unused：MayDiscard(init) → 引擎自动要求 discardable(init)
      | MayReorder
    }
    maps_scope / maps_full_expr / preserves_cleanup   // hir.md §8.4
}

β-to-let    : PreservesEvaluationCount + PreservesOrder
              + scope/FE 映射 + cleanup 证明
              （实参 Copy 且 discardable、λ 体 cleanup-free）
let-unused  : MayDiscard(init) → 引擎自动要求 discardable(init)
```

`(fn(x) { x + 1 })(host.read())` 整体仍不能进纯 term 的 equality
saturation——但 β 本身不删除、不复制、不重排 `arg`，契约证明后**可**
允许 effectful 实参；那是单独验证后再放开的方向（§14 再后）。**v1 仍
保守**：只对 Copy 且 discardable 的实参、cleanup-free 的单表达式 λ 体
提供 β 契约实例，λ 体 FE 到调用点 FE 的映射逐条显式声明（hir.md §8.4），
不作为 v1 行为宣传。

### 10.5 实现形态（Zig）

```zig
const OpSemantics = struct {
    eval: EvalPolicy,
    operand_uses: []const OperandUse,
    result_policy: ResultPolicy,

    infer_effects: *const fn (
        ctx: *EffectContext,
        expr: ExprId,
    ) EffectSummary,             // 递归汇总 + 函数摘要查找

    seg: ?SegDescriptor,
};

const EffectSummary = struct {
    accesses: EffectRowId,       // interned 行：有序去重 EffectAccess

    // 不设默认值：构造点必须显式选择 pure / top 或完整摘要
    // （bottom 与 pure 同值，见 §5.4）。
    may_trap: bool,              // 包括 panic
    may_diverge: bool,
    nondeterministic: bool,
};
```

构造器 `pure()` / `top()` 严格按 §5.4 的四元组赋值，`bottom()` 保留为
迭代起点的别名；不可依赖 Zig `.{}` 或空访问行推断摘要。Pending/Ready
包在摘要之外，不作为 EffectRow 的特殊值。

公开查询（每个都组合 effects × uses × capability/view × ownership 门；
Pending 或 cleanup 证明缺失均返回 false）。**speculate / reorder 是上下文
属性**：同一个表达式能否前移取决于跨过哪些 condition、borrow lifetime、
FE、effect 与 trap 屏障；同一对 sibling 能否交换取决于父节点的
EvalPolicy、operand 位置与中间是否有第三个 operation。因此公开面把
上下文显式参数化，只保留一个弱无上下文谓词：

```zig
// 表达式自身事实的弱判定：无 intrinsically blocking 条件。
// 必要非充分——code motion 必须再与路径上下文组合（canMove）。
fn isIntrinsicallySpeculatable(ctx: *HIR, expr: ExprId) bool;

// 交换同一 parent 下两个 operand slot（v1 先限相邻的 eager operand）。
fn canSwapOperands(ctx: *HIR, parent: ExprId, lhs_slot: u16, rhs_slot: u16) bool;

// 把 expr 从 from 位置移到 to 位置；跨移动须逐条检查 intervening
// operations、条件执行、binder 可用性、借用 lifetime 与 FE 边界。
fn canMove(ctx: *HIR, expr: ExprId,
           from: EvalPosition, to: EvalPosition,
           mctx: MovementContext) bool;

fn isDiscardable(ctx: *HIR, expr: ExprId, cleanup: CleanupCtx) bool;
fn isDuplicable(ctx: *HIR, expr: ExprId) bool;
fn isSegSafe(ctx: *HIR, expr: ExprId) bool;

const EvalPosition = struct {
    parent: ExprId,     // 父 op（EvalPolicy 由 descriptor 取）
    slot: u16,          // operand 位；region 内位置另按 regions 索引
    fe: FullExprId,     // 所属 full expression
};

const MovementContext = struct {
    // 移动路径上需检查的屏障与可用性：经过的 effect / trap / condition /
    // borrow lifetime / FE 边界；目标位置 binder 可见性；是否改变求值次数
    // 与销毁注册。具体字段随首个真实 consumer（hoisting、公共子表达式前移）
    // 定稿；查询必须接收路径上下文，不得退回 (a, b) 二元签名。
};
```

旧的 unary `isSpeculatable(ctx, expr)` / binary `canReorder(ctx, a, b)`
签名作废：EvalPolicy 是 **parent + operand 位置**的属性，不是 `a` / `b`
的自身属性，二元签名无法消费「EvalPolicy 允许」。

> **M1b 实施记录**：实际落地的 descriptor 形状与上面的 sketch 是语义等价
> 映射（`OpDescriptor` 定义见 [hir.md](hir.md) §3.5 的 M1b 修订）：
> `operand_uses` 拆为 `uses`（`UsePolicy`，含 `operand_capability` /
> `callee_params` / `static_list`）加可选显式 `operand_uses` 切片；
> `infer_effects` 拆为 `own_effect`（op 自身摘要）加 `transfer`
> （`TransferKind` 数据标签，由 `hir_effects.compute` 单一函数按标签组合
> operand / region / callee）；`seg` 在 M1b 落为 `hasSegEncoding`（恒
> false），`result_policy` 由既有 capability/view 数据承担。三者必填、
> 无默认值（省略即编译错误）。`EffectSummary` 同样无字段默认值，
> `pure`/`top`/`bottom`/`may_trap` 是唯一构造点。公开查询面的实现形态：
> `isIntrinsicallySpeculatable` 除 total / 无可观察 / 无 `Q` 外还要求
> cleanup 证明与递归 ownership 门；`canSwapOperands` 组合父节点 operand
> 位、full-expression 边界、两 operand 的 cleanup/ownership 与
> `orderCompatible`；`canMove` 本档不暴露（FE/lifetime 路径事实未建模）。

## 11. 完整销毁的可观察性

### 11.1 drop_effect(T)：类型系统与效果系统的桥

```text
drop_effect(T) -> EffectSummary
```

- `Copy(T)` → `{}`（drop 一个 Copy 值无效果，Types & Ownership）；
- `struct File { drop(file) { os.close(file.fd); } }` →
  `effects(File.drop_hook) ; seq(drop_effect(unique fields…), 逆声明序)`，
  保持结构销毁顺序（hook 先、字段逆声明序，Runtime）；
- `tuple[A, B]` → `drop_effect(B) ; drop_effect(A)`（销毁逆创建序）；
- `list[T] / box[T]` → 结构性递归（元素/内层 + 容器本身）；
- host opaque / `hostdata` → `Release(Host …)`——但**未知 opaque 与
  `any` 的装载内容销毁未知**，取保守摘要（不只是无害的 release 位：可能
  含 Stilla drop hook 或 host 析构，见 Types & Ownership、
  Runtime）；
- union 的候选 variant 用 `⊔`，实际销毁步骤用 `;`；list 的未知长度须
  覆盖零元素（`Pure`）及所有可能元素销毁序列，不能只汇总一个元素；
- 递归类型（自指 struct/union）→ 在类型 SCC 上求 least fixpoint，**不设
  展开深度/宽度上限**：分析期注册表冻结（§5.4/§5.6），transfer 单调，
  有限格保证收敛；may-summary 下重复天然坍缩（未知长度/深度的元素销毁在
  访问集与布尔位上等于单次），Kleene-star 不引入不收敛。**分析收敛 ≠
  运行时销毁终止**：收敛不授权去掉 `may_diverge`；结构终止证明缺失仍
  保守含发散，预算超限/放弃精化取 `Top`。

类型摘要与 drop hook 函数摘要**独立求解**：drop hook 是普通函数，其
摘要在函数 SCC（§8.2）中推导；`drop_effect(T)` 只引用 hook 与字段的
摘要。仅当依赖图出现跨层环——某函数摘要（经 FE 清理或 hook 路径）引用
`drop_effect(T)`，而 `T` 的 hook 摘要又引用该函数——时，`T` 回退 `Top`
（精度洞：此类环意味着 drop 一个值可能在 hook 中经模块函数间接 drop
同类值，罕见；出现真实模式再升级为分层外循环）。

**长期演化（不入 MVP，评审 #11）**：函数摘要与 `drop_effect(T)` 各自在
call-graph SCC / 类型 SCC 上求不动点，本质都是同一 EffectSummary 格上的
单调函数。若跨层环成为常见模式，把依赖节点统一为

```text
EffectDependencyNode =
    Function(FuncId)
  | DropType(TypeId)
```

并在一张统一 dependency graph 上做 least fixpoint，可消掉「跨层环时
`T` 回退 `Top`」的精度洞，分析器结构也更统一。留待真实模式出现后立项。

### 11.2 full-expression 清理与 observed_effect

Unique 临时量在所属 full expression 末尾**逆创建序**销毁（Runtime）。
一个表达式的真实语义不只是 `effects(expr)`，还要含其自动清理——但清理
是**上下文相关**的：

```text
observed_effect(expr, cleanup_context) =
    eval_effect(expr)
  ; cleanup_effect(cleanup_footprint(expr), cleanup_context)
```

**清理栈条目的 occurrence 归属（CleanupFootprint）。** full-expression
的清理栈不是「一堆临时量的袋子」——每条登记必须能回答它属于**哪个表达式
occurrence**：

```text
cleanup_footprint(expr) =
    { token t | t.origin_expr ∈ subtree(expr)
                ∧ t 登记在 expr 所属 FE 的清理栈上（未被 move / 转入
                  调用消耗） }

CleanupToken {
    id,                    // 清理栈内身份（同一 FE 内唯一）
    origin_expr: ExprId,   // 创建该临时量的 occurrence
    value: TempId, type: TypeId,
    registration_index,    // 入栈序号（逆创建序销毁的排序键）
}
```

由此 `observed_effect(expr, ctx)` 拿的是 **expr 子树对清理栈的贡献**
（origin 落在子树内的登记），不是整条 FE 的清理：

- `foo(make_file(), pure_expr())` 中 `discardable(pure_expr())` 不得把
  sibling `make_file()` 的 destructor 算进来（origin 不在其子树）；
- `discardable(make_file())` 必须计入其临时量在 FE 末尾的 drop
  （origin 在子树、且未消耗）。

MVP 只需 token 的 **origin + type + registration_index** 即可回答上述
两类问题；`Consumed / Escaped` 这类**状态**是路径敏感的（同一值在不同
控制流边上的消耗状态不同），不是摘要层的单一全局状态——它属于
destruction planner / CFG 侧（§11.3），效果层不维护。

规则要点：

- `make_file()` 即使构造本身无外部交互（`effects(make_file) = {}`），若
  结果未使用，`make_file();` 的 full expression 实际含
  `drop_effect(File)`——不能凭空 effects 删除；
- 被 `move`/转入调用（如 `consume(move make_file())`）的临时量**不在**
  清理栈上，不得重复计清理；
- 清理只在**正常路径**发生：panic/trap 跳过全部销毁（Static Semantics *Panic and traps*）；
- 清理顺序（逆创建序）在计划里保持，摘要按此顺序用 `;` 折叠，空清理为
  `Pure`；某个 destructor 异常终止后，不执行剩余清理；
- cleanup 证明不可用时，查询失败关闭；若需要可发布的保守清理摘要，使用
  `Top`。**不能把未知清理当 `Pure`，也不能只凭结果 Copy 推断整个子树无
  清理**；本规则从 MVP 起生效。
- **变换后的 origin 重映射**：任何重写（含 SEG island 替换、合成 let）
  后，被改写区域内存活临时量的 token 须把 origin 重映射到新节点，且
  registration_index 保持原 FE 内的相对销毁序；「合成 let 不改销毁注册」
  即此不变量——校验器核对 origin 与注册表一致（[hir.md](hir.md)
  §10.1）。

于是优化器只问一个谓词：

```text
discardable(ctx, expr)   // 内部组合 total、observable_effect_free 与
                         // discard_view(observed_effect(expr, ctx)) == Pure
                         // discard_view 忽略 Q（§10.1）；宿主声明的可观察读
                         // 以 Write / 可观察读出现，仍被拒绝
```

不必理解 full-expression 销毁的细节。合成 let 属于同一 full expression，
不改变临时量销毁注册——因此本约束与「合成 let 不改销毁注册」一致。

### 11.3 drop_effect ≠ 有序销毁计划

`drop_effect(T)` 只汇总**可观察性**；真正的有序销毁计划（hook 调用、
逐字段 drop、maybe-unique 的 join 边 drop、panic/trap 路径跳过清理）
仍由 destruction planner / CFG 层生成。effect 系统保证 DCE 不会误删带
重要 destructor 的临时值，**不替代计划本身**。

## 12. 效果驱动的前端变换

这套模型的三个首要消费者。它们共同点是：**合法性全部来自派生查询，任何
一个都没有 `switch(op)` 特判**。

### 12.1 Selective A-Normal Form

不再硬编码 `if expr is Call || Div || …`：

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
```

```text
let T0 = os.read() in call(f, local T0, add(a, mul(b, c)))
```

新增 intrinsic（如 `gpu.query`）：在 stdlib 加无体声明并写 lowering 展开
（Intrinsics）；其效果来自展开出的现有 op 与 host 调用，前端
canonicalizer 零改动。约束保留：callee 若本身
是表达式先按 LTR 绑定 callee；不跨 full expression；不从惰性分支内
提升；不改变临时量销毁注册。

### 12.2 dead-let

见 §10.2——`discardable` 一个查询同时覆盖 trap、效果与清理，规则无需
认识 `/` 或任何具体 op。

### 12.3 SEG legality

SEG 入口从 op 白名单改成两个条件（先看该 op 是否带 SEG 编码，再看派生
查询）：

```text
isSegSafe(ctx, expr)  ==
    op(expr).seg_encoding 已注册
    && Copy(type(expr))
    && total(expr)
    && observable_effect_free(expr)
    && 无 nondeterministic（Q = 0：island 内求值结果须稳定，饱和/抽取才能
        合并与复用）
    && cleanup 安全证明：已证明 cleanup-free，或 observed_effect == Pure
    && 递归：所有 operand 子树同判
    && 对 lazy-branch op：每个可选 region body 同判
    && ownership/lifetime 门：无 Borrowed-view 参与、无未决 Consume、
       不跨越 full-expression 边界
```

准入结果示意：

```text
add.i32 / mul.i32 / add.f32    ✅
div.i32                        ❌  may_trap
any 恢复                        ❌  may_trap
host binding 调用（syscall 目标）          ❌
drop                           ❌
move Unique                    ❌
```

职责分离：Slotted E-Graph 处理 variables/binders、substitution、
α-equivalence；Stilla 所需的 effect semantics 由 HIR→SEG bridge 的
legality 查询负责——准入检查的是**递归属性**（region body 与 ownership
依赖都纳入），而非只看根节点的效果与 operand 类型。

**本谓词只管普通 island**：isSegSafe 的「不跨越 full-expression 边界」
约束对 ordinary rewrite 成立；boundary rewrite（β，hir.md §8.4）不进
isSegSafe，由 §10.4 的契约门准入——两类重写共用本模型，但准入路径不同。

## 13. Host 接口 metadata（embedding ABI）

host 是 Stilla 的核心目标（host binding 实现完全由 host 提供；stdlib
intrinsic 由编译器展开，Intrinsics Spec）。编译器侧模块元数据
可扩展：

```text
HostFunctionDescriptor {
    signature
    effects: EffectSummary      // 声明方提供的语义契约
}
```

```text
math.sqrt:      effects = {}
os.open:        effects = { ReadWrite(Host.OS) + Allocate(Host.FileSystem) + MayTrap }
builtin.print:  effects = { Write(Host.Output) }
clock.now:      effects = { Read(Host.Clock), nondeterministic }
unknown host:   effects = TOP
```

立场：

- host 声明是**受信的语义契约**（host 与编译器约定），不是编译器自动
  验证出的 purity；错误声明是 host 的 bug，编译器按契约优化。
- 缺失 metadata 默认 TOP，安全优先。这作为 embedding ABI metadata，
  **不进 Stilla source syntax**；现成的扩展点是 host_bind 的 typed
  registry。
- 声明必须覆盖该 host 函数**可能执行的任何 Stilla 代码**：接受 Stilla
  回调（同步调用、存储后重入、转交另一 host）的 host 函数，其摘要须含
  回调可能产生的全部交互与发散——host 自身逻辑纯不能证明整次调用纯。
  回调内容静态未知时默认 `Top`；按传入 callable 的 effect_bound 实例化
  的「回调参数化摘要」留待后续（§15）。
- **读的可观察性是声明项**：默认域/op 的 `Read` 视为**非可观察**（结果未
  使用时允许删除，Q 不阻断 discard，§10.1）；宿主把「读本身有可观察后
  果」的访问（清读寄存器、消费式读、atime 更新）声明为 `Write` 或可观察
  读，编译器不替宿主假定「读可观察」或「读不可观察」。

**缓存指纹（EffectEnvironmentFingerprint）。** effect metadata 参与编译
缓存键：host 语义 registry 的 generation/版本、effect-domain 注册表、
overlap/disjoint 声明与 `stable` 声明，整体折叠为一个
`EffectEnvironmentFingerprint` 进入 module cache / incremental compilation
key。否则 `host.foo` 的声明从 `Pure` 改成 `Write(OS)` 后，旧缓存里按
`Pure` 优化的代码会变得 unsound——指纹随声明集合变化即失效，阻断此类
复用。

## 14. 模型范围与验收

**最小范围（固定乘积格与保守查询，不做通用 lattice 引擎）**：

```text
MayTrap（含 panic）+ MayDiverge + nondeterministic
+ 不再跟踪 may_return_normally（正常返回为默认假设，见 §5.4）
+ Host(resource, Read/Write)     // resource = 抽象域
+ ModuleConst(Read)
+ OperandUse 独立（move/borrow/consume 不进 EffectSummary）
```

用它驱动三个 pass：**dead-let、selective ANF、SEG-safe**。

**落地档位映射（与 [hir.md](hir.md) §11 对齐）**：本节的**最小范围 + MVP
前置条件 = M1b（效果基础设施）**。在 hir.md 的档位里，M1a 落地结构 HIR
（不含 effect 字段），M1b 以加性扩展带上 `SemanticInfo.effect` 并落地本
节的格 / 查询门 / 基础效果行。三个消费者 pass（dead-let / selective ANF /
SEG-safe）与函数 SCC fixpoint、module-const 检查属 **M2**：M1b 只验收基础
设施与查询门本身，「三个 pass 无 `switch(op)` 特判」的验收在 M2b 执行。
函数摘要的 SCC least fixpoint（§8.2）不在 M1b——M1b 内递归函数摘要一律
保守 `Top`。

> **M1b 实施记录**：模型落在 `src/effects.zig`，HIR 集成落在
> `src/passes/hir_effects.zig`（均见 hir.md §11 M1b 交付记录）。相对于
> 本节最小范围的实现选择：① `drop_effect(T)` 只做 Copy → `{}`、其余 →
> `Top`（精确结构/hook 摘要在“再后”第 1 项）；② cleanup 走本节允许的
> cleanup-free MVP 路径：对已求值子树递归证明全部类型 Copy、无非借用
> Unique 绑定、无 `drop`，否则 cleanup 贡献 `Top`（未建模的
> destructor/FE 清理失败关闭）； `CleanupFootprint` token 登记未由当前
> builder 填充，空注册表视为未建模、不作证明；③ 间接调用/缺失函数摘要/
> 缺失 host metadata 均取 `Top`；host metadata 通过分析局部注册表测试，
> 未接 embedding ABI；④ `stable` 域与 `disjoint` 对按本节 §5.5/§5.6
> 实现，未声明的不同资源对按冲突处理；⑤ §10.5 的 `canMove` 未暴露
> （FE/lifetime 路径事实未建模，expose 一个恒 false 的入口无意义）；
> `canSwapOperands` 组合父节点 operand 位、full-expression 边界、两个
> operand 的 cleanup/ownership 门，再经 `orderCompatible`（资源冲突、
> trap/diverge 顺序、`Q`）——摘要相等本身不放行任何交换；
> ⑥ **隐藏操作审计**（本档不建模但可能
> 有非 pure 行为者一律 `Top`/`MayTrap`）：值位置模块链叶子
> （`ExprNode.access_hops` 非空）取 `Top`——lowering 会重放
> `module_ref` + `load_member`（hir.md §7.4），模块加载/初始化的效果面
> 本档不建模；`let`/`match` 的 pattern 在 HIR 里没有节点，transfer 显式
> 序列化其效果：只有 list pattern 非 total（元素访问 lowering 为
> 边界检查的 `read_index`/`split_list`，均为 `cfg` `may_trap`），其余
> pattern 类别（wildcard/bind/literal/tuple/struct/variant/type_test）
> 为 total；⑦ **查询组合**（§10.1 强约束「缺一不可」）：
> `observableEffectFree` 对任一模的**通配/未知资源**（含 `Read(Top)`）
> 返回 false；`isIntrinsicallySpeculatable` 除 total / 无可观察 / 无 `Q`
> 外还要求 cleanup 证明与递归 ownership 门；`orderCompatible` 拒绝两个
> 可能失败的位（失败顺序可观察，§5.6），`Q` 位除「同一 stable 域读对」
> 外一律拒绝（§5.5）；`ownershipGate` 递归 operand，嵌套
> `move`/borrow 不得逃逸；注解校验先清 per-node memo 再重算摘要，故校验
> 是同逻辑的新推导（能拒绝被篗改/过期的注解并定位到过期的调用者）。
>
> **M2a 实施记录（SEG-safe 消费者）**：SEG v1 落在 `src/passes/hir_seg.zig`
> （见 hir.md §11 M2a 交付记录），由 `frontend.Options.seg` / `--seg` 开启，
> 默认关。准入完全由派生查询驱动：island 成员 = registry 的 `seg`
> 非空 ∧ `isSegSafe` ∧ 每个 operand / region body 同为 island；
> `div.i32`（may_trap）、`move`/`borrow`/`drop`、host 调用、跨 full-
> expression 的节点自然落在 island 外（无 `switch(op)` 白名单）。
> 本档只把 `isSegSafe` 接到四组 v1 规则（β/let/常折叠/整数代数）；
> dead-let 与 selective A-Normal Form 的无 `switch(op)` 摘要化通用形式、
> 函数 SCC fixpoint、module-const 初始化/teardown 检查仍归 M2b（本节
> 验收标准第一条的“三个 pass 无 switch(op)”完整验收在 M2b 执行）。
> 本档验收见 hir.md §11 M2a 记录：白盒规则/代价测试 + 黑盒定向用例
> （β 单次求值、div/float 拒绝、常量分支、不动点/确定性）+ 全语料
> `--seg` 编译与 AIR round-trip + SEG-on/off 解释器执行逐字相等。

**MVP 前置条件（不能延期）**：

- 实现 Bottom/Pure/Top、join 与顺序组合，以及 Pending/Ready 查询门；
- 接入 cleanup-aware legality：只有已证明无清理，或已获得保守清理摘要
  并通过相关查询，才允许删除、浮动、复制或 SEG 准入。未建模的
  destructor/FE 清理失败关闭；MVP 可只优化**已证明 cleanup-free** 的
  子树，不能仅检查根结果是否 Copy；
- 缺失函数摘要、未知 callee、缺失 host metadata 使用 `Top`。尚未实现的
  精化只降低优化覆盖率，不降低保守性。

**验收标准**：

- 这三个 pass 没有任何 `switch(op)` 特判——所有合法性来自派生查询；
- **negative tests**：每个判定配「不该发生的例子」（如
  `let x = 10/y in 0` 不许删 x；`host.read() * 0` 不许变 0；`div.i32`
  不许进 SEG；带 drop hook 的临时值不许被 DCE）；
- **Q 与 discard 的正/负例**：`let x = clock.now() in 0 → 0` 合法
  （Q 不阻断 discard，§10.1）；`duplicable(clock.now()) == false`、两处
  同形 `clock.now()` 不许合并（Q 仍阻断重复与 CSE）；宿主把某读声明为
  可观察读后，同形的 `let x = that_read() in 0` 不许删；
- 条件 panic 的函数调用不许被 DCE；有副作用的 callee 表达式必须先于
  实参执行且不能丢失；未知 cleanup（包括返回 Copy 的子树内部临时量）
  不许被删/浮动/复制或进入 SEG；Bottom/Pure/Top 与组合满足 §5.4 的
  代数验收例。另含 `;`/`⊔` 同式与摘要层 `E ; F == F ; E` 的正断言、
  「摘要相等不单独放行任何程序级交换/删除」的负例，以及 `stable` 域读对
  在整体 `Q = 1` 表达式中的边界用例（§5.5）。

**再后**（各自独立）：

1. 精化 `drop_effect(T)`（字段、容器、递归 hook），替换 MVP 的未知
   cleanup 拒绝/Top 回退，扩大 `observed_effect(expr, ctx)` 可证明的范围；
2. 函数 SCC fixpoint 摘要（§8.2）驱动 Core 的初始化与 teardown 检查，
   替换特设分析（checker_validate.zig 的 `InitOrder`；属 hir.md §11 的
   M2b）；teardown 判定按
   §7.2 以 `drop_effect` 全链（含字段/容器元素 hook）为对象；
3. host metadata（§13）接入现有 typed registry；
4. effectful β 实参的放开（在 §10.4 契约下单独验证后）；
5. 间接调用的局部 fn-ref 目标传播（§9.2：需求驱动、超限回 Top）。

## 15. 开放问题与现状核对

**开放问题：**

- 域间 overlap/disjoint 声明的具体条目：条目形式见 §5.6，具体内容随
  真实 host 域出现后按需补全。
- teardown 检查的链与措辞（§7.2）：Core 现措辞只约束「hook 及其传递
  调用」，字段/容器元素级 hook 的读（构造上同一危害类）与 Copy 常量的
  teardown 期读取（从不销毁、无害）均未表达。两条待规范澄清后回填本节
  与 checker 行为。
- host 回调/重入的 metadata 条目形式（§13）：未知回调默认 `Top` 的声明
  语法，以及「回调参数化摘要」（按传入 callable 的 effect_bound 实例化）
  是否立项。

**现状核对（哪些特设实现会被本文取代）：**

- module-const 依赖检查：checker_validate.zig 的 `InitOrder`（初始化
  方向 + drop hook 方向）是 AST 级的特设 walker，需用函数摘要替换；
- CFG/AIR 层已有一份 per-op 的 `may_trap / effects` 两位 schema（cfg.zig
  的 op schema，派生查询为 `pure()` 即 `!effects ∧ !may_trap`）——它是
  op 级的保守位，缺少 typed 精度与资源域；本文的 typed-opcode 摘要是对
  它的精化与统一。**M1b 落地时按“显式分层”处理**：HIR 的 typed 行按具体
  rep 写死（整数 div/rem `MayTrap`、float div/rem `Pure`），**不要求**与
  CFG 粗粒度位逐位相等（CFG 故意过度近似 float 除法）；registry 启动
  校验只断言 HIR 行自身的 typed 一致性，避免同一 trap 语义写两处而漂移。
- 现有 pass（dead-instr 等）以「side-effect-free、non-consuming、
  non-trapping」的 schema 位白名单做判定——正是本文想用派生查询替代的
  形态。
