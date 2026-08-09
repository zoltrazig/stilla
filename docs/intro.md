# Stilla：一门把「可见性」当作第一原则的嵌入式脚本语言

## 一句话介绍

**Stilla** 是一门小型、静态类型、无垃圾回收（GC）的语言，专为四件事而设计：**嵌入式脚本、确定性执行、宿主集成、机器生成代码**。它的核心主张是——程序的行为应当「从源码里直接看得见」：所有权、销毁、求值顺序全部显式且确定，没有任何隐藏在编译器或运行时背后的机制。

## 五个设计原则

1. **不可变与确定性**：绑定不可变、求值严格从左到右且恰好一次、销毁顺序确定、没有可变的全局状态。
2. **值一等、状态非一等**：数据用代数数据类型（ADT）表达；文件就是不可变模块值；没有隐式接收者，没有继承。
3. **所有权显式且按值**：`borrow` 借用、`move` 转移、`drop` 销毁，没有追踪式 GC。
4. **函数单态且不捕获**：表达式式控制流、一等函数都是单态的非捕获函数、泛型在编译期特化。
5. **按值模块化、静态解析**：模块只含模块级绑定，`import` 静态解析。

这五条原则不是并列清单，而是一条递进的线索：**先有不可变的值，才有值的 ADT 形态；值确定了，才谈得上所有权；函数是值、模块也是值，所有权规则因此处处适用；最后，这些全部由写在规范里的确定性执行语义来兜底**。下面沿着这条线索，一步步认识 Stilla。

## 先看一段代码：一上来就遇见所有权

一个带 `drop` 钩子的完整资源模块，集中展示了所有权、构造与销毁的全部语义：

```stilla
const os = import("os");
const builtin = import("builtin");

struct File {
    fd: int32;
    path: str;

    drop(file) {
        os.close(file.fd);
    }
}

fn open(path: str) -> File {
    File{
        fd: os.open(path),
        path: path
    }
}

fn inspect(borrow file: File) -> void {
    builtin.print(file.path);
}
```

```stilla
const file = import("file");

fn main() -> void {
    let handle = file.open("data.txt");

    file.inspect(handle);   // 借用，不转移所有权

    drop handle;            // 显式销毁，触发 os.close
}
```

注意这里没有 `File::open`、没有 `File::gen`、没有 `def`、没有方法调用——**一切都被归一化为普通的值操作**，这是 Stilla 最核心的取向。这段代码里已经出现 `import`、`struct`、`borrow`、`drop`，初看信息量不小；别担心，接下来每个概念都会被单独拆开讲清楚。

## 第 1 步：不可变的值与 ADT

先看 Stilla 最基本的形态——绑定不可变、函数普通：

```stilla
const greeting = "hello";   // 绑定不可变，没有 let mut
const count = 42;

fn double(x: int32) -> int32 {
    x * 2
}
```

**值一等、状态非一等**：没有类的概念，没有继承。数据用 nominal 的 `struct` 和 `union` 表达，构造就是普通结构体字面量——**没有构造器机制**，语言层不强制构造不变量（这是 v1.3 明确列出的「刻意省略」）；`open()`、`create()`、`from_fd()` 都是普通函数。

**ADT 与模式匹配**，穷尽性由编译器检查：

```stilla
union Option[T] {
    Some(T),
    None
}

let message =
    match (result) {
        Result::Ok(value) =>
            "ok: " + builtin.str(value),
        Result::Err(error) =>
            "error: " + error
    };
```

**递归类型必须经过 `box[T]` 间接存储**，读用 `peek`（借用）、取用 `unbox`（转移所有权）：

```stilla
union Tree[T] {
    Empty,
    Node(box[Tree[T]], T, box[Tree[T]])
}

fn contains(borrow tree: Tree, v: int32) -> bool {
    match (tree) {
        Tree::Empty => false,
        Tree::Node(left, x, right) =>
            if (v == x) {
                true
            } else if (v < x) {
                contains(builtin.peek(left), v)
            } else {
                contains(builtin.peek(right), v)
            }
    }
}
```

**容器同样不可变**：`list` 是语言唯一的抽象序列类型；`array`、`hashmap` 不是关键字，而是普通库类型。连 `builtin.print` 都要显式 `import("builtin")` 后调用——**没有隐式注入的 `print()`/`len()`**。

至此你看到了值的形状。但「值」还有一个更深的问题：**它的生命周期谁管？** 这引出 Stilla 最核心的机制——所有权。

