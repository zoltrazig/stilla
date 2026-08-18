# 面向定长字节码的 IR 评估与后端规范化方案

> 依据: `spec/ir.md`、`spec/Stilla Runtime Specification.md`、`src/cfg.zig`、`src/frontend.zig`、`docs/optimizer.md`  
> 目标: 保留现有 SSA CFG 的语义和优化能力，在其后增加一个适合解释器的定长字节码投影；本计划不实现解释器。  
> 验收基线: 每个实现阶段均通过 `zig fmt src/`、`zig fmt --check src/`、`zig build test`；黑盒覆盖加入 `src/frontend_tests.zig`。

依赖顺序: 阶段 0（补齐自包含 IR）→ 阶段 1（冻结字节码模型）→ 阶段 2（后端规范化）→ 阶段 3（验证与度量）→ 阶段 4（按数据决定的可选优化）

## 结论

**不简化现有 SSA CFG；新增独立的 CFG → Bytecode lowering。**

现有 IR 中的 SSA、phi、显式 ownership、borrow provenance、cleanup token 和结构化 drop 使优化器与验证器能够证明程序正确，但它们不是解释器最方便的执行形式。直接删除这些信息会把复杂度转移回 checker、优化器或解释器，并增加 ownership/trap 回归风险。

推荐流水线：

```text
source
  → validated SSA CFG
  → cfg_optimize
  → cfg_lower_drop
  → cfg_validate
  → cfg_lower_bytecode（只读投影，不修改 CFG）
  → fixed-width BytecodeProgram
```

首版字节码将每个 SSA value 映射到函数私有的虚拟寄存器 `rN`，物理位置为 frame slot `stack[fp + N]`；所有函数代码展开到全程序唯一的 `BytecodeProgram.instructions`，VM 定义 `pc`、`sp`、`fp`、`ctx` 专用寄存器。所有指令记录固定为 16 字节，变长数据放入只读 side table：

```zig
const Instr = extern struct {
    opcode: u16,
    flags: u16,
    a: u32,
    b: u32,
    c: u32,
};
```

`a/b/c` 的含义由 opcode 固定，可表示 frame slot、常量、类型、函数、模块、block 或 descriptor ID。`construct`、`call`、`syscall`、多结果 destructure、`switch` 等变长内容通过 descriptor ID 引用扁平 side table。若未来需要落盘，必须使用显式字节序编码，不得直接序列化 Zig ABI 内存布局。

### 全局 instruction table

`BytecodeProgram.instructions` 是全程序唯一的定长指令数组，每个 `FunctionDesc` 保存不重叠的半开区间 `[code_start, code_end)` 和入口 `entry_pc`。`pc`、branch target、switch target、`return_pc` 均为该全局数组的绝对 instruction index，取指为 `BytecodeProgram.instructions[pc]`。

FunctionId 是 call target、function value 和 metadata table 的稳定 ID。当前 FunctionDesc 由 `ownerOf(pc)` 唯一确定；code ranges 按 `code_start` 排序且不重叠。解释器在 entry/resume/ret 时由 `pc` 设置 `current_func` 缓存，call 时将其替换为 callee descriptor。

```text
BytecodeProgram
  instructions: []Instr
  functions: []FunctionDesc

FunctionDesc
  code_start: u32
  code_end: u32
  entry_pc: u32
  signature_id: SignatureId
  module_id: ModuleId
  value_slot_count: u32
  scratch_slot_count: u32
  cleanup_base: u32
  cleanup_count: u32
```

function 的 code range 仍保持 block 布局；每个 block descriptor 保存绝对 `start_pc/end_pc`。lowering 先确定所有函数与 block 的 record 数，再分配绝对 PC，最后回填 branch/switch/call target。函数代码不能 fall through 到相邻函数。

### VM 专用寄存器与 frame 约定

