def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)

def print_terms(i: int, n: int) -> None:
    if i < n:
        print(fib(i))
        print_terms(i + 1, n)

def main() -> None:
    print_terms(0, 35)

if __name__ == "__main__":
    main()
