section .text
[bits 32]

;;
;; import / export entries between .nasm and .c parts
;;
%ifidn __OUTPUT_FORMAT__, win32
extern _EntryPoint                  ; import C entry point from main.c
EntryPoint equ _EntryPoint          ; win32 builds from Visual C decorate C names using _
%else
extern EntryPoint                   ; import C entry point from main.c
%endif

global gMultiBootHeader         ; export multiboot structures to .c
global gMultiBootStruct

;;
;; we use hardcoded address space / map for our data structures, the multiboot header and the entry point
;; the plain binary image is loaded to 0x00200000 (2MB)
;;
KERNEL_BASE_VIRTUAL_32      equ 0x40000000			    ; magic 1G VA for x86 builds
KERNEL_BASE_VIRTUAL_64      equ 0x0000000200000000	    ; magic 8G VA for x64 builds
KERNEL_BASE_PHYSICAL        equ 0x200000                ; physical address where this file will be loaded (2 MB PA)

MULTIBOOT_HEADER_BASE       equ KERNEL_BASE_PHYSICAL + 0x400 ; take into account the MZ/PE header + 0x400 allignment
                                                        ; the multiboot header begins in the .text section
MULTIBOOT_HEADER_SIZE       equ 48                      ; check out '3.1.1 The layout of Multiboot header'
MULTIBOOT_HEADER_MAGIC      equ 0x1BADB002
MULTIBOOT_HEADER_FLAGS      equ 0x00010003              ; 0x1 ==> loading of modules must pe 4K alligned, 0x2 ==> OS needs memory map
                                                        ; 0x10000 ==> OS image has valid header_addr, load_addr, ..., entry_addr

MULTIBOOT_INFO_STRUCT_BASE  equ MULTIBOOT_HEADER_BASE + MULTIBOOT_HEADER_SIZE
MULTIBOOT_INFO_STRUCT_SIZE  equ 90

MULTIBOOT_ENTRY_POINT       equ (gMultiBootEntryPoint - gMultiBootHeader) + KERNEL_BASE_PHYSICAL + 0x400

IA32_EFER                   equ 0xC0000080
CR4_PAE                     equ 0x00000020
IA23_EFER_LME               equ 0x100

PML4_BASE equ 0x1000
CR0_PE    equ 1 << 0
CR0_PG    equ 1 << 31

TOP_OF_STACK_VIRTUAL        equ KERNEL_BASE_VIRTUAL_64 + 0x10000

;;
;; KERNEL_BASE_PHYSICAL + 0x400
;;
;; *** IMPORTANT: __init.nasm MUST be the first object to be linked into the code segment ***
;;

gMultiBootHeader:                                       ; check out '3.1.1 The layout of Multiboot header'
.magic          dd MULTIBOOT_HEADER_MAGIC
.flags          dd MULTIBOOT_HEADER_FLAGS
.checksum       dd 0-(MULTIBOOT_HEADER_MAGIC + MULTIBOOT_HEADER_FLAGS)
.header_addr    dd MULTIBOOT_HEADER_BASE
.load_addr      dd KERNEL_BASE_PHYSICAL
.load_end_addr  dd 0
.bss_end_addr   dd 0
.entry_addr     dd MULTIBOOT_ENTRY_POINT
.mode_type      dd 0
.width          dd 0
.height         dd 0
.depth          dd 0

gMultiBootStruct:                                       ; reserve space for the multiboot info structure (will copy here)
times MULTIBOOT_INFO_STRUCT_SIZE db 0                   ; check out '3.3 Boot information format'


;; leave 0x40 bytes for GDT stuff
times (0x100 - MULTIBOOT_HEADER_SIZE - MULTIBOOT_INFO_STRUCT_SIZE - 0x40) db 0

GDT64:
    dq 0
.Code: equ $ - GDT64
    dq (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53)
.Pointer:
    dw $ - GDT64 - 1
    dq gdtBase
	
gdtBase equ 0x2004c0

