cyan = /bin/echo -e "\x1b[36m\#\# $1\x1b[0m"

override HOME = ..

CC = clang
LD = ld.lld

CFLAGS = \
	-Iinclude \
	-ffreestanding \
	-fpie \
	-fno-stack-protector \
	-fshort-wchar \
	-g \
	-nostdlib \
	-pedantic

ASMFLAGS = \
	-Iinclude \
	-nostdlib

LDFLAGS = \
	-nostdlib \
	-static \
	--no-dynamic-linker \
	-Bsymbolic \
	--no-relax \
	-z max-page-size=0x1000

# Recursive Wild Card
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

# Source Files
C_SRC = source/main.c # kernel entry

OBJS = $(patsubst source/%.c,lib/%_c.o,$(C_SRC))
# OBJS += $(patsubst source/%.s,lib/%_s.o,$(ASM_SRC))

lib/%_c.o: source/%.c
	@ mkdir -m 777 -p $(@D)
	@ $(call cyan,"$(subst ../,,$^)")
	@ $(CC) $(CFLAGS) -c $^ -o $@

lib/%_s.o: source/%.s
	@ mkdir -m 777 -p $(@D)
	@ $(call cyan,"$(subst ../,,$^)")
	@ $(CC) $(ASMFLAGS) -c $^ -o $@

build/x86_64: \
	$(eval CLAGS += \
	--target=x86_64-unknown-none-elf \
	-mno-red-zone \
	-mno-avx \
	-mno-sse \
	-mno-mmx \
	-mno-3dnow) \
	$(eval ASMFLAGS += --target=x86_64-unknown-none-elf) \
	$(eval LDFLAGS += -T source/x86_64/kernel.ld) \
	$(eval C_SRC += $(call rwildcard,source/x86_64,*.c)) \
	$(OBJS) link

link:
	@ mkdir -p bin
	@ $(LD) $(LDFLAGS) -o bin/kernel.elf $(OBJS)