## 第 2 步：所有权——没有 GC，却有比 Rust 简单得多的所有权

Stilla 和 Rust 一样区分两类值：

- **可复制值（duplicable）**：`int32`、`float32`、`bool`、`str`、函数等，是 affine 的一个子集，可被隐式拷贝，对其 `drop` 不做任何事；
- **affine 值**：至多使用一次、必须恰好销毁一次的值（例如带 `drop` 钩子的结构体，或任何内含 affine 成分的聚合）。

affine 值不能被隐式拷贝，只能被借用、转移或销毁：

```stilla
let a = file.open("a.txt");
let b = move a;            // 显式转移所有权，此后 a 无效
inspect(a);                // 编译错误：use after move

inspect(b);                // borrow 参数：非拥有视图，可多次
inspect(b);

consume(move b);           // move 参数：接收所有权
```

但 Stilla 砍掉了 Rust 最重的部分：

- **没有生命周期标注**。借用被刻意限制为「词法上可检查」的范围，不能逃逸出操作或参数作用域；用户函数不能返回借用的 affine 值。
- **没有 trait、没有泛型函数值**。参数只有三档：普通（只收可复制值）、`borrow`（非拥有视图）、`move`（接收所有权）。
- **没有局部移动**。`move` 只能作用于完整局部绑定；要拆开 affine 结构，用整值解构：

```stilla
let Pair{
    first,
    second
} = move pair;   // 整值解构，first / second 各自成为独立所有者
```

资源生命周期不止「转移」一种动作，还有「销毁」——一个 `drop(file)` 钩子就是全部生命周期机制，且不可直接调用，由销毁时机自动触发（详见第 5 步）。回想开头那段代码：`drop handle` 显式销毁 `File`，自动触发 `os.close`。

结果：资源安全仍然成立，但**没有任何需要「编译器大脑」才能读懂的部分**——它要的是可预测，不是强大的表达力。

## 第 3 步：函数——一等公民，但没有闭包

所有权确定后，再来认识 Stilla 里唯一的行为载体：函数。函数和 lambda **不得捕获**外层函数的局部绑定——这在现代语言里几乎是独一无二的：

```stilla
fn example() -> fn(int32) -> int32 {
    let factor = 2;

    fn(x: int32) -> int32 {   // 编译错误：不得捕获 factor
        x * factor
    }
}
```

函数只能引用参数、自身局部量、模块常量、导入模块。这让函数表示平凡且可预测：配合「泛型全部编译期特化、运行时函数值全部单态」（第 6 步），`fn` 值就是一张可查的纯函数表，对机器生成代码和宿主嵌入极其友好。

函数还是一等值，可以放进结构体里。由于**没有隐式接收者**，函数字段必须显式接收自己需要的实例：

```stilla
struct Counter {
    value: int32;
    next: fn(borrow Counter) -> int32;
}

let counter = Counter{
    value: 10,
    next: fn(borrow counter: Counter) -> int32 {
        counter.value + 1
    }
};

counter.next(counter);   // 必须显式传实例，没有 counter.next() 这种糖
```

## 第 4 步：模块即值

有了「函数是值」，Stilla 最优雅的模型就顺理成章了。**每个源文件编译成一个隐式的不可变模块结构体**，没有独立的「命名空间」概念：

```stilla
const calc = import("calc");

calc.add(1, 2)   // 只是普通的值成员访问
```

`import("calc")` 返回一个对模块实例的稳定引用；`calc.add` 就是普通的 `.` 取值。因此也就**不存在静态方法、关联函数、实例方法**——它们全部归一化为「取模块成员，再调用」。模块还可以嵌套：

```stilla
const std = import("std");

std.math.sqrt(16.0);        // 链式值成员访问
std.string.upper("hello");
```

为了让类型查找保持静态化，模块值被限制只能出现在模块级 `const` 绑定里，不能进入局部值流。配合 `using` 路径别名（纯编译期别名，不产生运行时成员）：

```stilla
const string = import("string");

using string.upper as up;

fn shout(text: str) -> str {
    up(text)
}
```

宿主还可以注册自己的模块，与源模块、标准库模块完全同构。

## 第 5 步：确定性——求值与销毁的每一步都被钉死

所有权管住了「值何时消失」，但还有两个问题需要答案：**表达式按什么顺序求值？值在什么时机销毁？** 大多数语言把这两个问题留给实现细节。Stilla 把它们写进规范、强制实现遵守：

