#include <avr/io.h>
#include <avr/interrupt.h>

#define BAUD 38400L

void uart0_init(void)
{
    volatile char c;
    /* Initialize UART0 to BAUD, 8N1 */
    UBRR0H = 0;
    UBRR0L = 18432000L/16/BAUD-1;
    UCSR0A = 0;
    UCSR0B = _BV(TXEN0) | _BV(RXEN0) | _BV(RXCIE0);
    UCSR0C = _BV(URSEL0) | _BV(UCSZ01) | _BV(UCSZ00); // 8 bit data
    if (UCSR0A & _BV(RXC0)) c = UDR0;
    sei();
}

ISR(USART0_RXC_vect)
{
    extern void kbd_enqueue(unsigned char c);
    unsigned char status = UCSR0A;
    unsigned char c = UDR0;
    if (status & (UPE0 | FE0)) return;
    kbd_enqueue(c);
}
