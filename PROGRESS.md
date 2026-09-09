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

#### S3 事后修复（评审发现，随 S4 一起提交）

- **诊断消息生命周期缺陷**：`validate` 原先把返回消息分配在函数内部 scratch 子
  arena，`validate` 返回即释放——调用方读取的是悬垂内存（arena 复用恰好掩盖）。
  修复：`fail()` 改从**调用方 allocator** 分配返回消息，子 arena 只做 scratch
  （marks/worklist）；API 文档写明消息归调用方所有、按 cfg_validate 惯例释放；
  新增回归测试用 `std.testing.allocator` 作调用方 allocator，验证消息存活、内容
  可读、正确释放（泄漏检测器兜底）。
- **pattern 深度未设防**：`checkPatternTree` 是递归 DFS（环由 0/1/2 状态捕获，
  递归深度=最长无环链）。「免疫深层恶意 arena」只对 expr/region 迭代 walk 成立；
  pattern 侧加 4096 层深度上限，越深返回诊断而非栈溢出。PROGRESS 的迭代主张
  相应改为：expr/region walk 迭代无界安全；pattern 子树深度封顶（诊断化）。

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

#### S3 事后修复（评审发现，随 S4 一起提交）

- **诊断消息生命周期缺陷**：`validate` 原先把返回消息分配在函数内部 scratch 子
  arena，`validate` 返回即释放——调用方读取的是悬垂内存（arena 复用恰好掩盖）。
  修复：`fail()` 改从**调用方 allocator** 分配返回消息，子 arena 只做 scratch
  （marks/worklist）；API 文档写明消息归调用方所有、按 cfg_validate 惯例释放；
  新增回归测试用 `std.testing.allocator` 作调用方 allocator，验证消息存活、内容
  可读、正确释放（泄漏检测器兜底）。
- **pattern 深度未设防**：`checkPatternTree` 是递归 DFS（环由 0/1/2 状态捕获，
  递归深度=最长无环链）。「免疫深层恶意 arena」只对 expr/region 迭代 walk 成立；
  pattern 侧加 4096 层深度上限，越深返回诊断而非栈溢出。PROGRESS 的迭代主张
  相应改为：expr/region walk 迭代无界安全；pattern 子树深度封顶（诊断化）。

#### S3 过程记录（风险）

- 首次 `zig build -fincremental test` 出现一次 ~15 分钟空转无输出（无新 test 二进制
  产出）；重启后正常（~3 分钟编译 + 秒级测试）。原因未定，怀疑增量 listener 卡死；
  后续轮次均正常，无代码关联证据。中途两轮编译错误为返回类型可选包/error-union
  再包问题（`return self.fail(...)` 不隐式剥 error-union 包 optional；改为捕获后
  `return msg;`），已记录。

### S4 — AST→HIR builder（done）

- 交付：`passes/hir_build.zig`（~1900 行，`hir_build.buildProgram` /
  `buildProgramDiag`）——消费 module graph + checker.Annotation（含 mono 体），
  把全语料构建为规范形 HIR；`hir.zig` 加程序级容器（`BuiltProgram` /
  `BuiltModule` / `FuncRecord{kind, order}` / `ConstRecord` / `HostRecord` +
  SerCtx 接真实表）；registry 扩为 ~130 个 typed 行（算术/比较/位/逻辑/字符串/
  byte 家族，ScalarRep 加 byte/bool/str——§7.2 注明的"随 builder 补齐"）；
  `hir_tests.zig`（root.zig 挂接）fib + **examples/ + probes/ 全语料**构建并
  逐根跑 S3 validator（确定性 manifest + 磁盘读取，同 `zig build examples`）。
- 验收证据：`zig build test`（非增量）全绿 exit=0；`zig build -fincremental
  test` 全绿；语料测试的收集性由早期失败运行点名
  `hir_tests.test.S4: HIR corpus — …` 证明；`zig fmt --check src/` 绿；
  无 debug print、栅栏净（EffectSummary/effect_transfer/seg_* = 0）。

#### S4 设计定案与编码契约（评审迭代后）

- **源级规范树**（hir.md §5.2）：block→let 嵌套 / seq，if/match 保分支 region
  与 arm pattern；cfg 专属产物（module_ref 值、@init store 序列、pack/coerce、
  copy 插入、drop 布置、cleanup、SSA/phi）不在此层（S5 从 checker 态再派生）。
- **清单/命名/次序复刻 cfg**：init? → 非泛型成员 → 实例 → drop hook →
  λ（completion 序）→ intrinsic wrapper（creation 序）；预声明让前向/递归引用
  先解析（`func_ids`/`const_ids`/`host_ids` 名字表）；λ 计数器先于体（pre-order
  命名），记录 completion 后入列；wrapper 程序级缓存（owner, slot, spec）。
  记录带 `order`（模块内 cfg 序位置），S5 重排序即可。
