        .code64

        /* Install relocated data selectors. */
        lgdt    gdt_descr(%rip)
        mov     $(__HYPERVISOR_DS64),%ecx
        mov     %ecx,%ds
        mov     %ecx,%es
        mov     %ecx,%fs
        mov     %ecx,%gs
        mov     %ecx,%ss

        /* Enable minimal CR4 features. */
        mov     $XEN_MINIMAL_CR4,%rcx
        mov     %rcx,%cr4

        mov     stack_start(%rip),%rsp
        or      $(STACK_SIZE-CPUINFO_sizeof),%rsp

        /* Reset EFLAGS (subsumes CLI and CLD). */
        pushq   $0
        popf

        /* Reload code selector. */
        pushq   $(__HYPERVISOR_CS64)
        leaq    1f(%rip),%rax
        pushq   %rax
        lretq
1:      lidt    idt_descr(%rip)

        test    %ebx,%ebx
        jnz     start_secondary
        jmp     start_bsp

        .section .init.text, "ax", @progbits

start_bsp:
        /* Initialise IDT with simple error defaults. */
        leaq    ignore_int(%rip),%rcx
        movl    %ecx,%eax
        andl    $0xFFFF0000,%eax
        orl     $0x00008E00,%eax
        shlq    $32,%rax
        movl    %ecx,%edx
        andl    $0x0000FFFF,%edx
        orl     $(__HYPERVISOR_CS64<<16),%edx
        orq     %rdx,%rax
        shrq    $32,%rcx
        movl    %ecx,%edx
        leaq    idt_table(%rip),%rdi
        movl    $256,%ecx
1:      movq    %rax,(%rdi)
        movq    %rdx,8(%rdi)
        addq    $16,%rdi
        loop    1b

        /* Pass off the Multiboot info structure to C land. */
        mov     multiboot_ptr(%rip),%edi
        call    __start_xen
        ud2     /* Force a panic (invalid opcode). */

/* This is the default interrupt handler. */
ignore_int:
        SAVE_ALL CLAC
        movq    %cr2,%rsi
        leaq    int_msg(%rip),%rdi
        xorl    %eax,%eax
        call    printk
        movq    %rsp,%rbp
0:      movq    (%rbp),%rsi
        addq    $8,%rbp
        leaq    hex_msg(%rip),%rdi
        xorl    %eax,%eax
        call    printk
        testq   $0xff8,%rbp
        jnz     0b
1:      hlt
        jmp     1b

        .section .init.rodata, "a", @progbits

int_msg:
        .asciz "Unknown interrupt (cr2=%016lx)\n"
hex_msg:
        .asciz "    %016lx"

/*** DESCRIPTOR TABLES ***/

        .data
        .align 8
multiboot_ptr:
        .long   0

        .word   0
GLOBAL(gdt_descr)
        .word   LAST_RESERVED_GDT_BYTE
        .quad   boot_cpu_gdt_table - FIRST_RESERVED_GDT_BYTE

        .word   0,0,0
GLOBAL(idt_descr)
        .word   256*16-1
        .quad   idt_table

GLOBAL(stack_start)
        .quad   cpu0_stack

        .section .data.page_aligned, "aw", @progbits
        .align PAGE_SIZE, 0
GLOBAL(boot_cpu_gdt_table)
        .quad 0x0000000000000000     /* unused */
        .quad 0x00af9a000000ffff     /* 0xe008 ring 0 code, 64-bit mode   */
        .quad 0x00cf92000000ffff     /* 0xe010 ring 0 data                */
        .quad 0x0000000000000000     /* reserved                          */
        .quad 0x00cffa000000ffff     /* 0xe023 ring 3 code, compatibility */
        .quad 0x00cff2000000ffff     /* 0xe02b ring 3 data                */
        .quad 0x00affa000000ffff     /* 0xe033 ring 3 code, 64-bit mode   */
        .quad 0x00cf9a000000ffff     /* 0xe038 ring 0 code, compatibility */
        .fill (PER_CPU_GDT_ENTRY - __HYPERVISOR_CS32 / 8 - 1), 8, 0
        .quad 0x0000910000000000     /* per-CPU entry (limit == cpu)      */

        .align PAGE_SIZE, 0
