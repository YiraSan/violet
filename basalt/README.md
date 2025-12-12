# basalt

**basalt** is the native runtime environment for violetOS, designed to replace libc with a pure Zig interface. It bridges the kernel’s vector-asynchronous architecture with application logic, transforming raw batch primitives into ergonomic concurrency structures like async mutexes and channels.

Crucially, it abstracts the execution context: at compile time, basalt automatically selects between direct function calls (for Trusted Modules) and syscall instructions (for Userland). Beyond this abstraction, it manages the process lifecycle and memory interaction, enforcing the system's non-blocking, zero-copy workflow by default.

## License

basalt is a core component of the violetOS project.

As such, it is distributed under the same terms: the **Apache License 2.0**.