- **路径解析落叶**：fn_ref（成员/实例/host binding/intrinsic wrapper）/
  module_const（const 成员；intrinsic const 位模式物化）。host 表含宿主绑定与
  bundle intrinsic（call 位 vs 值位的 wrapper/syscall 分派留 S5）。
- **`::[]` 调用**（`array.get::[T]` 等 host/intrinsic）：无 call_of 行时按
  member 直接落 host 叶（镜像 cfg 的 intrinsic expansion 路径）。
- **λ 提升**：语料首个 first-class intrinsic wrapper 亦合成**可执行转发体**
  （`synthIntrinsicRoot`：参数按 mode 绑定 + `call` 宿主叶——与 cfg
  `synthIntrinsicFunc` 同形；此前记录 root 未定义，已修）。
- **语义保序修正**（评审驱动）：struct 构造按**书写序**求值、按声明序承载
  ——书写≠声明序时先 let 绑临时再构造；调用先构建 callee 再 args（λ/wrapper
  发现序对齐 cfg）；const init 于成员体**之前**构建（cfg 的 lowerInit 最先跑）。
- **注解身份根因修复**：`Block.result` 曾**按值**传递导致 block 尾表达式
  的注解（类型 / call_of / spec_of / 构造类型）全部丢失——`buildStmts` 链改
  传 `?*const ast.Expr`（指向原 AST）。删掉据此引入的 `instanceByArgs`
  签名猜测回退（参数类型无法钉死只出现在返回位的类型参数）；缺 call_of 即
  显式失败。
- **`using`**：模块值 alias→环境名（无运行时值）；值成员 alias→let 叶（bind
  一次）；块级 alias 续体索引修正为 i+1。
- **查表隔离**：`lookup` 受 `env_depth` 约束（函数体不得见调用方 local）；
  块级 module alias 受 `alias_depth` 约束。
- **S3 修订（§5.2 修订随 S4 提交）**：let region 可携带**不可反驳** pattern
  （多叶解构；params=绑定叶）；validator 加 `checkIrrefutable`（literal/
  variant/type-test 可反驳，仍只属 match arm）；无绑定 type-test 用
  maxInt 哨兵并在 validator/叶扫描中跳过。
- **注册表/S2 已知限制（记录）**：typed 比较行（eq.i32 等）结果应为 bool，
  S2 打印/解析的结果类型再推导尚未按行元数据区分（打印需显式 `: ty` 注解
  ——打印器本来就会对无法自推的节点补注解，但"比较→bool"未被行携带；
  S5/S2 后续给 typed 行补 result-bool 元数据）。
- **FE / origin / 销毁作用域（如实记录，非本档承诺）**：节点 `full_expr`
  目前统一为默认 0（未做逐表达式 FE 归属）；`origin` 未接线；binding→scope
  关联与销毁作用域留 S5（这些在 PROGRESS"明确推迟"与 hir.md §5.6 一致——
  FE 计划不是可执行销毁计划）。若评审认为 S4 必须携带逐表达式 FE 标注，另行
  扩展。
- **模块范围含 hoisted**：`BuiltModule.funcs` 覆盖该模块全部记录（含 λ/
  wrapper），`order` 给出 cfg 序位置。

#### S4 过程记录（风险）

- 长尾构建期多次出现内容重复/结构损坏（编辑脚本拼接失误），曾导致函数级
  重复定义与函数体拼接错乱；最终以头部 + 重新生成尾部（单拷贝）+ 字节级
  去重脚本修复。教训：大文件重构用整文件重写或行级索引替换，避免多层
  python 字符串拼接。
- 增量 listener 偶发空转一次（与 S3 观察同型，重启恢复）。
- 语料测试从磁盘读 probes//examples/（manifest 固定列举），与
  `zig build examples` 同依赖仓库布局；文件缺失=显式失败。

#### S4 设计决定（评审定案 + 本阶段编码契约）

- **HIR = 源级规范化树，不是 CFG 指令树**（hir.md §5.2：block→let 嵌套，
  IR 只有 Let/Seq/Expr 三种形状）。cfg 专属产物（module_ref 值、pack-at-let、
  copy 插入、drop 布置、cleanup、join phi、SSA）**不在 S4 编码**，留给 S5 从
  checker 绑定态再派生；HIR 只携带让 S5 无需重建 AST、无需再推断的
  结构/解析/视图事实。与 cfg 输出的逐字节差异归 S5 的 diff 迭代（§12 认可
  「等价门禁暴露表述缺口再补」）。
- **容器**（hir.zig 新增 `BuiltProgram`/`BuiltModule` 记录层，`hir.Program`
  保持每 module 节点仓）：程序级全局 funcs/consts/hosts 记录表 + 每 module
  （specifier、节点仓、func 记录 range、init/成员/实例/hook/lambda/wrapper
  顺序编排、module-const 记录）——清单顺序复刻 `cfg_lower_module.lowerModule`
  （init? → 非泛型函数成员 → 实例 → drop hook → 提升的 lambda → intrinsic
  wrapper）；FuncId/ConstId/HostBindingId = builder 分配的程序级稠密 id，
  SerCtx 由真实 module 表接线（types 用 graph 的 cfg.TypeDecl 布局同构表）。
