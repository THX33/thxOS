#pragma once
#include "defs.h"
#include "cpu.h"

#define ALL         0xFF

#define TIMER		0x20
#define KEYBOARD	0x21
#define CASCADE		0x22
#define COM2_4		0x23
#define COM1_3		0x24
#define LPT			0x25
#define FLOPPY		0x26
#define FREE7		0x27

#define CLOCK		0x28
#define FREE9		0x29
#define FREE10		0x2A
#define FREE11		0x2B
#define PS2MOUSE	0x2C
#define COPROC		0x2D
#define IDE_1		0x2E
#define IDE_2		0x2F

#define EOI 0x20

#pragma pack(push, 1)
struct interrupt_context
{
	registers_t regs;       // all general-purpose registers.
	uint64_t    int_no;		// interrupt vector number.
	uint64_t    retaddr;    // interrupt return address.
	uint64_t    cs;         // code segment.
	uint64_t    rflags;     // flags register.
	uint64_t    rsp;        // stack pointer.
	uint64_t    ss;         // stack segment.
};
#pragma pack(pop)

typedef struct interrupt_context interrupt_context_t;

typedef void(*isr_t)(interrupt_context_t *context);
void register_interrupt_handler(uint8_t interrupt, isr_t handler);

void mask_irq(uint8_t irq_no);
void unmask_irq(uint8_t irq_no);
void init_handlers(void);
void panic(interrupt_context_t *context);