| 寄存器 | 含义 | 更新者 |
| --- | --- | --- |
| `pc: u32` | 下一条指令在全局 `BytecodeProgram.instructions` 中的绝对索引；不是字节偏移或主机指针 | 顺序执行、branch/switch、call/ret/tailcall |
| `sp: u32` | VM stack 中第一个空闲 cell；用于分配 frame、call header 和临时 staging slots | call、ret、tailcall、frame setup |
| `fp: u32` | 当前 frame 的 slot 0；普通 slot operand 统一寻址为 `stack[fp + slot]` | call、ret；tailcall 保持当前 `fp` |
| `ctx` | 当前 execution context 的 VM-owned handle，提供 module storage、host binding、opaque object table 和 termination state；不进入字节码文件，也不可作为普通 operand 读写 | embedding host 创建，context 终止时失效 |

`pc/sp/fp` 使用 VM index 而不是主机地址，所有加法和范围在执行前或 bytecode validation 中检查。专用寄存器不属于 bytecode operand，普通指令不能读写它们；只有 opcode 的固定语义可以更新它们。可暂停 VM 的快照包含这四个寄存器和 stack，program image 由外部保持存活；恢复时先由 `pc` 重建 `current_func` 缓存。

每个普通 call 在新 frame 的 value slots 前保存固定 call header：`previous_fp`、`return_pc`、`return_dst`；`fp` 指向 header 之后的 slot 0，因此 header 起始位置可由 `fp - header_cells` 得到。根 frame 使用 invalid `return_pc` sentinel，根函数 `ret` 表示正常结束 context。frame 的 runtime 大小由当前 FunctionDesc 的 value、scratch 和 cleanup layout 决定。

### 基于虚拟寄存器的 calling convention

每个函数拥有独立的虚拟寄存器文件，寄存器编号就是 `fp` 相对 slot：

```text
r0 .. r(P-1)                    parameters
rP .. r(value_slot_count-1)     SSA locals/results
next scratch_slot_count         parallel-copy/call staging
next cleanup_count              cleanup armed state
```

参数寄存器顺序与 `FunctionDesc.signature.params` 一致。caller 先按 Stilla 的从左到右规则计算 callee 和全部参数，再由 call descriptor 将 caller registers 映射到 callee 的 `r0..r(P-1)`；plain/borrow/move 的 copy、alias、ownership transfer 由已专门化的 callee signature 固定。callee 不读取 caller frame，borrow 参数携带的 runtime value/view 仍受输入 CFG 已验证的 provenance 约束。

```text
CallDesc
  args_start: u32       index into BytecodeProgram.call_args
  args_len: u32         must equal callee parameter count

BytecodeProgram.call_args: []ValueReg
```

固定宽度调用 opcode：

| opcode | `a` | `b` | `c` |
| --- | --- | --- | --- |
| `call_direct` | callee FunctionId | CallDescId | caller return-destination register，void 为 `no_reg` |
| `call_indirect` | caller function-value register | CallDescId | caller return-destination register，void 为 `no_reg` |
| `ret` | result register，void 为 `no_reg` | 0 | 0 |
| `tailcall_self` | CallDescId | 0 | 0 |

`call_direct`/`call_indirect` 原子执行以下步骤：

1. 保存 `caller_fp = fp`，校验 CallDesc 与 callee signature，并为 call header 和完整 callee frame 预留 stack；stack overflow 在任何 frame 写入前 trap。
2. 令 `return_pc = pc + 1`，在 `sp` 写入 `{ previous_fp, return_pc, return_dst }`。
3. 令 `fp` 指向新 frame 的 `r0`，按参数顺序从 `stack[caller_fp + arg_reg]` 写入互不重叠的 `r0..r(P-1)`，并初始化 scratch/cleanup 区。
4. 令 `sp` 指向新 frame 末尾，`pc = functions[callee].entry_pc`。

`ret rN` 先暂存 `rN`，再恢复 header 中的 `previous_fp/return_pc`，最后写入 caller 的 `return_dst`。根 frame 的 `ret` 结束正常执行。`tailcall_self` 不写 call header：它先将实参暂存到当前 frame 的 scratch 区，再覆盖 `r0..r(P-1)`，将其余 value/scratch slots 标记为未初始化并重置 cleanup bits，保持 `fp`，重置 `sp`，并跳到当前函数的 `entry_pc`。

