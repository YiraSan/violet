# violetOS Platform Support

This document serves as the official hardware roadmap and status tracker for violetOS.

## Hardware Requirements

violetOS is designed for modern architectures. The baseline requirements are:
* **CPU:** 64-bit architecture.
* **Memory:** Minimum of 512 MiB RAM.
* **MMU:** At least 3-level paging with a 4 KiB granule.
* **System:** Functional hardware timers, interrupt controllers, and privileged syscall instructions.

## Tiers

* **Tier 4 (Bare-minimum):** The platform is successfully integrated into the build system, boots, and has a functional serial/UART driver for debugging.

* **Tier 3 (Headless):** Features working multi-core (SMP) support, memory stability, fundamental storage drivers (SD/NVMe), and basic networking.

* **Tier 2 (Workstation):** Requires a functional I/O ecosystem including primary buses (PCIe, USB) and protocols (HID, Display/Framebuffer).

* **Tier 1 (Full):** Includes hardware acceleration (GPU), power management, and specific onboard peripherals. *(Undocumented or proprietary silicon features like NPUs or Secure Elements are exempted).*

## Status Tracker

> **Legend:** <br>
> ✅ Reached <br>
> 🔨 Work in Progress (WIP) <br>
> 🗓️ Planned 

| Generic / Board | Identifier | Current State | Target Tier |
| :--- | :--- | :---: | :---: | :--- |
| **QEMU (ARM64)** | `aarch64-virt` | 🗓️ Planned | Tier 1 |
| **QEMU (x86_64)** | `x86_64-virt` | 🗓️ Planned | Tier 1 |
| **QEMU (RISC-V)** | `riscv64-virt` | 🗓️ Planned | Tier 1 |
| **Raspberry Pi 4**<sup>1</sup> | `raspberry_pi4` | 🗓️ Planned | Tier 2 |
| **Raspberry Pi 3**<sup>2</sup> | `raspberry_pi3` | 🗓️ Planned | Tier 3 |
| **VisionFive 2**<sup>3</sup> | `vision_five2` | 🗓️ Planned | Tier 3 |
| **Radxa Rock 5B** | `radxa_rock5b` | 🗓️ Planned | Tier 2 |
| **Orange Pi5 Plus** | `orange_pi5_plus` | 🗓️ Planned | Tier 2 |

***

> [!IMPORTANT]
> The final decision to include, maintain, or drop a platform remains at the sole discretion of the project maintainers.

<sup>1</sup> Includes Raspberry Pi 4B, 400 and Compute Module 4.
<sup>2</sup> Includes Raspberry Pi 3A+, 3B, 3B+ and Compute Module 3.  
<sup>3</sup> StarFive VisionFive 2 board (JH7110 SoC).
