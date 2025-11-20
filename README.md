# violetOS

> [!IMPORTANT]
> As defined by [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), versions in the 0.x.y range are inherently unstable and may introduce breaking changes at any time. Until we reach 1.0.0, version increments will follow development [milestones](https://github.com/YiraSan/violet/milestones) rather than strict backward compatibility.

violetOS is a radically reimagined operating system that breaks with UNIX and POSIX conventions at its core. Every part of the system — from concurrency and isolation to memory layout and dependency handling — is designed to be transparent, predictable, and consistent, with performance emerging naturally from clever design and thoughtful architecture. violetOS does not imitate the past; it aims to define what an OS can be in a lightweight, robust, and unapologetically forward-looking way. 

## Requirements

This project uses and is tested with Zig `0.14.1`. We recommend using [zvm](https://github.com/tristanisham/zvm) to install and manage Zig versions.

To run a virtual instance of violet on your computer, you will also need [QEMU](https://www.qemu.org).

## Build it yourself

Thanks to [Zig](https://github.com/ziglang/zig) building and running an operating system has never been so easy. Ensure you're using a compatible Zig version, then simply type:

```
zig build -Dplatform={IDENFITFIER}
```

Default to `aarch64_qemu` (see [Platform matrix](#platform_matrix) for more details).

## Platform matrix

| Platform | Identifier | State |
| -------- | ---------- | ----- |
| QEMU (aarch64)              | `aarch64_qemu` | ✅<sup>1</sup> |
| QEMU (riscv64)              | `riscv64_qemu` | 🗓️<sup>3</sup> |
| Raspberry Pi 4<sup>4</sup>  | `rpi4`         | 🔨<sup>2</sup> |
| Raspberry Pi 3<sup>5</sup>  | `rpi3`         | 🗓️<sup>3</sup> |

<sup>1</sup> ✅ means "Supported".

<sup>2</sup> 🔨 means "Partially supported".

<sup>3</sup> 🗓️ means "Planed".

<sup>4</sup> Raspberry Pi 4B, 400 and 4 CM.

<sup>5</sup> Raspberry Pi 3B, 3B+ and 3 CM.
