_END=$'\x1b[0m
_BOLD=$'\x1b[1m
_PURPLE=$'\x1b[35m

info_limine = /bin/echo -e "$(_PURPLE)[extern/limine]$(_END) $(_BOLD)$1$(_END)"

install/limine:
ifeq ($(wildcard ./boot/limine/.*),)
	@ mkdir -m 777 -p boot/limine
	@ $(call info_limine,"Downloading...")
	@ cd boot && git clone https://github.com/limine-bootloader/limine.git --branch=v7.0.3-binary --depth=1 
	@ $(call info_limine,"Installing...")
	@ cd boot/limine && make
	@ $(call info_limine,"done.")
endif

info_ovmf = /bin/echo -e "$(_PURPLE)[extern/ovmf]$(_END) $(_BOLD)$1$(_END)"

install/ovmf-aarch64:
ifeq ($(wildcard ./boot/ovmf-aarch64/.*),)
	@ mkdir -m 777 -p boot/ovmf-aarch64
	@ $(call info_ovmf,"Downloading for aarch64...")
	@ cd boot/ovmf-aarch64 && curl -Lo OVMF-AA64.zip https://efi.akeo.ie/OVMF/OVMF-AA64.zip && unzip OVMF-AA64.zip
	@ $(call info_ovmf,"done.")
endif

install/ovmf-x86_64:
ifeq ($(wildcard ./boot/ovmf-x86_64/.*),)
	@ mkdir -m 777 -p boot/ovmf-x86_64
	@ $(call info_ovmf,"Downloading for x86_64...")
	@ cd boot/ovmf-x86_64 && curl -Lo OVMF-X64.zip https://efi.akeo.ie/OVMF/OVMF-X64.zip && unzip OVMF-X64.zip
	@ $(call info_ovmf,"done.")
endif

build/x86_64: install/limine 
	@ make build/x86_64 -C kernel
	# Build ISO
	@ mkdir -p boot/init/
	@ cp kernel/bin/kernel.elf boot/init/
	@ cp boot/limine.cfg boot/init/
	@ mkdir -p boot/init/limine/
	@ cp boot/limine/limine-bios.sys boot/limine/limine-bios-cd.bin boot/limine/limine-uefi-cd.bin boot/init/limine/
	@ xorriso -as mkisofs -b limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        boot/init/ -o violet-x86_64.iso
	@ boot/limine/limine bios-install violet-x86_64.iso

X86_64_QEMU_FLAGS = \
	-bios boot/ovmf-x86_64/OVMF.fd \
	-cdrom violet-x86_64.iso \
	-machine q35 \
	-m 2G \
	-smp cores=4 \
	-serial stdio \
	-no-reboot \
	-no-shutdown

run/x86_64: build/x86_64 install/ovmf-x86_64
	qemu-system-x86_64 $(X86_64_QEMU_FLAGS) -enable-kvm