> 除非显式说明，子表达式**恰好求值一次，从左到右按源码顺序**。

销毁顺序同样精确。局部 affine 值按**逆创建顺序**销毁：

```stilla
{
    let a = open("a.txt");
    let b = open("b.txt");
}   // 先销毁 b，再销毁 a
```

结构体先跑用户 `drop` 钩子、再按**逆声明顺序**销毁 affine 字段：

```stilla
struct Connection {
    socket: Socket;
    log: File;

    drop(connection) {
        builtin.print("closing connection");
    }
}
// 销毁顺序：Connection.drop → drop log → drop socket
```

`builtin.range`、`map`、`fold` 的遍历顺序、`builtin.hash` 的确定性，全部在规范里钉死。

出错路径同样确定：**panic 即终止，一切显式**。`builtin.panic("...")` 返回 `never` 类型，直接终止执行上下文，**不展开、不运行任何析构**，清理责任交给宿主。整数溢出、除零、非法索引、非法转换全部是**确定性运行时陷阱**（而不是 C 的未定义行为）。

也没有任何隐式转换：`"value = " + 42` 是编译错误，必须显式转换：

```stilla
builtin.print("value = " + builtin.str(42));
```

## 第 6 步：泛型——编译期模板，运行时没有泛型

最后一步，把「静态、确定」贯彻到泛型：泛型只是编译期特化（monomorphization）的语法糖。`identity(42)` 在编译期被展开为 `fn(int32) -> int32` 的普通函数：

```stilla
fn identity[T](move value: T) -> T {
    move value
}

let f = identity::[int32];   // 显式特化，f 是单态函数值
// let g = identity;         // 编译错误：未特化的泛型不是运行时值
```

因此运行时**不存在** `fn[T](T) -> T` 这种泛型函数值类型，也不存在动态分派——一切都是静态的、确定的。

## 回顾：六步合起来是什么

把六步连起来，就是开头那句「一切皆值」的全貌：

- **值**：不可变绑定 + ADT，没有类、没有隐式状态；
- **所有权**：duplicable / affine，`borrow` / `move` / `drop`，资源安全且无需编译器大脑；
- **函数**：一等值、不捕获、无方法，显式传接收者；
- **模块**：模块即值，`import` 静态解析，与宿主模块同构；
- **确定性**：求值恰好一次、从左到右、销毁顺序钉死、陷阱确定；
- **泛型**：编译期特化，运行时全单态。

## 与其他语言的对比

| 维度 | Stilla | Rust | Go | Lua | C | Zig |
|---|---|---|---|---|---|---|
| 类型 | 静态 | 静态 | 静态 | 动态 | 静态 | 静态 |
| 内存管理 | affine 所有权+确定性析构 | 所有权+借用检查 | GC | GC | 手动 | 手动+defer |
| 生命周期标注 | **无** | 有 | — | — | — | 无 |
| 闭包/捕获 | **无** | 有 | 有 | 有 | 无 | 无 |
| 方法/接收者 | **无** | 有 | 有 | 表方法 | 无 | 无 |
| 构造函数 | **无** | `fn new` 惯例 | `New` 惯例 | 表构造 | 无 | 无 |
| 泛型 | 编译期特化 | 单态+trait 对象 | 类型参数 | — | — | comptime 特化 |
| panic | 终止、不展开 | 默认展开（可 abort） | `recover` | error | — | 可展开/终止 |
| 确定性求值顺序 | **规范强制** | 依赖求值序已定 | spec 已定 | 实现定义 | 未定序（UB） | 未定序 |
| 嵌入宿主 | 一等目标 | 差 | 差 | 好 | 好 | 一般 |
| 不可变性 | 绑定/容器不可变 | 默认可变 | 默认可变 | 可变 | 可变 | 可变 |

一句话概括定位：**它处在 Rust 与 Lua 之间**——保留 Rust 的资源安全内核（无 GC、仿射所有权、确定性销毁），却把表达力降到 Lua 一样的「小、快、一眼看懂」，再把确定性与可静态分析推到规范级，专为嵌入与机器生成而设计。

## 适用场景

- **嵌入式脚本引擎**：静态类型 + 确定执行 + 明确的宿主契约（上下文、模块注册、终止接管）；
- **需要安全资源管理的 DSL**：机器生成的代码可以依赖确定性的求值/销毁顺序；
- **对可预测性有硬要求的沙箱**：无 GC 停顿、无异常栈、所有陷阱确定可复现。