### 专用寄存器使用规则

| 操作 | 寄存器读取 | 寄存器更新 |
| --- | --- | --- |
| fetch/decode | 读取 `pc`；以 `ownerOf(pc)` 或 `current_func` 缓存取得 FunctionDesc | 普通指令完成后 `pc += 1` |
| frame slot op | 读取 `fp`，访问 `stack[fp + slot]` | 不更新专用寄存器 |
| constant op | 读取 `BytecodeProgram.constants[ConstId]` | 完成后 `pc += 1` |
| `j`/`br`/`switch` | 条件或 tag 来自 `fp` 相对 slot | `pc = absolute_target_pc`；`fp/sp` 不变，target 必须仍在当前 FunctionDesc 范围内 |
| direct/value `call` | 读取 caller `pc/fp/sp`、callee FunctionId 和全部 argument slots | 在 `sp` 写 call header 与新 frame；`fp = new_frame_slot0`，`sp = frame_end`，`pc = functions[callee].entry_pc`；实现缓存切换到 callee descriptor |
| `ret` | 先把返回值暂存，读取当前 frame 前的 call header | 根 frame 直接正常终止；否则 `sp = header_start`，恢复 `fp = previous_fp`、`pc = return_pc`，由 `pc` 重建 caller descriptor，再写 `stack[fp + return_dst]` |
| self `tailcall` | 读取当前 FunctionDesc、`fp` 和全部 argument slots；输入 CFG 保证没有 armed cleanup 或其他 live *Unique* local | 先写不重叠 staging slots，再覆盖 parameter slots；`fp` 不变，`sp = fp + current.frame_size`，`pc = current.entry_pc` |
| `syscall` | 参数来自 `fp` 相对 slot；通过 `ctx` 查 host binding/runtime object | 不切换 frame；正常返回后 `pc += 1`，trap 时 context 立即终止 |
| `load/store_member` | home module 从 `ownerOf(pc) → module_id → ctx.modules` 推导；跨模块形式读取显式 ModuleId | 不更新专用寄存器；完成后 `pc += 1` |
| cleanup op | `cleanup_base = fp + ownerOf(pc).cleanup_base`，按 CleanupId 访问 armed state | 只修改当前 frame cleanup cell；完成后 `pc += 1` |
| dynamic drop/`any`/opaque | 读取 value slot、TypeId/DropId 和 `ctx` | 正常完成后 `pc += 1`；hook/syscall trap 立即终止 |
| `trap`/panic | 读取 `ctx` | 标记 context terminated 并返回 host；不执行 pending cleanup/drop，之后不得再读取 `pc/sp/fp` 执行 Stilla 指令 |

call 必须先完成 callee 与全部参数的从左到右求值，再分配并写入新 frame。ret 必须先暂存返回值，再恢复 caller 寄存器，最后写 return destination。tailcall 必须先把所有实参放入不与参数区重叠的 staging slots，再覆盖当前 frame 的参数 slots；它不创建 call header，也不增长 stack。

## 不能丢失的语义

| 约束 | 字节码要求 |
| --- | --- |
| 从左到右且恰好一次求值（Runtime §5） | 保持 block 内指令顺序；`and`/`or` 继续使用真实控制流 |
| panic/trap 不展开栈（Runtime §7） | trapping opcode 立即终止 context，不执行 pending drop 或 cleanup |
| *Unique* 恰好转移或销毁一次（IR §6） | CFG 验证后再编码；move、drop、call mode 的运行时效果不能被普通 bit-copy 替代 |
| maybe-*Unique* 条件销毁（IR §6.4） | `cleanup_arm/disarm/drop` 降为 frame cleanup slot 与 armed bit |
| 原子 consuming destructure（IR §5.3） | 多结果写入必须作为一个不可部分完成的动作；descriptor 保留结果顺序 |
| drop hook 与逆序结构销毁（Runtime §6） | 首版消费 `cfg_lower_drop` 的展开结果；动态 `list`/`any`/opaque/`hostdata` drop 仍由 runtime dispatch |
| tailcall 原子替换参数（IR §14.7.1） | 先暂存全部参数，再覆盖 `fp` 相对的 parameter slots；保持 `fp`，重置 `sp/pc`，不增长 call stack |
| module 初始化/销毁顺序（Runtime §2） | ModuleId、member/slot 两套索引以及 `init_order` 必须进入 runtime image |
| `any` 与 opaque host type | 使用稳定 TypeId/HostTypeId；`hostdata` 不进入 `any` tag 空间 |