; Paging tables. Must be 4kb aligned
p4_table equ 0x201000
p3_table equ 0x202000
p2_table equ 0x203000

;;
;; KERNEL_BASE_PHYSICAL + 0x4C0
;;

;;
;; TOP-OF-STACK is KERNEL_BASE_PHYSICAL + 0x10000
;;

;;
;; N.B. multiboot starts in 32 bit PROTECTED MODE, without paging beeing enabled (FLAT); check out '3.2 Machine state' from docs
;; we explicitly allign the entry point to +64 KB (0x10000)
;;

times 0x10000 - 0x400 - $ + gMultiBootHeader db 'G'           ; allignment

;;
;; KERNEL_BASE_PHYSICAL + 0x10000
;;
[bits 32]
gMultiBootEntryPoint:
    cli

    MOV     DWORD [0x000B8000], 'O1S1'
%ifidn __OUTPUT_FORMAT__, win32
    MOV     DWORD [0x000B8004], '3121' ; 32 bit build marker
%else
    MOV     DWORD [0x000B8004], '6141' ; 64 bit build marker
%endif

    ; enable SSE instructions (CR4.OSFXSR = 1)
    mov     eax, cr4
    or      eax, 0x00000200
    mov     cr4, eax

    mov esp, TOP_OF_STACK_VIRTUAL

    call set_up_page_tables

    ; set address of P4 table into cr3
    mov eax, p4_table
    mov cr3, eax

    ; enable PAE
    mov eax, cr4
    or eax, CR4_PAE
    mov cr4, eax

    ; set LM bit
    mov ecx, IA32_EFER
    rdmsr
    or eax, IA23_EFER_LME
    wrmsr

    ; enable paging
    mov eax, cr0
    or eax, CR0_PG
    mov cr0, eax

	lgdt [0x2004d0]
	jmp 0x08:0x210062

    [bits 64]
    longMode:
		mov ax, 0
		mov ss, ax
		mov ds, ax
		mov es, ax
		mov fs, ax
		mov gs, ax
        call EntryPoint
		
	.os_returned:
		;print "OS returned!"
		mov rax, 0x4f724f204f534f4f
		mov [0xb8000], rax
		mov rax, 0x4f724f754f744f65
		mov [0xb8008], rax
		mov rax, 0x4f214f644f654f6e
		mov [0xb8010], rax
		call __magic
		cli
		hlt

[bits 32]
set_up_page_tables:
	; Clear page tables
	mov edi, p4_table
    mov cr3, edi
    xor eax, eax
    mov ecx, 3072
    rep stosd
    mov edi, cr3

    ; map all p4 entries to first p3
    mov eax, p3_table
	or eax, 0x3 ; present + writable
	mov ecx, 512
loop_p4:
    mov [p4_table + ecx * 8], eax
	loop loop_p4
    mov [p4_table], eax

    ; map all p3 entries to first p2
    mov eax, p2_table
    or eax, 0x3 ; present + writable
    mov ecx, 512
loop_p3:
    mov [p3_table + ecx * 8], eax
    loop loop_p3
    mov [p3_table], eax

    ; map each P2 entry to a huge 2MiB page
    mov ecx, 0         ; counter variable
.loop_p2:
    ; map ecx-th P2 entry to a huge page that starts at address 2MiB*ecx
    mov eax, 0x200000  ; 2MiB
    mul ecx            ; start address of ecx-th page
    or eax, 0x83       ; huge + present + writable
    mov [p2_table + ecx * 8], eax ; map ecx-th entry
    inc ecx
    cmp ecx, 512
    jne .loop_p2

    ret

;;--------------------------------------------------------
;; EXPORT TO C FUNCTIONS
;;--------------------------------------------------------

%macro EXPORT2C 1-*
%rep  %0
    %ifidn __OUTPUT_FORMAT__, win32 ; win32 builds from Visual C decorate C names using _
    global _%1
    _%1 equ %1
    %else
    global %1
    %endif
%rotate 1
%endrep
%endmacro

[bits 64]

