local function fib(n)
    return n < 2 and n or fib(n - 1) + fib(n - 2)
end

local function print_terms(i, n)
    if i < n then
        print(fib(i))
        print_terms(i + 1, n)
    end
end

local function main()
    print_terms(0, 35)
end

main()
