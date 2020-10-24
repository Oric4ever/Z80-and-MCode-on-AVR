# Z80-and-MCode-on-AVR

This is another version of my Z80+CP/M emulator for ATmegas with external ram extension, such as the ATmega162.
I had some room left in the ATmega162's 16KB rom, so I added accelerators for the Turbo Modula-2 bytecode (MCode)...
I don't intend to put additional work in this project, because emulating Turbo Modula-2's bytecode revealed so good that I decided to re-engineer Turbo Modula-2 in order to remove all the Z80 code from it, and thus get a full Modula-2 machine (see Turbo Modula-2 Reloaded).