;;--------------------------------------------------------
;; ISR
;;--------------------------------------------------------
[EXTERN isr_handler]

%macro ISR_NOERRCODE 1
	EXPORT2C isr%1
	isr%1:
		push %1		; exception number
		push r15
		push r14
		push r13
        push r12
        push r11
        push r10
        push r9
        push r8
        push rbp
        push rdi
        push rsi
        push rdx
        push rcx
        push rbx
        push rax

		mov rcx, rsp
		call isr_handler

		pop rax
        pop rbx
        pop rcx
        pop rdx
        pop rsi
        pop rdi
        pop rbp
        pop r8
        pop r9
        pop r10
        pop r11
        pop r12
        pop r13
        pop r14
        pop r15
		add rsp, 8

		iretq
%endmacro

; Certain exceptions push and additional error code on top
; of the stack. The code must be pulled in those cases.
%macro ISR_ERRCODE 1
	EXPORT2C isr%1
	isr%1:
		push %1		; exception number
		push r15
		push r14
		push r13
        push r12
        push r11
        push r10
        push r9
        push r8
        push rbp
        push rdi
        push rsi
        push rdx
        push rcx
        push rbx
        push rax

		mov rcx, rsp
		call isr_handler

		pop rax
        pop rbx
        pop rcx
        pop rdx
        pop rsi
        pop rdi
        pop rbp
        pop r8
        pop r9
        pop r10
        pop r11
        pop r12
        pop r13
        pop r14
        pop r15
		add rsp, 8
		
		iretq
%endmacro

ISR_NOERRCODE 0
ISR_NOERRCODE 1
ISR_NOERRCODE 2
ISR_NOERRCODE 3
ISR_NOERRCODE 4
ISR_NOERRCODE 5
ISR_NOERRCODE 6
ISR_NOERRCODE 7
ISR_ERRCODE   8
ISR_NOERRCODE 9
ISR_ERRCODE   10
ISR_ERRCODE   11
ISR_ERRCODE   12
ISR_ERRCODE   13
ISR_ERRCODE   14
ISR_NOERRCODE 15
ISR_NOERRCODE 16
ISR_NOERRCODE 17
ISR_NOERRCODE 18
ISR_NOERRCODE 19
ISR_NOERRCODE 20
ISR_NOERRCODE 21
ISR_NOERRCODE 22
ISR_NOERRCODE 23
ISR_NOERRCODE 24
ISR_NOERRCODE 25
ISR_NOERRCODE 26
ISR_NOERRCODE 27
ISR_NOERRCODE 28
ISR_NOERRCODE 29
ISR_NOERRCODE 30
ISR_NOERRCODE 31


;;--------------------------------------------------------
;; IRQ
;;--------------------------------------------------------
[EXTERN irq_handler]
%macro IRQ 2
	global irq%1
	irq%1:
		push %2		; remapped irq number
		push r15
		push r14
		push r13
        push r12
        push r11
        push r10
        push r9
        push r8
        push rbp
        push rdi
        push rsi
        push rdx
        push rcx
        push rbx
        push rax
		
		mov rcx, rsp
		call irq_handler

		pop rax
        pop rbx
        pop rcx
        pop rdx
        pop rsi
        pop rdi
        pop rbp
        pop r8
        pop r9
        pop r10
        pop r11
        pop r12
        pop r13
        pop r14
        pop r15
		add rsp, 8

		iretq
%endmacro

IRQ   0,	32
IRQ   1,	33
IRQ   2,	34
IRQ   3,	35
IRQ   4,	36
IRQ   5,	37
IRQ   6,	38
IRQ   7,	39
IRQ   8,	40
IRQ   9,	41
IRQ   10,	42
IRQ   11,	43
IRQ   12,	44
IRQ   13,	45
IRQ   14,	46
IRQ   15,	47

EXPORT2C __cli, __sti, __magic, __lidt
__cli:
    cli
    ret

__sti:
    sti
    ret

__magic:
    xchg bx, bx
    ret

__lidt:
	mov eax, [esp+8] 
    lidt [eax]
    ret