## 当前状态

阶段 0 的 IR 自包含前置条件已完成：`IrProgram` 包含 concrete type declarations，`IrModule` 包含 member table，`SysCall` 携带 specialized signature，`borrow_variant` 与 `tailcall` 已进入 IR 文法，且 §9.5 的 terminator 术语已与 §3、§10 及 `cfg.Terminator` 的 `j`/`br` 一致。

字节码实现尚未开始；以下阶段 1–3 仍是实现计划。

## 阶段 0 — 补齐自包含 IR

- [x] 0.1 `src/cfg.zig`、`src/passes/cfg_lower_program.zig` — 将 `IrProgram.types` 从名称表补齐为规范 §9.1 的 concrete `TypeDecl`，包含 struct fields、union variants、ownership、drop hook 和 opaque `host_id`。
  验收: 不读取 `ModuleGraph` 即可从 `IrProgram` 查询任一 named type 的布局、ownership 与销毁信息；`zig build test` 通过。
- [x] 0.2 `src/cfg.zig`、`src/passes/cfg_lower_module.zig` — 为 `IrModule` 物化规范 §7/§9.6 的 member table，并保持 member index 与 constant slot index 为不同索引空间。
  验收: 每个 `load_member` 和 `store_member` 均可仅通过 `IrProgram` 解析到合法 member/slot；validator 增加越界与 kind 检查。
- [x] 0.3 `src/cfg.zig`、`src/passes/cfg_lower_call.zig`、`src/passes/cfg_validate.zig` — 将专门化后的完整 `FunctionType` 写入 `SysCall`，校验参数 type/mode 与返回类型。
  验收: 一个 syscall 的 plain/borrow/move 错配可由 `cfg_validate` 独立拒绝，不依赖 checker annotation。
- [x] 0.4 `spec/ir.md` — 将 §9.5 的 `branch`/`branch_cond` 术语与 §3、§10 及 `cfg.Terminator` 的 `j`/`br` 对齐。
  验收: §3、§9、§10 中的 terminator 名称和集合一致，且与 `cfg.Terminator` 一一对应。

## 阶段 1 — 冻结字节码模型

- [ ] 1.1 新增 `src/bytecode.zig` — 定义全局 `instructions`、16-byte `Instr`、`Opcode`、`ValueReg`、`pc/sp/fp/ctx` 专用寄存器契约、dense ID 类型、function/block descriptors 和扁平 side tables；opcode 必须是稳定的显式整数，不能依赖 Zig enum ordinal。
  验收: `@sizeOf(bytecode.Instr) == 16`，所有可序列化 record 字段均为定宽整数且无 pointer/slice/string；`pc/sp/fp` 为 VM index，`ctx` 明确不序列化，当前函数可由任意合法 `pc` 唯一解析。
- [ ] 1.2 `src/bytecode.zig` — 明确每个 opcode 的 `a/b/c/flags` schema 与专用寄存器读写集合，并为 n-ary operands/results、call signature、switch arms 和 phi edge copies 定义 descriptor。
  验收: `cfg.op_table` 中每个可执行 op 及全部 terminator 都有唯一 lowering 规则；schema 测试能拒绝错误 descriptor kind/range 和非法 `pc/sp/fp` 效果。
- [ ] 1.3 `src/bytecode.zig` — 固化 `FunctionDesc` code range、call header、frame slot、argument staging、return destination 和 cleanup slot 的布局；所有普通 value operand 均为 `fp` 相对 slot。
  验收: nested call/ret 从 header 恢复原 `pc/fp/sp` 并由 `pc` 找回 caller FunctionDesc；self-tailcall 保持 `fp` 且不增加 stack depth；参数互换不会因原地覆盖丢值。
