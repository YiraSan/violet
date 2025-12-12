# violetOS

![Zig Version](https://img.shields.io/badge/Zig-0.14.1-orange.svg?logo=zig)
![GitHub License](https://img.shields.io/github/license/YiraSan/violet)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/YiraSan/violet/dev-build.yml)

**Making humble hardware scream.**

> [!IMPORTANT]
> As defined by [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), versions in the 0.x.y range are inherently unstable and may introduce breaking changes at any time. Until we reach 1.0.0, version increments will follow development [milestones](https://github.com/YiraSan/violet/milestones) rather than strict backward compatibility.

**violetOS** is an operating system built from first principles in Zig, establishing a new architecture distinct from UNIX and POSIX conventions. It features a vector-asynchronous and polymorphic kernel designed for atomic modularity and fearless concurrency.

The project aims to eliminate system unpredictability by prioritizing isolation and explicit dependency management. Instead of optimizing for speed through complex heuristics, violetOS seeks performance through architectural simplicity, interface-driven polymorphism, and zero-copy mechanisms.

It isn't an imitation of the past; it is a robust, lightweight, and unapologetically forward-looking platform designed to define what a secure, high-performance operating system can be in the modern era.

## Physically-Monolithic. Logically-Microkernel.

violetOS decouples software architecture from execution strategy. Logically, it enforces a strict microkernel design: the core is hollow, containing only the scheduler and IPC, while drivers and services remain distinct modules interacting through explicit interfaces. This guarantees modularity and prevents the tight coupling typical of traditional monolithic kernels.

Physically, however, the runtime adapts to the context. While untrusted processes remain strictly isolated, trusted modules share the kernel's address space. This hybrid approach preserves the architectural cleanliness of a microkernel while reclaiming the raw performance of a monolith—enabling direct function calls and zero-copy mechanisms—precisely where they are needed.

## Requirements

This project uses and is tested with [Zig](https://github.com/ziglang/zig) `0.14.1`. We recommend using [zvm](https://github.com/tristanisham/zvm) to install and manage Zig versions.

To run a virtual instance of violet on your computer, you will also need [QEMU](https://www.qemu.org).

## Build it yourself

Thanks to Zig, building and running an operating system has never been so easy. Ensure you're using a compatible Zig version, then simply type:

```bash
zig build -Dplatform={IDENTIFIER}
```

Default to `aarch64_qemu` (see [Platform matrix](#platform_matrix) for more details).

### Running violetOS on QEMU

It is as simple as building violetOS:

```bash
zig build run -Dplatform={IDENTIFIER}
```

## Platform matrix

> [!NOTE]
> **Regarding x86_64:**
> While the codebase is architected with x86_64 portability in mind, active implementation is currently deferred. The legacy complexity of the x86 architecture creates unnecessary friction for rapid prototyping and obscures architectural clarity. We prioritize cleaner ISAs (AArch64, RISC-V) to validate our core concepts first.

| Platform | Identifier | State |
| -------- | ---------- | ----- |
| QEMU (aarch64)              | `aarch64_qemu` | ✅<sup>1</sup> |
| QEMU (riscv64)              | `riscv64_qemu` | 🗓️<sup>3</sup> |
| Raspberry Pi 4<sup>4</sup>  | `rpi4`         | 🔨<sup>2</sup> |
| Raspberry Pi 3<sup>5</sup>  | `rpi3`         | 🗓️<sup>3</sup> |

<sup>1</sup> ✅ means "Supported".

<sup>2</sup> 🔨 means "Partially supported / Unstable (WIP)".

<sup>3</sup> 🗓️ means "Planned".

<sup>4</sup> Raspberry Pi 4B, 400 and 4 CM.

<sup>5</sup> Raspberry Pi 3B, 3B+ and 3 CM.

## License

Distributed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0). See [LICENSE](LICENSE) and [NOTICE](NOTICE) for more information.
