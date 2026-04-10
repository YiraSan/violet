# violetOS

![Rust Nightly](https://img.shields.io/badge/Rust-nightly-orange?logo=rust)
![GitHub License](https://img.shields.io/github/license/YiraSan/violet)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/YiraSan/violet/dev-build.yml)

**Making humble hardware scream.**

> [!IMPORTANT]
> As defined by [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), versions in the 0.x.y range are inherently unstable and may introduce breaking changes at any time. Until we reach 1.0.0, version increments will follow development [milestones](https://github.com/YiraSan/violet/milestones).

**violet** (pronounced /vjɔlɛt/) is a work-in-progress operating system built in Rust, centered on a fully asynchronous and non-blocking architecture. It aims to establish a highly predictable software stack where performance and isolation are balanced through an anykernel design.

By decoupling logical structure from execution strategy, the system enforces microkernel-style modularity while allowing trusted services to operate in shared kernel space. This enables zero-copy data paths protected by Rust’s safety guarantees rather than relying solely on expensive hardware context switching.

The project is in an early development phase, focused on maturing these architectural foundations into a scalable, general-purpose system for modern hardware.

## Requirements

This project uses and is tested with [Rust](https://rust-lang.org) nightly.

To run a virtual instance of violet on your computer, you will also need [QEMU](https://www.qemu.org).

## Build it yourself

Thanks to `forge` (violet' build system), building and running an operating system has never been so easy.

```bash
cargo x build --platform {PLATFORM}
```

Default platform is `aarch64-qemu` (see [Support](SUPPORT.md) for more details).

### Running it on QEMU

Simply type:
```bash
cargo x run --platform {PLATFORM}
```

## License

Distributed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0). See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for more information.