- [ ] 1.4 `src/bytecode.zig` — 固化 `call_direct`、`call_indirect`、`ret`、`tailcall_self` 和 CallDesc schema；参数进入 callee `r0..r(P-1)`，return destination 保存在 call header，返回地址为 absolute `pc + 1`。
  验收: direct/indirect、void/value、nested、recursive 和 self-tailcall 均只通过 call opcode 完成 frame 转移；字节码无需显式 prologue/epilogue 或 return-address spill。
- [ ] 1.5 `spec/ir.md` 或新增 `docs/bytecode.md` — 固化 bytecode 只是 validated CFG 的后端投影，不替代 canonical SSA IR，也不作为首版稳定持久化 ABI。
  验收: 文档明确版本号、整数宽度、ID 空间、side-table 所有权、trap 行为及 serialization 非目标。

## 阶段 2 — 后端规范化

- [ ] 2.1 新增 `src/passes/cfg_lower_bytecode.zig` — 以 `*const cfg.IrProgram` 为输入，按 module/function order 和 `cfg.BlockOrder` 分配 dense FunctionId/BlockId；先计算每个 block 的 record 数，再将所有函数展平到单一 `instructions` 并回填 absolute PC。最终 `cfg.renumberValues` 后的 ValueId 作为首版 `fp` 相对 frame slot。
  验收: lowering 前后 `cfg.print` 输出完全相同；任意优化后 block id 空洞不会进入 bytecode；FunctionDesc code ranges 不重叠，每个 entry/branch/switch target 都是全局有效 PC 且位于目标函数范围内。
- [ ] 2.2 `src/passes/cfg_lower_bytecode.zig` — 将字符串、常量、concrete type、module、function、host binding 和 signature intern 为稳定 ID；将 direct call/module/member 引用解析为整数。
  验收: BytecodeProgram 的 instruction records 不含名称或指针；相同实体只占一个 table row。
- [ ] 2.3 `src/passes/cfg_lower_bytecode.zig` — 消除 phi：在 predecessor edge 插入 parallel slot copies，必要时拆 critical edge，copy cycle 使用一个 scratch slot；*Unique* phi 按 ownership transfer 处理。
  验收: 输出 opcode 集中不存在 phi；diamond、borrowed-view join、循环 header phi 均得到正确 edge copies，且 CFG validator 在 lowering 前通过。
- [ ] 2.4 `src/passes/cfg_lower_bytecode.zig` — 将 generic arithmetic/comparison/cast 依据 concrete type 专门化，例如 `i32_add`、`u32_add`、`f32_add`，使 trap 行为由 opcode 固定。
  验收: interpreter dispatch 无需读取 result type 即可区分有符号溢出、`u32` wrap 和 IEEE `f32` 行为。
- [ ] 2.5 `src/passes/cfg_lower_bytecode.zig` — 将 `construct`、calls、syscalls、multi-result destructure、switch/tailcall 编为 fixed record + descriptor；调用分别降为 `call_direct`/`call_indirect`，返回降为 `ret`，self tail call 降为 `tailcall_self`，并明确 `pc/sp/fp` 转移。
  验收: 覆盖 0/1/N 参数、void/value 返回、跨函数 nested direct/indirect call、switch 与 self-tailcall；参数寄存器、absolute PC、FunctionId、descriptor range 和 return destination 均在界内。
- [ ] 2.6 `src/passes/cfg_lower_bytecode.zig` — 将 `borrow`/`move`/`copy` 规范化为明确的 slot 操作；验证期专用的 `ValueState`、`BorrowOrigin`、dominance/availability 信息不复制进 runtime image。
  验收: bytecode 仍显式区分 copy、ownership transfer 与 alias；borrow root 被 move/drop 后使用的问题已由输入 CFG validator 拒绝。