/* NB. Even rings != 0 get access to the full 4Gb, as only the            */
/*     (compatibility) machine->physical mapping table lives there.       */
GLOBAL(boot_cpu_compat_gdt_table)
        .quad 0x0000000000000000     /* unused */
        .quad 0x00af9a000000ffff     /* 0xe008 ring 0 code, 64-bit mode   */
        .quad 0x00cf92000000ffff     /* 0xe010 ring 0 data                */
        .quad 0x00cfba000000ffff     /* 0xe019 ring 1 code, compatibility */
        .quad 0x00cfb2000000ffff     /* 0xe021 ring 1 data                */
        .quad 0x00cffa000000ffff     /* 0xe02b ring 3 code, compatibility */
        .quad 0x00cff2000000ffff     /* 0xe033 ring 3 data                */
        .quad 0x00cf9a000000ffff     /* 0xe038 ring 0 code, compatibility */
        .fill (PER_CPU_GDT_ENTRY - __HYPERVISOR_CS32 / 8 - 1), 8, 0
        .quad 0x0000910000000000     /* per-CPU entry (limit == cpu)      */
        .align PAGE_SIZE, 0

GLOBAL(__page_tables_start)

/* Mapping of first 16 megabytes of memory. */
GLOBAL(l2_identmap)
        .quad sym_phys(l1_identmap) + __PAGE_HYPERVISOR
        pfn = 0
        .rept 7
        pfn = pfn + (1 << PAGETABLE_ORDER)
        .quad (pfn << PAGE_SHIFT) | PAGE_HYPERVISOR | _PAGE_PSE
        .endr
        .fill 4 * L2_PAGETABLE_ENTRIES - 8, 8, 0
        .size l2_identmap, . - l2_identmap

GLOBAL(l2_xenmap)
        idx = 0
        .rept 8
        .quad sym_phys(__image_base__) + (idx << L2_PAGETABLE_SHIFT) + (PAGE_HYPERVISOR | _PAGE_PSE)
        idx = idx + 1
        .endr
        .fill L2_PAGETABLE_ENTRIES - 8, 8, 0
        .size l2_xenmap, . - l2_xenmap

l2_fixmap:
        idx = 0
        .rept L2_PAGETABLE_ENTRIES
        .if idx == l2_table_offset(FIXADDR_TOP - 1)
        .quad sym_phys(l1_fixmap) + __PAGE_HYPERVISOR
        .else
        .quad 0
        .endif
        idx = idx + 1
        .endr
        .size l2_fixmap, . - l2_fixmap

GLOBAL(l3_identmap)
        idx = 0
        .rept 4
        .quad sym_phys(l2_identmap) + (idx << PAGE_SHIFT) + __PAGE_HYPERVISOR
        idx = idx + 1
        .endr
        .fill L3_PAGETABLE_ENTRIES - 4, 8, 0
        .size l3_identmap, . - l3_identmap

l3_xenmap:
        idx = 0
        .rept L3_PAGETABLE_ENTRIES
        .if idx == l3_table_offset(XEN_VIRT_START)
        .quad sym_phys(l2_xenmap) + __PAGE_HYPERVISOR
        .elseif idx == l3_table_offset(FIXADDR_TOP - 1)
        .quad sym_phys(l2_fixmap) + __PAGE_HYPERVISOR
        .else
        .quad 0
        .endif
        idx = idx + 1
        .endr
        .size l3_xenmap, . - l3_xenmap

/* Top-level master (and idle-domain) page directory. */
GLOBAL(idle_pg_table)
        .quad sym_phys(l3_bootmap) + __PAGE_HYPERVISOR
        idx = 1
        .rept L4_PAGETABLE_ENTRIES - 1
        .if idx == l4_table_offset(DIRECTMAP_VIRT_START)
        .quad sym_phys(l3_identmap) + __PAGE_HYPERVISOR
        .elseif idx == l4_table_offset(XEN_VIRT_START)
        .quad sym_phys(l3_xenmap) + __PAGE_HYPERVISOR
        .else
        .quad 0
        .endif
        idx = idx + 1
        .endr
        .size idle_pg_table, . - idle_pg_table

GLOBAL(__page_tables_end)