- **编解码关键约定**：
  - 路径解析到最终目标：成员链静态走穿（module 值 / using / import），落
    `fn_ref`（函数/实例/host binding/intrinsic wrapper）或 `module_const`
    （const 成员，含 module 值）。名字解析顺序镜像 `cfg_lower_path.lowerPathValue`：
    local → module value → 自身成员 → using alias。
  - `if` 无 else = else region 根为 void 字面量（S2 文本约定）。
  - `and`/`or` 编码为 `if` 形状（保短路 provenance，S5 可复现同款
    br-diamond）；`match (move s)` 消费性由 arm payload binder 的
    `.move` mode 表达；identifier 整值 catch-all arm 绑整个 scrutinee。
  - `let` 解构（`let (a,b)=e`，语料 8 处）：S3 定 let region 单 binder +
    pattern 只在 match arm —— 不放松 S3；把多叶不可反驳解构规范成
    **单 arm 的 match**（scrutinee=init 值,irrefutable pattern 在 arm
    region 上,arm body=原 let 的续体）？——评审后改为：let 保持单 binder
    （绑整个 init 值），续体内按需要以 field/tuple/list 投影节点取分量。
    投影用 `field_get`（payload.field=索引；S5 依 base 类型分派 struct
    field vs tuple 元素 vs list 元素读，对应 cfg read_field/read_tuple/
    read_index 决策在 S5，因为索引+类型即全信息）。绑定叶只出现在 match
    arm 的 region pattern；纯标识 let 用单 binder。详见 hir_build 内
    `destructureLet`。
  - tuple 元素成员读 `t.0`（语料 26 处）同上投影节点。
  - full_expr：每个「函数体顶层与 λ 体、if/match arm 体、let 续体根」的
    求值产生处打 FE 边界 id（含跨构造的临时量归属按求值序）；
    S4 先只在构造 API 层面提供 addFullExpr 归属点（全 FE 清理注册留 S5，
    hir.md §5.6 明确销毁计划不在 HIR）。
  - ownership_view：helper 依 cfg.Type ownership + 上下文
    （borrow param / non-consuming match 视图 / unique 源）派生，
    记入 SemanticInfo（默认 owned）。
  - `using`（块级/模块级）：模块值 alias → 环境名字（非运行时值）；
    值成员 alias → 归约成 let 绑一个 fn_ref/module_const 叶（保留 cfg
    的 load-once-at-using 语义）。
- **Registry 扩展**（数据编辑，§7.2 注明随 S4 补齐）：为语料算术家族补
  typed 行：sub/rem/min/max/abs?/neg?/not?/shl/shr/band/bor/bxor/
  eq/ne/lt/le/gt/ge（i32/u32/i64/u64 视 cfg 语义）、f32/f64 四则与比较、
  concat（str）、neg/not 归 core？——行名与 §7.1 不冲突（§7.1 是语义核心，
  全算术家族明示随 S4 落），typed 行取 cfg 3-address 语义对应。core 22 行
  不动（除非显式向 hir.md 提修订，本阶段不新增 core op）。
- **明确推迟/不编码（记录，S5 的 diff 面）**：module_ref 值、@init 的
  store_member 序列（S4 只在 module 记录里登记 const 及其 init 表达式根，
  S5 决定存储与初始化函数形态）、drop 布置与 cleanup、pack 物化（let/返回/
  join 边的 any 打包）、coerceRet、copy 插入、块内线性化的值表。
- 语料测试机制：`hir_tests.zig`（root.zig 挂接）用磁盘读取 probes/、
  examples/ 各 `.st`（确定性枚举；文件缺失 = 显式失败，不静默跳过；与
  `zig build examples` 同依赖仓库布局）单文件编译 + HIR 构建 + 逐根
  validate；`std/` 体经传递闭包一并构建。白盒（arena/registry 级）测试在
  hir_build.zig / hir.zig。

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
| 2026-09-08 | S3 修复 | fix(hir) S3 fix 提交 | 诊断消息改由调用方 allocator 分配（原为 scratch arena，返回即悬垂）+ 消息生命周期回归测试；pattern DFS 加深度上限 4096（越深诊断化，不栈溢出）；PROGRESS 措辞改准确 |
| 2026-09-08 | S4 | 本次 feat(hir) S4 提交 | passes/hir_build.zig（AST→HIR，含 mono 体/实例/drop hook/λ 提升/intrinsic wrapper 转发体/路径落叶/`::[]` host 调用）；hir.zig 容器层 + registry ~130 typed 行 + ScalarRep{byte,bool,str} + serCtx 错误传播；S3 修订（let 不可反驳 pattern + checkIrrefutable + 无绑定 type-test 哨兵）；hir_tests.zig fib + examples//probes/ 全语料构建+逐根 validate；验收=全套绿 |