- [ ] 2.7 `src/passes/cfg_lower_bytecode.zig` — 将 cleanup token 映射到当前 `fp` 的 cleanup descriptors/armed bits，保留 `cleanup_arm/disarm/drop` 的原有顺序。
  验收: definitely-owned、definitely-released、maybe-*Unique* 三种路径分别产生普通 drop、无 cleanup、条件 cleanup；ret 正常完成 frame，trap 立即终止且不执行 cleanup。

## 阶段 3 — 验证与度量

- [ ] 3.1 新增 `src/passes/bytecode_validate.zig` — 只校验 bytecode 层不变量：dense/range IDs、全局 PC target、FunctionDesc code range、block 边界、terminator 位置、descriptor kind、`fp` 相对 slot、最大 `sp`/frame size 与 opcode schema；不重复 SSA dominance/ownership 分析。
  验收: 对每类非法 FunctionId、越界/跨函数 PC、重叠 code range、越界 slot/range、错误 descriptor、stack size overflow 和缺失 terminator 至少有一个最小拒绝测试。
- [ ] 3.2 `src/frontend_tests.zig` — 增加覆盖 arithmetic、construct、direct/value call、syscall、phi、switch、多结果 destructure、tailcall、cleanup 和动态 drop 的 normalization 测试。
  验收: `zig build test` 验证 record 恒为 16 字节、输入 CFG 未修改、所有引用合法，并以最小 VM state model 验证参数到 `r0..r(P-1)`、call header、call/ret/tailcall 的 `pc/sp/fp` 转移以及 resume 后的 FunctionDesc 重建。
- [ ] 3.3 `src/frontend_tests.zig` — 将 bytecode normalization 接入现有 optimizer corpus harness，记录 instruction count、descriptor bytes、frame slot count 与总 image bytes。
  验收: examples corpus 全部可 normalize；报告能区分 fixed records 与 side tables 的空间占用。

## 延后优化（先度量后实施）

- 4.1 若 dispatch profile 显示收益，融合仅用于 `switch` 的 `read_tag` 为 typed `switch_union`；`any` 的开放 tag 匹配仍保留 `type_is` 分支链。验收: opcode 数或 dispatch 数下降，且 union exhaustiveness、implicit trap default 行为不变。
- 4.2 若 frame size 成为瓶颈，再增加 slot lifetime reuse；首版保持 ValueId → slot 的一一映射。验收: corpus 最大 frame slot 数下降，并通过 ownership、borrow、tailcall 全量测试。
- 4.3 若 expanded drop 显著放大 image，再评估 `drop slot, DropPlanId`；drop plan 必须保留 hook-first、逆序字段/元素、active union payload 与中途 trap 语义。验收: 含嵌套 struct/union/box 的 corpus image 明显缩小，且 drop hook 输出顺序与当前 CFG 完全一致。
- 4.4 若 side-table 间接访问成为热点，再评估 24/32-byte record 或少量 specialized wide opcode；不要仅为“所有操作数内联”拆成大量二元临时指令。验收: 由 benchmark 证明吞吐收益超过 image size 增长后再合入。

## 明确不采用

- 不把 fixed-width 字段加入 `cfg.Op`，也不让 optimizer 操作 bytecode。
- 不为满足三地址形式把所有 n-ary op 拆成二元链；side table 更小且保留原子 destructure 语义。
- 不让解释器直接维护 predecessor 状态执行 phi；后端 edge copies 更简单。
- 不直接序列化 `cfg.IrProgram` 或 Zig `extern struct` 的内存镜像。
- 不在 correctness 建立前引入 compact drop plan；现有 `cfg_lower_drop` 已提供最小正确路径。

## 备注（非本计划范围）

- 解释器 dispatch loop、value 的具体 runtime representation、module instantiation 和 context 生命周期；本计划只规定全局 instruction table、frame 布局与 `pc/sp/fp/ctx` 状态转移契约。
- host vtable、opaque object table、`any`/`list` 的具体堆表示及内存管理策略。
- 稳定磁盘格式、跨版本兼容、校验和、调试信息、source map。
- JIT、GC、并发执行、异常展开；Stilla v1.3 trap 明确不展开栈。
