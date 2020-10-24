/*
  Z80 and CP/M emulator by F.Frances, (C) 2019.

  This targets ATmega processors with external SRAM
  such as ATmega161/162/640/1280/2560/1281/2561...
    
  However, for speed efficiency, the emulator does not try to access the
  part of the external SRAM that is overlayed by the internal ram nor the
  first page reserved for the ATmega's I/Os. So the memory map accessible
  by the emulated Z80 is 0000-FAFF (mapped to the ATmega's 0500-FFFF).

  The 1KB internal ram of the ATmega162 is used for a sector buffer (512 bytes),
  a few variables, and the AVR stack (used when calling a few C routines).

  Caveats:
    - I first wrote a 8080 emulator and added the Z80 instructions afterwards,
      so the mnemonics are those of the Intel 8080.
    
      running programs on CP/M (eg. Z80 extended IO instructions, not used due
      to hardware abstraction given by CP/M's BIOS)
    - N flag not implemented (memorizes if last operation was an addition or
      subtraction, for correct adjustement in DAA): DAA will always assume
      last operation was an addition...
    - BCD handling not tested, and two extended BCD instructions (RLD,RRD) are
      not implemented...
    - when accessing memory from AVR code, beware that the Z80 address space
      is translated: every page #n of the Z80 is mapped to the physical page
      #n+5.

  Speed: 
    It depends on the Z80 instructions that are executed, but roughly I have
    observed that a 16 MHz ATmega162 gives a ~ 7 or 8 MHz Z80...

  Examples of instructions timing in AVR cycles (all memory accesses considered
  in external mem):

    nop             =>   5 cycles
    ld  a,b         =>   6 cycles
    ld  e,10        =>   8 cycles
    ld  b,(hl)      =>  11 cycles
    ld  (hl),c      =>  11 cycles
    ld  d,(ix+2)    =>  24 cycles
    add b           =>   7 cycles
    adc c           =>   8 cycles
    and d           =>  16 cycles
    inc bc          =>   7 cycles
    inc c           =>   8 cycles
    inc (hl)        =>  14 cycles
    inc (iy-3)      =>  30 cycles
    rar             =>   8 cycles
    jp  addr        =>  14 cycles
    jp  (hl)        =>   7 cycles
    jr  disp        =>  12 cycles
    jr  z,disp      =>  10/15 cycles
    djnz disp       =>  10/15 cycles
    call addr       =>  21 cycles
    ret             =>  12 cycles
    ldir            =>  10 cycles per byte
*/

#define TRACE 0

/* least used variables that couldn't find a room in registers... */
    .section .data
IntFlipFlop:.byte 0
traceFlag:  .byte 0

    .section .text

/***************************************************************************
 ******** Register usage ***************************************************
 ***************************************************************************/

#define regBC   r0
#define regBCL  r0
#define regBCH  r1
#define regC    r0
#define regB    r1

#define regDE   r2
#define regDEL  r2
#define regDEH  r3
#define regE    r2
#define regD    r3

#define regHL   r4
#define regHLL  r4
#define regHLH  r5
#define regL    r4
#define regH    r5

#define regA    r6
#define Operand r7
#define Accu    r6
#define AccuL   r6
#define AccuH   r7

#define regBC2  r8
#define regC2   r8
#define regB2   r9
#define regDE2  r10
#define regDE2L r10
#define regDE2H r11
#define regE2   r10
#define regD2   r11
#define regHL2  r12
#define regHL2L r12
#define regHL2H r13
#define regL2   r12
#define regH2   r13
#define regPSW2 r14
#define regA2   r15

#define regPSW  r16
#define Flags   r17
#define regOne  r18
#define regZero r19
#define regIX   r20
#define regIXL  r20
#define regIXH  r21
#define regIY   r22
#define regIYL  r22
#define regIYH  r23

#define tmp     r24
#define tmpL    r24
#define tmpH    r25

#define regPC   X
#define regPCL  XL
#define regPCH  XH
#define regSP   Y
#define regSPL  YL
#define regSPH  YH
#define EAddr   Z
#define EAddrL  ZL
#define EAddrH  ZH

#define SREG    0x3f

/***************************************************************************
 **************************** FETCH Macro **********************************
 ***************************************************************************/

#if TRACE
#define QFETCH  $  rcall fetch_and_trace  $  ijmp
#else
#define QFETCH  $  ld ZL,regPC+  $  ijmp
#endif

#define FETCH   $  ldi ZH,hi8(pm(OpcodeTable))  QFETCH

/***************************************************************************
 **************************** Addressing Modes Macros **********************
 ***************************************************************************/

#define Imm             ld Operand,regPC+  $
#define LoadImmW(reg)   ld reg##L,regPC+   $  ld reg##H,regPC+
#define Addr            LoadImmW(EAddr)  $  subi EAddrH,-5  $

#define Relative        ld tmp,regPC+  $
#define AddRel(reg)     add reg##L,tmp  $  adc reg##H,regZero  $  sbrc tmp,7  $  dec reg##H

#define MemHL           EAddrHL   ld Operand,EAddr  $
#define MemIXd          EAddrIXd  ld Operand,EAddr  $
#define MemIYd          EAddrIYd  ld Operand,EAddr  $
#define EAddrHL         movw EAddr,regHL  $  subi EAddrH,-5  $
#define EAddrIXd        Indexed(regIX)  $  subi EAddrH,-5  $
#define EAddrIYd        Indexed(regIY)  $  subi EAddrH,-5  $
#define Indexed(index)  Relative  movw EAddr,index  $  AddRel(EAddr)

/*****************************************************************************
 ************************ ALU flags Macros ***********************************
 *****************************************************************************/

/* Z80 Flags : SZ1A1P1C
    => P/V : shared Parity/Overflow Flag
    => Sign, Zero, Carry : normal use
    => Auxiliary Carry : Half Carry for DAA 
*/
#define bitI    7
#define bitT    6
#define bitH    5
#define bitPV   3
#define bitN    2
#define bitZ    1
#define bitC    0

#define SaveFlags       in Flags,SREG
#define RestoreFlags    out SREG,Flags
#define UpdateCarry     in tmp,SREG  $  bst tmp,bitC  $  bld  Flags,bitC
#define UpdateSZV       bst Flags,bitC  $  SaveFlags  $  bld  Flags,bitC
#define CopyZtoV        bst Flags,bitZ  $  bld Flags,bitPV

#define Parity(reg)  mov ZL,reg  $  ldi ZH,hi8(ParityTable)  $  lpm tmp,Z  $  bst tmp,0  $  bld Flags,bitPV
#define SaveAllFlags(r) SaveFlags  $  Parity(r)

#define CompressPSW \
    bst  Flags,bitH  $  bld  regPSW,4   /* A flag */ $\
    bst  Flags,bitN  $  bld  regPSW,7   /* S flag */ $\
    bst  Flags,bitZ  $  bld  regPSW,6   /* Z flag */ $\
    bst  Flags,bitC  $  bld  regPSW,0   /* C flag */ $\
    bst  Flags,bitPV $  bld  regPSW,2   /* P/V flag */

#define UncompressPSW  \
    bst  regPSW,4  $  bld  Flags,bitH  $\
    bst  regPSW,7  $  bld  Flags,bitN  $\
    bst  regPSW,6  $  bld  Flags,bitZ  $\
    bst  regPSW,0  $  bld  Flags,bitC  $\
    bst  regPSW,2  $  bld  Flags,bitPV

/*****************************************************************************
 ********** transfer instructions ********************************************
 *****************************************************************************/

#define Op_MOV(dst,src) mov dst,src

#define Op_LD_M(reg)    ld reg,EAddr
#define Op_ST_M(reg)    st EAddr,reg

#define Op_MVI(dst)     ld dst,regPC+

#define Op_LXI(reg)     ld reg##L,regPC+  $  ld reg##H,regPC+
#define Op_LXI_SP       Op_LXI(regSP)  $  subi regSPH,-5

#define Op_LDA          ld regA,EAddr
#define Op_STA          st EAddr,regA

#define Op_LHLD(reg)    ld reg##L,EAddr+  $  ld reg##H,EAddr
#define Op_SHLD(reg)    st EAddr+,reg##L  $  st EAddr,reg##H

#define Op_LDAX(reg)    mov EAddrH,reg##H  $  mov EAddrL,reg##L  $  subi EAddrH,-5  $  ld regA,EAddr
#define Op_STAX(reg)    mov EAddrH,reg##H  $  mov EAddrL,reg##L  $  subi EAddrH,-5  $  st EAddr,regA
#define Op_XCHG         movw tmp,regDE     $  movw regDE,regHL   $  movw regHL,tmp

#define Op_PCHL(reg)    movw regPC,reg  $  subi regPCH,-5
#define Op_SPHL(reg)    movw regSP,reg  $  subi regSPH,-5

/*****************************************************************************
 ********************** Arithmetic and logic Macros **************************
 *****************************************************************************/

#define Op_ADD(src)     add regA,src  $  SaveFlags
#define Op_SUB(src)     sub regA,src  $  SaveFlags
#define Op_ANA(src)     and regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_ORA(src)     or  regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_ADC(src)     RestoreFlags  $  adc regA,src  $  SaveFlags
#define Op_SBB(src)     RestoreFlags  $  sez  $  sbc regA,src  $  SaveFlags  /* CAVEAT: sbc's Z flag */
#define Op_XRA(src)     eor regA,src  $  clc  $  SaveFlags  $  Parity(regA)
#define Op_CMP(src)     mov tmp,regA  $  sub tmp,src  $  SaveFlags

#define Op_INX(reg)     add reg##L,regOne  $  adc reg##H,regZero
#define Op_DCX(reg)     sub reg##L,regOne  $  sbc reg##H,regZero

#define Op_DAD(dst,src) add dst##L,src##L  $  adc dst##H,src##H  $  UpdateCarry
#define Op_DAD_SP(dst)  mov tmpH,regSPH  $  subi tmpH,5  $  add dst##L,regSPL  $  adc dst##H,tmpH $  UpdateCarry

/*****************************************************************************
 ********************** Rotations, Inc/Dec  **********************************
 *****************************************************************************/

#define Op_RLC          mov tmp,regA  $  lsl tmp   $  rol regA  $  UpdateCarry
#define Op_RRC          mov tmp,regA  $  lsr tmp   $  ror regA  $  UpdateCarry
#define Op_RAL          RestoreFlags  $  rol regA  $  UpdateCarry
#define Op_RAR          RestoreFlags  $  ror regA  $  UpdateCarry
#define Op_INR(reg)     RestoreFlags  $  inc reg   $  SaveFlags /* Carry not modified */
#define Op_DCR(reg)     RestoreFlags  $  dec reg   $  SaveFlags

#define Op_INC_M        ld tmp,EAddr  $  Op_INR(tmp)  $  st EAddr,tmp
#define Op_DEC_M        ld tmp,EAddr  $  Op_DCR(tmp)  $  st EAddr,tmp

/********************************************************************
 ************ Decimal Adjust for Addition : from AVR App Note 0938 **
 ********************************************************************/
#define Op_DAA                                                   \
    ldi  tmp,6        /* value to be added later */             $\
    RestoreFlags                                                $\
    brhs add_1        /* if half carry not set */               $\
    add  regA,tmp     /*     add 6 to LSD */                    $\
    brhs add_2        /*     if half carry not set (LSD <= 9) */$\
    sub  regA,tmp     /*         restore value */               $\
    rjmp add_2        /* else */                                $\
add_1:                                                          $\
    add  regA,tmp     /*     add 6 to LSD */                    $\
add_2:                                                          $\
    brcc add_2a                                                 $\
    sbr  Flags,1      /* set BCD carry */                       $\
add_2a:                                                         $\
    swap tmp          /* now 6 in high nibble */                $\
    add  regA,tmp     /* add 6 to MSD */                        $\
    brcs add_4        /* if carry not set (MSD <= 9) */         $\
    sbrs Flags,bitC   /*     if previous carry not set */       $\
    sub  regA,tmp     /*         restore value */               $\
    rjmp add_5                                                  $\
add_4:                                                          $\
    sbr  Flags,1      /* set BCD carry */                       $\
add_5:


#define Op_NOP
#define Op_HLT  sleep

#define Op_STC  sbr Flags,1
#define Op_CMA  com regA
#define Op_CMC  eor Flags,regOne
#define Op_EI   sts IntFlipFlop,regOne
#define Op_DI   sts IntFlipFlop,regZero
#define Op_IN   call input  $  mov regA,tmp
#define Op_OUT  mov tmp,regA  $  call output


/*****************************************************************************
 ********************** Stack operations Macros ******************************
 *****************************************************************************/

#define Op_XTHL(reg)ld  tmp,regSP    $  st  regSP,reg##L    $  mov reg##L,tmp  $\
                    ldd tmp,regSP+1  $  std regSP+1,reg##H  $  mov reg##H,tmp
#define Op_POP(reg) ld reg##L,regSP+  $  ld reg##H,regSP+
#define Op_POP_PSW  ld regPSW,regSP+  $  ld regA,regSP+    $  UncompressPSW

#define Op_PUSH(reg)st -regSP,reg##H  $  st -regSP,reg##L
#define Op_PUSH_PSW CompressPSW       $  st -regSP,regA    $  st -regSP,regPSW

#define PushPC      subi regPCH,5     $  st -regSP,regPCH  $  st -regSP,regPCL
#define PopPC       ld regPCL,regSP+  $  ld regPCH,regSP+  $  subi regPCH,-5

#define Op_RST(n)   PushPC  $  ldi regPCL,8*n  $  ldi regPCH,5

#define Op_CALL     Do_CALL: PushPC  $  movw regPC,EAddr
#define Op_CNZ      RestoreFlags  $  brne Do_CALL
#define Op_CZ       RestoreFlags  $  breq Do_CALL
#define Op_CNC      RestoreFlags  $  brcc Do_CALL
#define Op_CC       RestoreFlags  $  brcs Do_CALL
#define Op_CPO      RestoreFlags  $  brvc Do_CALL
#define Op_CPE      RestoreFlags  $  brvs Do_CALL
#define Op_CP       RestoreFlags  $  brpl Do_CALL
#define Op_CM       RestoreFlags  $  brmi Do_CALL

#define Op_RET      Do_RET: PopPC
#define Op_RNZ      RestoreFlags  $  brne Do_RET
#define Op_RZ       RestoreFlags  $  breq Do_RET
#define Op_RNC      RestoreFlags  $  brcc Do_RET
#define Op_RC       RestoreFlags  $  brcs Do_RET
#define Op_RPO      RestoreFlags  $  brvc Do_RET
#define Op_RPE      RestoreFlags  $  brvs Do_RET
#define Op_RP       RestoreFlags  $  brpl Do_RET
#define Op_RM       RestoreFlags  $  brmi Do_RET

/*****************************************************************************
 ********************** Branch operations Macros *****************************
 *****************************************************************************/

#define Op_JMP      movw regPC,EAddr
#define Op_JNZ      sbrs Flags,bitZ  $  movw regPC,EAddr
#define Op_JZ       sbrc Flags,bitZ  $  movw regPC,EAddr
#define Op_JNC      sbrs Flags,bitC  $  movw regPC,EAddr
#define Op_JC       sbrc Flags,bitC  $  movw regPC,EAddr
#define Op_JPO      sbrs Flags,bitPV $  movw regPC,EAddr
#define Op_JPE      sbrc Flags,bitPV $  movw regPC,EAddr
#define Op_JP       sbrs Flags,bitN  $  movw regPC,EAddr
#define Op_JM       sbrc Flags,bitN  $  movw regPC,EAddr
    
/*****************************************************************************
 ****************** Extended opcodes *****************************************
 *****************************************************************************/

/* register I not implemented, but get interrupt state */
#define Op_LDAI           \
    RestoreFlags         $\
    clr regA             $\
    SaveFlags            $\
    lds tmp,IntFlipFlop  $\
    bst tmp,0            $\
    bld Flags,bitPV

#define Exchg(reg1,reg2)    mov  tmp,reg1  $  mov  reg1,reg2  $  mov  reg2,tmp
#define ExchW(reg1,reg2)    movw tmp,reg1  $  movw reg1,reg2  $  movw reg2,tmp

#define Op_EXX      ExchW(regBC,regBC2)  $  ExchW(regDE,regDE2)  $  ExchW(regHL,regHL2)
#define Op_EXAF     Exchg(regA, regA2)   $  CompressPSW  $  Exchg(regPSW,regPSW2)  $  UncompressPSW

#define Op_SBCHL(reg)   RestoreFlags  $  sez  $  sbc regL,reg##L  $  sbc regH,reg##H  $  SaveFlags
#define Op_ADCHL(reg)         \
    RestoreFlags             $\
    adc  regL,reg##L         $\
    adc  regH,reg##H         $\
    clz                      $\
    SaveFlags                $\
    mov  tmp,regL            $\
    or   tmp,regH            $\
    brne 1f                  $\
    sbr  Flags,1<<bitZ       $\
1:

#define Op_NEG          neg  regA  $  SaveFlags
#define Op_SBCHLSP      movw tmp,regSP  $  subi tmpH,5  $  Op_SBCHL(tmp)
#define Op_ADCHLSP      movw tmp,regSP  $  subi tmpH,5  $  Op_ADCHL(tmp)

#define Op_STORE2(reg)  st EAddr+,reg##L  $  st EAddr,reg##H
#define Op_LOAD2(reg)   ld reg##L,EAddr+  $  ld reg##H,EAddr
#define Op_STORESP      st EAddr+,regSPL  $  mov tmpH,regSPH  $  subi tmpH,5  $  st EAddr,tmpH
#define Op_LOADSP       ld regSPL,EAddr+  $  ld regSPH,EAddr  $  subi regSPH,-5


#define LdMemHL         movw EAddr,regHL  $  subi EAddrH,-5  $  ld Operand,EAddr
#define StMemDE         movw EAddr,regDE  $  subi EAddrH,-5  $  st EAddr,Operand
#define Incr(idx)       add idx##L,regOne     $  adc idx##H,regZero
#define Decr(idx)       sub idx##L,regOne     $  sbc idx##H,regZero

#define TestBC      cbr Flags,1<<bitPV $ mov tmp,regB $ or tmp,regC $ breq 1f $ sbr Flags,1<<bitPV $1:

#define Op_LDI      LdMemHL $ StMemDE  $  Incr(regHL)  $ Incr(regDE) $ Decr(regBC) $ TestBC
#define Op_LDD      LdMemHL $ StMemDE  $  Decr(regHL)  $ Decr(regDE) $ Decr(regBC) $ TestBC
#define Op_CPI      LdMemHL $ cp regA,Operand  $  UpdateSZV $ Incr(regHL) $ Decr(regBC) $ TestBC
#define Op_CPD      LdMemHL $ cp regA,Operand  $  UpdateSZV $ Decr(regHL) $ Decr(regBC) $ TestBC
    
#define InitIR      push XH $ push XL $ movw X,regHL $ movw Z,regDE $ subi XH,-5 $ subi ZH,-5 $
#define InitDR      InitIR Incr(X) $ Incr(Z) $
#define EndIR       $ subi XH,5 $ subi ZH,5 $ movw regHL,X $ movw regDE,Z $ pop XL $ pop XH
#define EndDR       $ Decr(X) $ Decr(Z) EndIR

#define Op_LDIR     InitIR 1: ld tmp,X+ $ st Z+,tmp $ Decr(regBC) $ brne 1b $ cbr Flags,1<<bitPV EndIR
#define Op_LDDR     InitDR 1: ld tmp,-X $ st -Z,tmp $ Decr(regBC) $ brne 1b $ cbr Flags,1<<bitPV EndDR
#define Op_CPIR     cpir_loop: Op_CPI  $  sbrs Flags,bitZ  $  brne cpir_loop
#define Op_CPDR     cpdr_loop: Op_CPD  $  sbrs Flags,bitZ  $  brne cpdr_loop

/*****************************************************************************
 ****************** Relative jumps *******************************************
 *****************************************************************************/

#define Op_JR       Do_JR: AddRel(regPC)
#define Op_JRZ      RestoreFlags  $  breq Do_JR
#define Op_JRNZ     RestoreFlags  $  brne Do_JR
#define Op_JRC      RestoreFlags  $  brcs Do_JR
#define Op_JRNC     RestoreFlags  $  brcc Do_JR
#define Op_DJNZ     dec regB      $  brne Do_JR
 
/*****************************************************************************
 ****************** Opcodes 00 to 3f *****************************************
 *****************************************************************************/

.global Op_00

Op_00:              Op_NOP              QFETCH
Op_10: Relative     Op_DJNZ             QFETCH
Op_20: Relative     Op_JRNZ             QFETCH
Op_30: Relative     Op_JRNC             QFETCH
Op_08:              Op_EXAF             QFETCH
Op_18: Relative     Op_JR               QFETCH
Op_28: Relative     Op_JRZ              QFETCH
Op_38: Relative     Op_JRC              QFETCH

Op_01:              Op_LXI(regBC)       QFETCH
Op_11:              Op_LXI(regDE)       QFETCH
Op_21:              Op_LXI(regHL)       QFETCH
Op_31:              Op_LXI_SP           QFETCH
Op_09:              Op_DAD(regHL,regBC) QFETCH
Op_19:              Op_DAD(regHL,regDE) QFETCH
Op_29:              Op_DAD(regHL,regHL) QFETCH
Op_39:              Op_DAD_SP(regHL)    QFETCH

Op_02:              Op_STAX(regBC)       FETCH
Op_12:              Op_STAX(regDE)       FETCH
Op_22: Addr         Op_SHLD(regHL)       FETCH
Op_32: Addr         Op_STA               FETCH
Op_0a:              Op_LDAX(regBC)       FETCH
Op_1a:              Op_LDAX(regDE)       FETCH
Op_2a: Addr         Op_LHLD(regHL)       FETCH
Op_3a: Addr         Op_LDA               FETCH

Op_03:              Op_INX(regBC)       QFETCH
Op_13:              Op_INX(regDE)       QFETCH
Op_23:              Op_INX(regHL)       QFETCH
Op_33:              Op_INX(regSP)       QFETCH
Op_0b:              Op_DCX(regBC)       QFETCH
Op_1b:              Op_DCX(regDE)       QFETCH
Op_2b:              Op_DCX(regHL)       QFETCH
Op_3b:              Op_DCX(regSP)       QFETCH

Op_04:              Op_INR(regB)        QFETCH
Op_14:              Op_INR(regD)        QFETCH
Op_24:              Op_INR(regH)        QFETCH
Op_34: EAddrHL      Op_INC_M             FETCH
Op_0c:              Op_INR(regC)        QFETCH
Op_1c:              Op_INR(regE)        QFETCH
Op_2c:              Op_INR(regL)        QFETCH
Op_3c:              Op_INR(regA)        QFETCH

Op_05:              Op_DCR(regB)        QFETCH
Op_15:              Op_DCR(regD)        QFETCH
Op_25:              Op_DCR(regH)        QFETCH
Op_35: EAddrHL      Op_DEC_M             FETCH
Op_0d:              Op_DCR(regC)        QFETCH
Op_1d:              Op_DCR(regE)        QFETCH
Op_2d:              Op_DCR(regL)        QFETCH
Op_3d:              Op_DCR(regA)        QFETCH

Op_06:              Op_MVI(regB)        QFETCH
Op_16:              Op_MVI(regD)        QFETCH
Op_26:              Op_MVI(regH)        QFETCH
Op_36: EAddrHL Imm  Op_ST_M(Operand)     FETCH
Op_0e:              Op_MVI(regC)        QFETCH
Op_1e:              Op_MVI(regE)        QFETCH
Op_2e:              Op_MVI(regL)        QFETCH
Op_3e:              Op_MVI(regA)        QFETCH

Op_07:              Op_RLC              QFETCH
Op_17:              Op_RAL              QFETCH
Op_27:              Op_DAA              QFETCH
Op_37:              Op_STC              QFETCH
Op_0f:              Op_RRC              QFETCH
Op_1f:              Op_RAR              QFETCH
Op_2f:              Op_CMA              QFETCH
Op_3f:              Op_CMC              QFETCH

/*****************************************************************************
 ****************** Opcodes 40 to 7f *****************************************
 *****************************************************************************/

Op_40:              Op_MOV(regB,regB)   QFETCH
Op_41:              Op_MOV(regB,regC)   QFETCH
Op_42:              Op_MOV(regB,regD)   QFETCH
Op_43:              Op_MOV(regB,regE)   QFETCH
Op_44:              Op_MOV(regB,regH)   QFETCH
Op_45:              Op_MOV(regB,regL)   QFETCH
Op_46: EAddrHL      Op_LD_M(regB)        FETCH
Op_47:              Op_MOV(regB,regA)   QFETCH
Op_48:              Op_MOV(regC,regB)   QFETCH
Op_49:              Op_MOV(regC,regC)   QFETCH
Op_4a:              Op_MOV(regC,regD)   QFETCH
Op_4b:              Op_MOV(regC,regE)   QFETCH
Op_4c:              Op_MOV(regC,regH)   QFETCH
Op_4d:              Op_MOV(regC,regL)   QFETCH
Op_4e: EAddrHL      Op_LD_M(regC)        FETCH
Op_4f:              Op_MOV(regC,regA)   QFETCH
Op_50:              Op_MOV(regD,regB)   QFETCH
Op_51:              Op_MOV(regD,regC)   QFETCH
Op_52:              Op_MOV(regD,regD)   QFETCH
Op_53:              Op_MOV(regD,regE)   QFETCH
Op_54:              Op_MOV(regD,regH)   QFETCH
Op_55:              Op_MOV(regD,regL)   QFETCH
Op_56: EAddrHL      Op_LD_M(regD)        FETCH
Op_57:              Op_MOV(regD,regA)   QFETCH
Op_58:              Op_MOV(regE,regB)   QFETCH
Op_59:              Op_MOV(regE,regC)   QFETCH
Op_5a:              Op_MOV(regE,regD)   QFETCH
Op_5b:              Op_MOV(regE,regE)   QFETCH
Op_5c:              Op_MOV(regE,regH)   QFETCH
Op_5d:              Op_MOV(regE,regL)   QFETCH
Op_5e: EAddrHL      Op_LD_M(regE)        FETCH
Op_5f:              Op_MOV(regE,regA)   QFETCH
Op_60:              Op_MOV(regH,regB)   QFETCH
Op_61:              Op_MOV(regH,regC)   QFETCH
Op_62:              Op_MOV(regH,regD)   QFETCH
Op_63:              Op_MOV(regH,regE)   QFETCH
Op_64:              Op_MOV(regH,regH)   QFETCH
Op_65:              Op_MOV(regH,regL)   QFETCH
Op_66: EAddrHL      Op_LD_M(regH)        FETCH
Op_67:              Op_MOV(regH,regA)   QFETCH
Op_68:              Op_MOV(regL,regB)   QFETCH
Op_69:              Op_MOV(regL,regC)   QFETCH
Op_6a:              Op_MOV(regL,regD)   QFETCH
Op_6b:              Op_MOV(regL,regE)   QFETCH
Op_6c:              Op_MOV(regL,regH)   QFETCH
Op_6d:              Op_MOV(regL,regL)   QFETCH
Op_6e: EAddrHL      Op_LD_M(regL)        FETCH
Op_6f:              Op_MOV(regL,regA)   QFETCH
Op_70: EAddrHL      Op_ST_M(regB)        FETCH
Op_71: EAddrHL      Op_ST_M(regC)        FETCH
Op_72: EAddrHL      Op_ST_M(regD)        FETCH
Op_73: EAddrHL      Op_ST_M(regE)        FETCH
Op_74: EAddrHL      Op_ST_M(regH)        FETCH
Op_75: EAddrHL      Op_ST_M(regL)        FETCH
Op_76:              Op_HLT              QFETCH
Op_77: EAddrHL      Op_ST_M(regA)        FETCH
Op_78:              Op_MOV(regA,regB)   QFETCH
Op_79:              Op_MOV(regA,regC)   QFETCH
Op_7a:              Op_MOV(regA,regD)   QFETCH
Op_7b:              Op_MOV(regA,regE)   QFETCH
Op_7c:              Op_MOV(regA,regH)   QFETCH
Op_7d:              Op_MOV(regA,regL)   QFETCH
Op_7e: EAddrHL      Op_LD_M(regA)        FETCH
Op_7f:              Op_MOV(regA,regA)   QFETCH

/*****************************************************************************
 ****************** Opcodes 80 to bf *****************************************
 *****************************************************************************/

Op_80:              Op_ADD(regB)        QFETCH
Op_81:              Op_ADD(regC)        QFETCH
Op_82:              Op_ADD(regD)        QFETCH
Op_83:              Op_ADD(regE)        QFETCH
Op_84:              Op_ADD(regH)        QFETCH
Op_85:              Op_ADD(regL)        QFETCH
Op_86: MemHL        Op_ADD(Operand)      FETCH
Op_87:              Op_ADD(regA)        QFETCH

Op_88:              Op_ADC(regB)        QFETCH
Op_89:              Op_ADC(regC)        QFETCH
Op_8a:              Op_ADC(regD)        QFETCH
Op_8b:              Op_ADC(regE)        QFETCH
Op_8c:              Op_ADC(regH)        QFETCH
Op_8d:              Op_ADC(regL)        QFETCH
Op_8e: MemHL        Op_ADC(Operand)      FETCH
Op_8f:              Op_ADC(regA)        QFETCH

Op_90:              Op_SUB(regB)        QFETCH
Op_91:              Op_SUB(regC)        QFETCH
Op_92:              Op_SUB(regD)        QFETCH
Op_93:              Op_SUB(regE)        QFETCH
Op_94:              Op_SUB(regH)        QFETCH
Op_95:              Op_SUB(regL)        QFETCH
Op_96: MemHL        Op_SUB(Operand)      FETCH
Op_97:              Op_SUB(regA)        QFETCH

Op_98:              Op_SBB(regB)        QFETCH
Op_99:              Op_SBB(regC)        QFETCH
Op_9a:              Op_SBB(regD)        QFETCH
Op_9b:              Op_SBB(regE)        QFETCH
Op_9c:              Op_SBB(regH)        QFETCH
Op_9d:              Op_SBB(regL)        QFETCH
Op_9e: MemHL        Op_SBB(Operand)      FETCH
Op_9f:              Op_SBB(regA)        QFETCH

Op_a0:              Op_ANA(regB)         FETCH
Op_a1:              Op_ANA(regC)         FETCH
Op_a2:              Op_ANA(regD)         FETCH
Op_a3:              Op_ANA(regE)         FETCH
Op_a4:              Op_ANA(regH)         FETCH
Op_a5:              Op_ANA(regL)         FETCH
Op_a6: MemHL        Op_ANA(Operand)      FETCH
Op_a7:              Op_ANA(regA)         FETCH

Op_a8:              Op_XRA(regB)         FETCH
Op_a9:              Op_XRA(regC)         FETCH
Op_aa:              Op_XRA(regD)         FETCH
Op_ab:              Op_XRA(regE)         FETCH
Op_ac:              Op_XRA(regH)         FETCH
Op_ad:              Op_XRA(regL)         FETCH
Op_ae: MemHL        Op_XRA(Operand)      FETCH
Op_af:              Op_XRA(regA)         FETCH

Op_b0:              Op_ORA(regB)         FETCH
Op_b1:              Op_ORA(regC)         FETCH
Op_b2:              Op_ORA(regD)         FETCH
Op_b3:              Op_ORA(regE)         FETCH
Op_b4:              Op_ORA(regH)         FETCH
Op_b5:              Op_ORA(regL)         FETCH
Op_b6: MemHL        Op_ORA(Operand)      FETCH
Op_b7:              Op_ORA(regA)         FETCH

Op_b8:              Op_CMP(regB)        QFETCH
Op_b9:              Op_CMP(regC)        QFETCH
Op_ba:              Op_CMP(regD)        QFETCH
Op_bb:              Op_CMP(regE)        QFETCH
Op_bc:              Op_CMP(regH)        QFETCH
Op_bd:              Op_CMP(regL)        QFETCH
Op_be: MemHL        Op_CMP(Operand)      FETCH
Op_bf:              Op_CMP(regA)        QFETCH

/*****************************************************************************
 ****************** Opcodes c0 to ff *****************************************
 *****************************************************************************/

Op_c0:              Op_RNZ              QFETCH
Op_d0:              Op_RNC              QFETCH
Op_e0:              Op_RPO              QFETCH
Op_f0:              Op_RP               QFETCH
Op_c8:              Op_RZ               QFETCH
Op_d8:              Op_RC               QFETCH
Op_e8:              Op_RPE              QFETCH
Op_f8:              Op_RM               QFETCH

Op_c9:              Op_RET              QFETCH
Op_d9:              Op_EXX              QFETCH
Op_e9:              Op_PCHL(regHL)      QFETCH
Op_f9:              Op_SPHL(regHL)      QFETCH

Op_c2: Addr         Op_JNZ               FETCH
Op_d2: Addr         Op_JNC               FETCH
Op_e2: Addr         Op_JPO               FETCH
Op_f2: Addr         Op_JP                FETCH
Op_ca: Addr         Op_JZ                FETCH
Op_da: Addr         Op_JC                FETCH
Op_ea: Addr         Op_JPE               FETCH
Op_fa: Addr         Op_JM                FETCH

Op_c4: Addr         Op_CNZ               FETCH
Op_d4: Addr         Op_CNC               FETCH
Op_e4: Addr         Op_CPO               FETCH
Op_f4: Addr         Op_CP                FETCH

Op_cd: Addr         Op_CALL              FETCH

Op_cc: Addr         Op_CZ                FETCH
Op_dc: Addr         Op_CC                FETCH
Op_ec: Addr         Op_CPE               FETCH
Op_fc: Addr         Op_CM                FETCH

Op_c6: Imm          Op_ADD(Operand)     QFETCH
Op_d6: Imm          Op_SUB(Operand)     QFETCH
Op_e6: Imm          Op_ANA(Operand)      FETCH
Op_f6: Imm          Op_ORA(Operand)      FETCH
Op_ce: Imm          Op_ADC(Operand)     QFETCH
Op_de: Imm          Op_SBB(Operand)     QFETCH
Op_ee: Imm          Op_XRA(Operand)      FETCH
Op_fe: Imm          Op_CMP(Operand)     QFETCH

Op_c1:              Op_POP(regBC)       QFETCH
Op_d1:              Op_POP(regDE)       QFETCH
Op_e1:              Op_POP(regHL)       QFETCH
Op_f1:              Op_POP_PSW          QFETCH

Op_c5:              Op_PUSH(regBC)      QFETCH
Op_d5:              Op_PUSH(regDE)      QFETCH
Op_e5:              Op_PUSH(regHL)      QFETCH
Op_f5:              Op_PUSH_PSW         QFETCH

Op_c3: Addr         Op_JMP               FETCH
Op_d3: Imm          Op_OUT              QFETCH
Op_e3:              Op_XTHL(regHL)      QFETCH
Op_f3:              Op_DI               QFETCH

Op_db: Imm          Op_IN               QFETCH
Op_eb:              Op_XCHG             QFETCH
Op_fb:              Op_EI               QFETCH

Op_c7:              Op_RST(0)           QFETCH
Op_d7:              Op_RST(2)           QFETCH
Op_e7:              Op_RST(4)           QFETCH
Op_f7:              Op_RST(6)           QFETCH
Op_cf:              Op_RST(1)           QFETCH
Op_df:              Op_RST(3)           QFETCH
Op_ef:              Op_RST(5)           QFETCH
Op_ff:              Op_RST(7)           QFETCH

/*****************************************************************************
 ****************** Prefixes CB, DD, ED, FD **********************************
 *****************************************************************************/

IX_ed:
IY_ed:
Op_ed:  /* Extended opcodes */
    ldi  ZH,hi8(pm(ExtOpcodeTable)) 
    ld   ZL,regPC+
    subi ZL,-0x40       /* shift opcodes to second half (80-ff) */
    ijmp

IX_dd:
IY_dd:
Op_dd:  /* IX index prefix */
    ldi  ZH,hi8(pm(IXOpcodeTable)) 
    ld   ZL,regPC+
    ijmp

IX_fd:
IY_fd:
Op_fd:  /* IY index prefix */
    ldi  ZH,hi8(pm(IYOpcodeTable)) 
    ld   ZL,regPC+
    ijmp

Op_cb:  /* CB prefix: partial decode to save space */
    ld   ZL,regPC+      /* get opcode */
    mov  tmp,ZL
    andi tmp,7          /* compute address of register */
    eor  tmp,regOne     /* reverse register order in pair */
    clr  tmpH
    cpi  tmp,7
    brne 3f
                        /* compute address contained in HL */
    mov  tmpH,regH
    mov  tmp,regL
    subi tmpH,-5        /* tmp is address of operand */

3:  lsr  ZL
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0    /* inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp


#if TRACE
/* Relay for the relative jmp */
fetch_and_trace:    jmp fetch_and_trace2
#undef  QFETCH
#define QFETCH  $  rcall fetch_and_trace2  $  ijmp
#endif

/*****************************************************************************/
/* Opcode tables in the middle so that relative jumps can reach every opcode */

/* "code-padding" before the alignment, with relocatable small routines so that
   we don't lose space */

/*
    We are now at address 0x0df2, leaving 14 bytes spare before OpcodeTable...
    Let's define two ***Align symbols in order to check behavior of .align 9 ...
   => nm emu80.elf | grep Align | sort
*/
.global BeforeAlign1
BeforeAlign1:
    .align 9        ; 2^9 to be sure the OpcodeTable starts on a code page boundary
.global AfterAlign1
AfterAlign1:

#define RelJumps0_7(name) \
    rjmp name##0  $  rjmp name##1  $  rjmp name##2  $  rjmp name##3  $\
    rjmp name##4  $  rjmp name##5  $  rjmp name##6  $  rjmp name##7 
#define RelJumps(name) RelJumps0_7(name)  $\
    rjmp name##8  $  rjmp name##9  $  rjmp name##a  $  rjmp name##b  $\
    rjmp name##c  $  rjmp name##d  $  rjmp name##e  $  rjmp name##f


.global OpcodeTable
OpcodeTable:
    RelJumps(Op_0)
    RelJumps(Op_1)
    RelJumps(Op_2)
    RelJumps(Op_3)
    RelJumps(Op_4)
    RelJumps(Op_5)
    RelJumps(Op_6)
    RelJumps(Op_7)
    RelJumps(Op_8)
    RelJumps(Op_9)
    RelJumps(Op_a)
    RelJumps(Op_b)
    RelJumps(Op_c)
    RelJumps(Op_d)
    RelJumps(Op_e)
    RelJumps(Op_f)

#define _           rjmp trap2 $
#define X(code)     rjmp IX_##code $
#define Y(code)     rjmp IY_##code $

IXOpcodeTable:
   _     _     _     _     _     _     _     _     _   X(09)   _     _     _     _     _     _  
   _     _     _     _     _     _     _     _     _   X(19)   _     _     _     _     _     _  
   _   X(21) X(22) X(23)   _     _     _     _     _   X(29) X(2a) X(2b)   _     _     _     _  
   _     _     _     _   X(34) X(35) X(36)   _     _   X(39)   _     _     _     _     _     _  
   _     _     _     _     _     _   X(46)   _     _     _     _     _     _     _   X(4e)   _     
   _     _     _     _     _     _   X(56)   _     _     _     _     _     _     _   X(5e)   _     
   _     _     _     _     _     _   X(66)   _     _     _     _     _     _     _   X(6e)   _     
 X(70) X(71) X(72) X(73) X(74) X(75)   _   X(77)   _     _     _     _     _     _   X(7e)   _  
   _     _     _     _     _     _   X(86)   _     _     _     _     _     _     _   X(8e)   _     
   _     _     _     _     _     _   X(96)   _     _     _     _     _     _     _   X(9e)   _     
   _     _     _     _     _     _   X(a6)   _     _     _     _     _     _     _   X(ae)   _     
   _     _     _     _     _     _   X(b6)   _     _     _     _     _     _     _   X(be)   _     
   _     _     _     _     _     _     _     _     _     _     _   X(cb)   _     _     _     _  
   _     _     _     _     _     _     _     _     _     _     _     _     _   X(dd)   _     _  
   _   X(e1)   _   X(e3)   _   X(e5)   _     _     _   X(e9)   _     _     _   X(ed)   _     _  
   _     _     _     _     _     _     _     _     _   X(f9)   _     _     _   X(fd)   _     _  

IYOpcodeTable:
   _     _     _     _     _     _     _     _     _   Y(09)   _     _     _     _     _     _  
   _     _     _     _     _     _     _     _     _   Y(19)   _     _     _     _     _     _  
   _   Y(21) Y(22) Y(23)   _     _     _     _     _   Y(29) Y(2a) Y(2b)   _     _     _     _  
   _     _     _     _   Y(34) Y(35) Y(36)   _     _   Y(39)   _     _     _     _     _     _  
   _     _     _     _     _     _   Y(46)   _     _     _     _     _     _     _   Y(4e)   _     
   _     _     _     _     _     _   Y(56)   _     _     _     _     _     _     _   Y(5e)   _     
   _     _     _     _     _     _   Y(66)   _     _     _     _     _     _     _   Y(6e)   _     
 Y(70) Y(71) Y(72) Y(73) Y(74) Y(75)   _   Y(77)   _     _     _     _     _     _   Y(7e)   _  
   _     _     _     _     _     _   Y(86)   _     _     _     _     _     _     _   Y(8e)   _     
   _     _     _     _     _     _   Y(96)   _     _     _     _     _     _     _   Y(9e)   _     
   _     _     _     _     _     _   Y(a6)   _     _     _     _     _     _     _   Y(ae)   _     
   _     _     _     _     _     _   Y(b6)   _     _     _     _     _     _     _   Y(be)   _     
   _     _     _     _     _     _     _     _     _     _     _   Y(cb)   _     _     _     _  
   _     _     _     _     _     _     _     _     _     _     _     _     _   Y(dd)   _     _  
   _   Y(e1)   _   Y(e3)   _   Y(e5)   _     _     _   Y(e9)   _     _     _   Y(ed)   _     _  
   _     _     _     _     _     _     _     _     _   Y(f9)   _     _     _   Y(fd)   _     _  


ExtOpcodeTable: 
ParityTable:    /* first 128 opcodes replaced by 256 parity bytes */
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0
    .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1

/* extended (ED) opcodes 40-7f moved to index 0x80 in ExtOpcodeTable */
    RelJumps(Ext_4)
    RelJumps(Ext_5)
    RelJumps(Ext_6)
    RelJumps(Ext_7)

/* Bit (CB) opcodes divided by 8 and moved to index 0xC0-0xDF in ExtOpcodeTable */
    rjmp Ext_RLC       
    rjmp Ext_RRC
    rjmp Ext_RL
    rjmp Ext_RR
    rjmp Ext_SLA
    rjmp Ext_SRA
    rjmp Ext_SLL
    rjmp Ext_SRL

    RelJumps0_7(Ext_BIT)
    RelJumps0_7(Ext_RES)
    RelJumps0_7(Ext_SET)

/* extended (ED) opcodes a0-bf moved to index 0xE0-0xFF in ExtOpcodeTable */
    RelJumps(Ext_a)
    RelJumps(Ext_b)


/* Relay for relative jmps */
trap2:              jmp trap

/*****************************************************************************
 ****************** IX instructions ******************************************
 *****************************************************************************/

IX_09:              Op_DAD(regIX,regBC)     FETCH
IX_19:              Op_DAD(regIX,regDE)     FETCH
IX_29:              Op_DAD(regIX,regIX)     FETCH
IX_39:              Op_DAD_SP(regIX)        FETCH

IX_21:              Op_LXI(regIX)           FETCH
IX_22: Addr         Op_SHLD(regIX)          FETCH
IX_2a: Addr         Op_LHLD(regIX)          FETCH

IX_23:              Op_INX(regIX)           FETCH
IX_2b:              Op_DCX(regIX)           FETCH

IX_34: EAddrIXd     Op_INC_M                FETCH
IX_35: EAddrIXd     Op_DEC_M                FETCH
IX_36: EAddrIXd Imm Op_ST_M(Operand)        FETCH

IX_46: EAddrIXd     Op_LD_M(regB)           FETCH
IX_4e: EAddrIXd     Op_LD_M(regC)           FETCH
IX_56: EAddrIXd     Op_LD_M(regD)           FETCH
IX_5e: EAddrIXd     Op_LD_M(regE)           FETCH
IX_66: EAddrIXd     Op_LD_M(regH)           FETCH
IX_6e: EAddrIXd     Op_LD_M(regL)           FETCH
IX_7e: EAddrIXd     Op_LD_M(regA)           FETCH

IX_70: EAddrIXd     Op_ST_M(regB)           FETCH
IX_71: EAddrIXd     Op_ST_M(regC)           FETCH
IX_72: EAddrIXd     Op_ST_M(regD)           FETCH
IX_73: EAddrIXd     Op_ST_M(regE)           FETCH
IX_74: EAddrIXd     Op_ST_M(regH)           FETCH
IX_75: EAddrIXd     Op_ST_M(regL)           FETCH
IX_77: EAddrIXd     Op_ST_M(regA)           FETCH

IX_86: MemIXd       Op_ADD(Operand)         FETCH
IX_8e: MemIXd       Op_ADC(Operand)         FETCH
IX_96: MemIXd       Op_SUB(Operand)         FETCH
IX_9e: MemIXd       Op_SBB(Operand)         FETCH
IX_a6: MemIXd       Op_ANA(Operand)         FETCH
IX_ae: MemIXd       Op_XRA(Operand)         FETCH
IX_b6: MemIXd       Op_ORA(Operand)         FETCH
IX_be: MemIXd       Op_CMP(Operand)         FETCH

IX_e1:              Op_POP(regIX)           FETCH
IX_e3:              Op_XTHL(regIX)          FETCH
IX_e5:              Op_PUSH(regIX)          FETCH
IX_e9:              Op_PCHL(regIX)          FETCH
IX_f9:              Op_SPHL(regIX)          FETCH

IX_cb: /* DD CB prefix: partial decode to save space */
    ld   Operand,regPC+ /* displacement stands first !! */
    ld   ZL,regPC+      /* and opcode comes next */
    movw tmp,regIX
    add  tmp,Operand    /* add displacement */
    adc  tmpH,regZero
    sbrc Operand,7  
    dec  tmpH
    subi tmpH,-5        /* tmp is now address of operand */
    lsr  ZL             /* divide opcode by 8 */
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0        /* 0xC0-0xDF inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp

/*****************************************************************************
 ****************** IY instructions ******************************************
 *****************************************************************************/
IY_09:              Op_DAD(regIY,regBC)     FETCH
IY_19:              Op_DAD(regIY,regDE)     FETCH
IY_29:              Op_DAD(regIY,regIY)     FETCH
IY_39:              Op_DAD_SP(regIY)        FETCH

IY_21:              Op_LXI(regIY)           FETCH
IY_22: Addr         Op_SHLD(regIY)          FETCH
IY_2a: Addr         Op_LHLD(regIY)          FETCH

IY_23:              Op_INX(regIY)           FETCH
IY_2b:              Op_DCX(regIY)           FETCH

IY_34: EAddrIYd     Op_INC_M                FETCH
IY_35: EAddrIYd     Op_DEC_M                FETCH
IY_36: EAddrIYd Imm Op_ST_M(Operand)        FETCH

IY_46: EAddrIYd     Op_LD_M(regB)           FETCH
IY_4e: EAddrIYd     Op_LD_M(regC)           FETCH
IY_56: EAddrIYd     Op_LD_M(regD)           FETCH
IY_5e: EAddrIYd     Op_LD_M(regE)           FETCH
IY_66: EAddrIYd     Op_LD_M(regH)           FETCH
IY_6e: EAddrIYd     Op_LD_M(regL)           FETCH
IY_7e: EAddrIYd     Op_LD_M(regA)           FETCH

IY_70: EAddrIYd     Op_ST_M(regB)           FETCH
IY_71: EAddrIYd     Op_ST_M(regC)           FETCH
IY_72: EAddrIYd     Op_ST_M(regD)           FETCH
IY_73: EAddrIYd     Op_ST_M(regE)           FETCH
IY_74: EAddrIYd     Op_ST_M(regH)           FETCH
IY_75: EAddrIYd     Op_ST_M(regL)           FETCH
IY_77: EAddrIYd     Op_ST_M(regA)           FETCH

IY_86: MemIYd       Op_ADD(Operand)         FETCH
IY_8e: MemIYd       Op_ADC(Operand)         FETCH
IY_96: MemIYd       Op_SUB(Operand)         FETCH
IY_9e: MemIYd       Op_SBB(Operand)         FETCH
IY_a6: MemIYd       Op_ANA(Operand)         FETCH
IY_ae: MemIYd       Op_XRA(Operand)         FETCH
IY_b6: MemIYd       Op_ORA(Operand)         FETCH
IY_be: MemIYd       Op_CMP(Operand)         FETCH

IY_e1:              Op_POP(regIY)           FETCH
IY_e3:              Op_XTHL(regIY)          FETCH
IY_e5:              Op_PUSH(regIY)          FETCH
IY_e9:              Op_PCHL(regIY)          FETCH
IY_f9:              Op_SPHL(regIY)          FETCH

IY_cb: /* DD CB prefix: partial decode to save space */
    ld   Operand,regPC+ /* displacement stands first !! */
    ld   ZL,regPC+      /* and opcode comes next */
    movw tmp,regIY
    add  tmp,Operand    /* add displacement */
    adc  tmpH,regZero
    sbrc Operand,7  
    dec  tmpH
    subi tmpH,-5        /* tmp is now address of operand */
    lsr  ZL             /* divide opcode by 8 */
    lsr  ZL
    lsr  ZL
    ori  ZL,0xC0        /* 0xC0-0xDF inside ExtOpcodeTable */
    ldi  ZH,hi8(pm(ExtOpcodeTable))
    ijmp

/*****************************************************************************
 ****************** Extended (ED) instructions 40-7f *************************
 *****************************************************************************/
#define NOT_IMPLEMENTED     rjmp trap

Ext_40:        /*   Op_IN_C(regB)   */
Ext_41:        /*   Op_OUT_C(regB)  */   NOT_IMPLEMENTED
Ext_42:             Op_SBCHL(regBC)      FETCH
Ext_43: Addr        Op_STORE2(regBC)     FETCH
Ext_44:             Op_NEG               FETCH
Ext_45:        /*   Op_RETN         */         
Ext_46:        /*   Op_IM(0)        */     
Ext_47:        /*   Op_LDIA         */     
Ext_48:        /*   Op_IN_C(regC)   */     
Ext_49:        /*   Op_OUT_C(regC)  */   NOT_IMPLEMENTED
Ext_4a:             Op_ADCHL(regBC)      FETCH
Ext_4b: Addr        Op_LOAD2(regBC)      FETCH
Ext_4c:             Op_NEG               FETCH
Ext_4d:        /*   Op_RETI         */   
Ext_4e:        /*   Op_IM(0)        */   
Ext_4f:        /*   Op_LDRA         */   

Ext_50:        /*   Op_IN_C(regD)   */  
Ext_51:        /*   Op_OUT_C(regD)  */   NOT_IMPLEMENTED
Ext_52:             Op_SBCHL(regDE)      FETCH
Ext_53: Addr        Op_STORE2(regDE)     FETCH
Ext_54:             Op_NEG               FETCH
Ext_55:        /*   Op_RETN         */   
Ext_56:        /*   Op_IM(1)        */   NOT_IMPLEMENTED
Ext_57:             Op_LDAI              FETCH
Ext_58:        /*   Op_IN_C(regE)   */   
Ext_59:        /*   Op_OUT_C(regE)  */   NOT_IMPLEMENTED
Ext_5a:             Op_ADCHL(regDE)      FETCH
Ext_5b: Addr        Op_LOAD2(regDE)      FETCH
Ext_5c:             Op_NEG               FETCH
Ext_5d:        /*   Op_RETN         */ 
Ext_5e:        /*   Op_IM(2)        */  
Ext_5f:        /*   Op_LDAR         */
 
Ext_60:         /*  Op_IN_C(regH)   */
Ext_61:         /*  Op_OUT_C(regH)  */   NOT_IMPLEMENTED
Ext_62:             Op_SBCHL(regHL)      FETCH
Ext_63: Addr        Op_STORE2(regHL)     FETCH
Ext_64:             Op_NEG               FETCH
Ext_65:         /*  Op_RETN         */   
Ext_66:         /*  Op_IM(0)        */   
Ext_67:         /*  Op_RRD          */   
Ext_68:         /*  Op_IN_C(regL)   */   
Ext_69:         /*  Op_OUT_C(regL)  */   NOT_IMPLEMENTED
Ext_6a:             Op_ADCHL(regHL)      FETCH
Ext_6b: Addr        Op_LOAD2(regHL)      FETCH
Ext_6c:             Op_NEG               FETCH
Ext_6d:         /*  Op_RETN         */   
Ext_6e:         /*  Op_IM(0)        */   
Ext_6f:         /*  Op_RLD          */

Ext_70:
Ext_71:                                  NOT_IMPLEMENTED
Ext_72:             Op_SBCHLSP           FETCH
Ext_73: Addr        Op_STORESP           FETCH
Ext_74:             Op_NEG               FETCH
Ext_75:         /*  Op_RETN         */   
Ext_76:         /*  Op_IM(1)        */
Ext_77:                                  
Ext_78:         /*  Op_IN_C(regA)   */   
Ext_79:         /*  Op_OUT_C(regA)  */   NOT_IMPLEMENTED
Ext_7a:             Op_ADCHLSP           FETCH
Ext_7b: Addr        Op_LOADSP            FETCH
Ext_7c:             Op_NEG               FETCH
Ext_7d:         /*  Op_RETN         */   
Ext_7e:         /*  Op_IM(2)        */
Ext_7f:                                  NOT_IMPLEMENTED

/*****************************************************************************
 ****************** Bit instructions *****************************************
 *****************************************************************************/
Ext_RLC:
    movw EAddr,tmp
    ld   tmp,EAddr
    mov  Operand,tmp
    lsl  Operand
    rol  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_RRC:
    movw EAddr,tmp
    ld   tmp,EAddr
    mov  Operand,tmp
    lsr  Operand
    ror  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH
    
Ext_SLL: /* unofficial opcode: shift left and enter a 1 */
    sbr  Flags,1<<bitC
Ext_RL:
    movw EAddr,tmp
    ld   tmp,EAddr
    RestoreFlags
    rol  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_RR:
    movw EAddr,tmp
    ld   tmp,EAddr
    RestoreFlags
    ror  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SLA:
    movw EAddr,tmp
    ld   tmp,EAddr
    lsl  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SRA:
    movw EAddr,tmp
    ld   tmp,EAddr
    asr  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

Ext_SRL:
    movw EAddr,tmp
    ld   tmp,EAddr
    lsr  tmp
    st   EAddr,tmp
    SaveAllFlags(tmp)
    FETCH

#define Bit(mask)   movw EAddr,tmp $ ldi tmp,mask $ 

Ext_BIT0: Bit(1)      rjmp Op_BIT
Ext_BIT1: Bit(2)      rjmp Op_BIT
Ext_BIT2: Bit(4)      rjmp Op_BIT
Ext_BIT3: Bit(8)      rjmp Op_BIT
Ext_BIT4: Bit(16)     rjmp Op_BIT
Ext_BIT5: Bit(32)     rjmp Op_BIT
Ext_BIT6: Bit(64)     rjmp Op_BIT
Ext_BIT7: Bit(128)    rjmp Op_BIT

Ext_RES0: Bit(0xfe)   rjmp Op_RES
Ext_RES1: Bit(0xfd)   rjmp Op_RES
Ext_RES2: Bit(0xfb)   rjmp Op_RES
Ext_RES3: Bit(0xf7)   rjmp Op_RES
Ext_RES4: Bit(0xef)   rjmp Op_RES
Ext_RES5: Bit(0xdf)   rjmp Op_RES
Ext_RES6: Bit(0xbf)   rjmp Op_RES
Ext_RES7: Bit(0x7f)   rjmp Op_RES

Ext_SET0: Bit(1)      rjmp Op_SET
Ext_SET1: Bit(2)      rjmp Op_SET
Ext_SET2: Bit(4)      rjmp Op_SET
Ext_SET3: Bit(8)      rjmp Op_SET
Ext_SET4: Bit(16)     rjmp Op_SET
Ext_SET5: Bit(32)     rjmp Op_SET
Ext_SET6: Bit(64)     rjmp Op_SET
Ext_SET7: Bit(128)    rjmp Op_SET

Op_BIT: /*  Carry not modified, S and Z reflect AND operation, V = Z */
    ld   Operand,EAddr
    RestoreFlags
    and  Operand,tmp
    SaveFlags
    CopyZtoV
    FETCH

Op_RES:
    ld   Operand,EAddr
    and  Operand,tmp
    st   EAddr,Operand
    FETCH

Op_SET:
    ld   Operand,EAddr
    or   Operand,tmp
    st   EAddr,Operand
    FETCH


/*****************************************************************************
 ****************** Extended (ED) instructions a0-bf *************************/

Ext_a0:             Op_LDI               FETCH
Ext_a1:             Op_CPI               FETCH
Ext_a2:         /*  Op_INI   */         
Ext_a3:         /*  Op_OUTI  */
Ext_a4:
Ext_a5:
Ext_a6:
Ext_a7:                                  NOT_IMPLEMENTED
Ext_a8:             Op_LDD               FETCH
Ext_a9:             Op_CPD               FETCH
Ext_aa:         /*  Op_IND   */          
Ext_ab:         /*  Op_OUTD  */
Ext_ac:
Ext_ad:
Ext_ae:
Ext_af:                                  NOT_IMPLEMENTED

Ext_b0:             Op_LDIR              FETCH
Ext_b1:             Op_CPIR              FETCH
Ext_b2:          /* Op_INIR  */          
Ext_b3:          /* Op_OTIR  */
Ext_b4:
Ext_b5:
Ext_b6:
Ext_b7:                                  NOT_IMPLEMENTED
Ext_b8:             Op_LDDR              FETCH
Ext_b9:             Op_CPDR              FETCH
Ext_ba:          /* Op_INDR  */          
Ext_bb:          /* Op_OTDR  */
Ext_bc:
Ext_bd:
Ext_be:                                  NOT_IMPLEMENTED
Ext_bf: /* normally NOP */  rjmp MCodeFETCH

/*****************************************************************************
 ****************** Initialization and debugging *****************************
 *****************************************************************************/

    .global startZ80
startZ80:
    clr  regZero
    ldi  regOne,1
    clr  regIXL         ; registers should not be initialized,
    clr  regIXH         ; but this helps compare correct execution
    clr  regIYL
    clr  regIYH
    clr  regB2
    clr  regC2
    clr  regD2
    clr  regE2
    clr  regH2
    clr  regL2
    sei
    SaveFlags
    clr  regPCL
    ldi  regPCH,5       ; all memory map shifted by 5 pages
    FETCH


trap:
    sbiw  regPC,1
    rcall trace
1:  rjmp 1b

#if TRACE
fetch_and_trace2:
    cpi  regPCL,0
    brne 1f
    cpi  regPCH,1+5
    breq start_trace
1:
    cpi  regPCL,0x9A
    brne 1f
    cpi  regPCH,0xF1+5
    breq restore_trace
1:
    cpi  regPCL,0x05
    brne 1f
    cpi  regPCH,0+5
    breq save_trace
    rjmp 1f
start_trace:
    ldi  tmp,0xFF
    sts  traceFlag,tmp
    rjmp 1f
save_trace:
    lds  tmp,traceFlag
    lsr  tmp
    sts  traceFlag,tmp
    rjmp 1f
restore_trace:
    lds  tmp,traceFlag
    lsl  tmp
    sts  traceFlag,tmp

1:
    ld   ZL,regPC+
    lds  tmp,traceFlag
    sbrs tmp,7
    ret
#endif


send_space:
    ldi   r16,' '
send_char: 
    jmp   uart_send
send_hex:
    push  r16
    swap  r16
    rcall send_hexbyte
    pop   r16
send_hexbyte:
    andi  r16,0x0f
    cpi   r16,10
    brlo  1f
    subi  r16,-7
1:  subi  r16,-48
    rjmp  send_char
send_newline:
    ldi   r16,'\r'
    rcall send_char
    ldi   r16,'\n'
    rjmp  send_char



#define write_space             rcall send_space
#define write(char)             ldi r16,char $  rcall send_char
#define write_flag(char,bit)    ldi r16,'-'  $  sbrc r17,bit  $  write(char)
#define write_hex(reg)          mov r16,reg  $  rcall send_hex
#define write_addr(reg)         mov r16,reg##H  $  subi r16,5  $  rcall send_hex  $  write_hex(reg##L)

trace:
    push r17
    push r16
    write_space  $  write_space  $  write_space  $  write_space  $  write_space  $  write_space
 
/*
    write_hex(EAddrH)  $  write_hex(EAddrL)  $  write('=')
    ld   r16,Z  $  call send_hex
    write_space
*/

    write('A')  $  write('=')  $  write_hex(regA)
    write_space
    write('B')  $  write('C')  $  write('=')  $  write_hex(regB)  $  write_hex(regC)
    write_space
    write('D')  $  write('E')  $  write('=')  $  write_hex(regD)  $  write_hex(regE)
    write_space
    write('H')  $  write('L')  $  write('=')  $  write_hex(regH)  $  write_hex(regL)
    write_space
/*
    write('I')  $  write('X')  $  write('=')  $  write_hex(regIXH)  $  write_hex(regIXL)
    write_space
    write('I')  $  write('Y')  $  write('=')  $  write(regIYH)  $  write(regIYL)
    write_space
*/

    write_flag('S',bitN)
    write_flag('Z',bitZ)
    write('1')
    write('x') /*  write_flag('A',bitH)  */
    write('1')
    write_flag('V',bitPV)
    write('1')
    write_flag('C',bitC)

    write_space
    write('S')  $  write('P')  $  write('=')  $  write_addr(regSP)
    call send_newline

    sbiw regPC,1
    write_addr(regPC)
    write_space
    ld   r16,regPC  $  call send_hex
    write_space
    adiw regPC,1

    ld   r16,regPC  $  call send_hex
    call send_newline

    pop  r16
    pop  r17
    ret

/*****************************************************************************
 ****************** MCode Instructions accelerators **************************
 *****************************************************************************/

.global Z80_code
Z80_code:   /* MCode op not implemented yet, we still accelerate the next() routine */
    mov     regA,ZL
    ldi     ZH,1+5  /* LSB in page 1 */
    ld      regL,Z
    ldi     ZH,2+5  /* MSB in page 2 */
    ld      regH,Z
    movw    regPC,regHL
    subi    regPCH,-5
ExecZ80:
    FETCH

/* DUP and SWAP */
MCD_20: ld tmp,Y $ ldd tmpH,Y+1 $ st -Y,tmpH $ st -Y,tmp $ rjmp MCodeFETCH
MCD_21: ld tmp,Y $ ldd ZL,Y+2 $ st Y,ZL $ std Y+2,tmp $ ldd tmpH,Y+1 $ ldd ZH,Y+3 $ std Y+1,ZH $ std Y+3,tmpH $ rjmp MCodeFETCH

#define LOCAL       movw Z,regIX
#define GLOBAL      lds ZL,0x0812 $ lds ZH,0x0813
#define STACK       Op_POP(Z)
#define EXTERNAL    rcall ExternalAddr

#define SAVE_BC     sts 0x081a,regC $ sts 0x081b,regB
#define RESTORE_BC  lds regC,0x081a $ lds regB,0x081b

#define Incr2(reg)  sec $ adc reg##L,regOne $ adc reg##H,regZero
#define MFETCH(reg) movw Z,regDE $ subi ZH,-5 $ Incr(regDE) $ ld reg,Z
#define MRELATIVE(reg) movw Z,regDE $ subi ZH,-5 $ Incr(regDE) $ ld reg##L,Z+ $ ld reg##H,Z
#define MFETCHW(reg) movw Z,regDE $ subi ZH,-5 $ Incr2(regDE) $ ld reg##L,Z+ $ ld reg##H,Z
#define ADIW(reg,val)   subi reg##L,lo8(-val) $ sbci reg##H,hi8(-val)

MCD_8d: /* LIB n        Load Immediate Byte */
    MFETCH(tmp)
MCD_PushByte:       // Push tmp
    clr tmpH
MCD_PushWord:
    Op_PUSH(tmp) 
MCodeFETCH:
    MFETCH(ZL)
    ldi     ZH,hi8(pm(MCodeTable))
    ijmp

MCD_8e: /* LIW nn       Load Immediate Word */
    MFETCHW(regHL)
MCodePUSH:          // Push HL
    Op_PUSH(regHL)
    MFETCH(ZL)
    ldi     ZH,hi8(pm(MCodeTable))
    ijmp
    
MCD_8f: /* LID nnmm     Load Immediate Double word */
    MFETCHW(regHL)
    MFETCHW(tmp)
    Op_PUSH(tmp)
    rjmp MCodePUSH
    
MCD_ab: Op_POP(regHL)  $  or regH,regL  $ breq True /* EQ0 */
False:
MCD_90: ldi tmp,0  $  rjmp MCD_PushByte  /* LI0 Load Immediate 0 */

#define Compare         sub regL,tmpL $ sbc regH,tmpH

MCD_a3: Op_POP(regHL) $ Op_POP(tmp) $ Compare $ brcs True $ rjmp False /* HIGHER THAN */
MCD_a4: Op_POP(regHL) $ Op_POP(tmp) $ Compare $ brcc True $ rjmp False /* LOWER OR EQUAL */
MCD_b3: Op_POP(regHL) $ Op_POP(tmp) $ Compare $ brmi True $ rjmp False /* GREATER THAN */
MCD_b4: Op_POP(regHL) $ Op_POP(tmp) $ Compare $ brpl True $ rjmp False /* LESS OR EQUAL */

MCD_cb: Op_POP(regHL)  $  or regH,regL  $ breq False /* NE0 */
True:
MCD_91: ldi tmp,1  $  rjmp MCD_PushByte  /* LI1 Load Immediate 1 */

MCD_a0: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ breq True $ rjmp False /* EQUAL */
MCD_a1: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ brne True $ rjmp False /* NOT EQUAL */
MCD_a2: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ brcs True $ rjmp False /* LOWER THAN */
MCD_a5: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ brcc True $ rjmp False /* HIGHER OR EQUAL */
MCD_b2: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ brmi True $ rjmp False /* LESS THAN */
MCD_b5: Op_POP(tmp) $ Op_POP(regHL) $ Compare $ brpl True $ rjmp False /* GREATER OR EQUAL*/


.global BeforeAlign2
BeforeAlign2:
    .align 9        ; 2^9 to be sure the MCodeTable starts on a code page boundary
.global AfterAlign2
AfterAlign2:

.global MCodeTable
MCodeTable:
#undef _
#define _ rjmp Z80_code $
#define M(code) rjmp MCD_##code $

/*0*/   _     _     _   M(03) M(04) M(05) M(06) M(07) M(08) M(09) M(0a) M(0b)   _   M(0d) M(0e) M(0f) 
/*1*/ M(10)   _     _   M(13) M(14) M(15) M(16) M(17) M(18) M(19) M(1a) M(1b)   _   M(1d) M(1e) M(1f) 
/*2*/ M(20) M(21) M(22) M(23) M(24) M(25) M(26) M(27) M(28) M(29) M(2a) M(2b) M(2c) M(2d) M(2e) M(2f)
/*3*/ M(30) M(31) M(32) M(33) M(34) M(35) M(36) M(37) M(38) M(39) M(3a) M(3b) M(3c) M(3d)   _   M(3f)
/*4*/   _     _   M(42) M(43) M(44) M(45) M(46) M(47) M(48) M(49) M(4a) M(4b) M(4c) M(4d) M(4e) M(4f)
/*5*/   _     _   M(52) M(53) M(54) M(55) M(56) M(57) M(58) M(59) M(5a) M(5b) M(5c) M(5d) M(5e) M(5f)
/*6*/ M(60) M(61) M(62) M(63) M(64) M(65) M(66) M(67) M(68) M(69) M(6a) M(6b) M(6c) M(6d) M(6e) M(6f)
/*7*/ M(70) M(71) M(72) M(73) M(74) M(75) M(76) M(77) M(78) M(79) M(7a) M(7b) M(7c) M(7d) M(7e) M(7f)
/*8*/ M(80) M(81) M(82) M(83) M(84) M(85) M(86)   _   M(88) M(89) M(8a) M(8b) M(8c) M(8d) M(8e) M(8f)
/*9*/ M(90) M(91) M(92) M(93) M(94) M(95) M(96) M(97) M(98) M(99) M(9a) M(9b) M(9c) M(9d) M(9e) M(9f)
/*A*/ M(a0) M(a1) M(a2) M(a3) M(a4) M(a5) M(a6) M(a7) M(a8) M(a9) M(aa) M(ab) M(ac) M(ad) M(ae) M(af) 
/*B*/ M(b0) M(b1) M(b2) M(b3) M(b4) M(b5) M(b6) M(b7) M(b8) M(b9) M(ba) M(bb) M(bc) M(bd)   _     _  
/*C*/ M(c0) M(c1) M(c2)   _     _   M(c5) M(c6) M(c7)   _     _     _   M(cb)   _     _   M(ce) M(cf)
/*D*/ M(d0) M(d1)   _     _   M(d4)   _     _     _     _     _     _     _     _     _   M(de) M(df)
/*E*/ M(e0) M(e1) M(e2) M(e3) M(e4) M(e5) M(e6)   _   M(e8) M(e9) M(ea)   _     _   M(ed)   _   M(ef)
/*F*/ M(f0) M(f1) M(f2) M(f3) M(f4) M(f5) M(f6) M(f7) M(f8) M(f9) M(fa) M(fb) M(fc) M(fd) M(fe) M(ff)

MCD_92: ldi tmp,2  $  rjmp MCD_PushByte  /* LI2 Load Immediate 2 */
MCD_93: ldi tmp,3  $  rjmp MCD_PushByte
MCD_94: ldi tmp,4  $  rjmp MCD_PushByte
MCD_95: ldi tmp,5  $  rjmp MCD_PushByte
MCD_96: ldi tmp,6  $  rjmp MCD_PushByte
MCD_97: ldi tmp,7  $  rjmp MCD_PushByte
MCD_98: ldi tmp,8  $  rjmp MCD_PushByte
MCD_99: ldi tmp,9  $  rjmp MCD_PushByte
MCD_9a: ldi tmp,10 $  rjmp MCD_PushByte
MCD_9b: ldi tmp,11 $  rjmp MCD_PushByte
MCD_9c: ldi tmp,12 $  rjmp MCD_PushByte
MCD_9d: ldi tmp,13 $  rjmp MCD_PushByte
MCD_9e: ldi tmp,14 $  rjmp MCD_PushByte
MCD_9f: ldi tmp,15 $  rjmp MCD_PushByte  /* LI15 Load Immediate 15 */

/*********************************************************************
********** The four types of memory **********************************
*********************************************************************/

ExternalAddr:
    MFETCH(tmpL)
    lsl     tmpL
    neg     tmpL
    subi    tmpL,18         ; => -2n-18
    ldi     tmpH,4          ; 0xff + 5
    GLOBAL
    add     ZL,tmpL         ; => GLOBAL-18-2n
    adc     ZH,tmpH
    ld      regC,Z+
    ld      regB,Z
    MFETCH(ZL)
    ldi     ZH,0
    lsl     ZL
    rol     ZH
    add     ZL,regC
    adc     ZH,regB
    ret
    
/********************************************************************/


/******************************************************************************
********* Instructions which use Local addresses ******************************
*******************************************************************************/

MCD_10: /* LLW0 */
    LOCAL
    subi    ZH,-5
MCodeLOAD:
    ld      regL,Z+
    ld      regH,Z
    Op_PUSH(regHL)
    MFETCH(ZL)
    ldi     ZH,hi8(pm(MCodeTable))
    ijmp

MCD_03: LOCAL $ ADIW(Z,0x0506) $ rjmp MCodeLOAD /* LOAD_PARAM1 */
MCD_04: LOCAL $ ADIW(Z,0x0508) $ rjmp MCodeLOAD /* LOAD_PARAM2 */
MCD_05: LOCAL $ ADIW(Z,0x050A) $ rjmp MCodeLOAD /* LOAD_PARAM3 */
MCD_06: LOCAL $ ADIW(Z,0x050C) $ rjmp MCodeLOAD /* LOAD_PARAM4 */
MCD_07: LOCAL $ ADIW(Z,0x050E) $ rjmp MCodeLOAD /* LOAD_PARAM5 */

MCD_22: LOCAL $ ADIW(Z,0x04FC) $ rjmp MCodeLOAD /* LLW2  */
MCD_23: LOCAL $ ADIW(Z,0x04FA) $ rjmp MCodeLOAD /* LLW3  */
MCD_24: LOCAL $ ADIW(Z,0x04F8) $ rjmp MCodeLOAD /* LLW4  */
MCD_25: LOCAL $ ADIW(Z,0x04F6) $ rjmp MCodeLOAD /* LLW5  */
MCD_26: LOCAL $ ADIW(Z,0x04F4) $ rjmp MCodeLOAD /* LLW6  */
MCD_27: LOCAL $ ADIW(Z,0x04F2) $ rjmp MCodeLOAD /* LLW7  */
MCD_28: LOCAL $ ADIW(Z,0x04F0) $ rjmp MCodeLOAD /* LLW8  */
MCD_29: LOCAL $ ADIW(Z,0x04EE) $ rjmp MCodeLOAD /* LLW9  */
MCD_2a: LOCAL $ ADIW(Z,0x04EC) $ rjmp MCodeLOAD /* LLW10 */
MCD_2b: LOCAL $ ADIW(Z,0x04EA) $ rjmp MCodeLOAD /* LLW11 */

MCD_80:     /* LLA n  (n signed) */
    MFETCH(tmp)
    LOCAL
    clr     tmpH
    lsl     tmp
    sbci    tmpH,0
    add     tmp,ZL
    adc     tmpH,ZH
    rjmp    MCD_PushWord

MCD_2c:     /* LLW n  (n signed) */
    MFETCH(tmp)
    LOCAL
    ldi     tmpH,5
    lsl     tmp
    sbci    tmpH,0
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeLOAD

MCD_08:     /* LLD n  (n signed) */
    MFETCH(tmp)
    ldi     tmpH,5
    lsl     tmp
    sbci    tmpH,0
    LOCAL
LoadDW_idx:
    add     ZL,tmp
    adc     ZH,tmpH
MCodeLOAD_DW:
    ld      regL,Z+
    ld      regH,Z+
    ld      tmpL,Z+
    ld      tmpH,Z
    Op_PUSH(tmp)
    rjmp    MCodePUSH

MCodeSTORE:
    Op_POP(regHL)
MCodeSTORE2:
    st      Z+,regL
    st      Z,regH
    MFETCH(ZL)
    ldi     ZH,hi8(pm(MCodeTable))
    ijmp

MCD_13: LOCAL $ ADIW(Z,0x0506) $ rjmp MCodeSTORE  /* STORE_PARAM1 */
MCD_14: LOCAL $ ADIW(Z,0x0508) $ rjmp MCodeSTORE  /* STORE_PARAM2 */
MCD_15: LOCAL $ ADIW(Z,0x050A) $ rjmp MCodeSTORE  /* STORE_PARAM3 */
MCD_16: LOCAL $ ADIW(Z,0x050C) $ rjmp MCodeSTORE  /* STORE_PARAM4 */
MCD_17: LOCAL $ ADIW(Z,0x050E) $ rjmp MCodeSTORE  /* STORE_PARAM5 */

MCD_32: LOCAL $ ADIW(Z,0x04FC) $ rjmp MCodeSTORE /* SLW2 */
MCD_33: LOCAL $ ADIW(Z,0x04FA) $ rjmp MCodeSTORE /* SLW3 */
MCD_34: LOCAL $ ADIW(Z,0x04F8) $ rjmp MCodeSTORE /* SLW4 */
MCD_35: LOCAL $ ADIW(Z,0x04F6) $ rjmp MCodeSTORE /* SLW5 */
MCD_36: LOCAL $ ADIW(Z,0x04F4) $ rjmp MCodeSTORE /* SLW6 */
MCD_37: LOCAL $ ADIW(Z,0x04F2) $ rjmp MCodeSTORE /* SLW7 */
MCD_38: LOCAL $ ADIW(Z,0x04F0) $ rjmp MCodeSTORE /* SLW8 */
MCD_39: LOCAL $ ADIW(Z,0x04EE) $ rjmp MCodeSTORE /* SLW9 */
MCD_3a: LOCAL $ ADIW(Z,0x04EC) $ rjmp MCodeSTORE /* SLW10*/
MCD_3b: LOCAL $ ADIW(Z,0x04EA) $ rjmp MCodeSTORE /* SLW11*/

MCD_3c:     /* SLW n  (n signed) */
    MFETCH(tmp)
    LOCAL
    ldi     tmpH,5
    lsl     tmp
    sbci    tmpH,0
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeSTORE

MCD_18:     /* SLD n  (n signed) */
    MFETCH(tmp)
    LOCAL
    ldi     tmpH,5
    lsl     tmp
    sbci    tmpH,0
MCodeSTORE_idx_DW:
    add     ZL,tmp
    adc     ZH,tmpH
MCodeSTORE_DW:
    Op_POP(regHL)
    Op_POP(tmp)
MCodePUSH_DW:
    st      Z+,regL
    st      Z+,regH
    st      Z+,tmpL
    st      Z,tmpH
MFETCH_RESTOREBC:
    RESTORE_BC              // mimic TurboM2 behavior
    MFETCH(ZL)
    ldi     ZH,hi8(pm(MCodeTable))
    ijmp

/******************************************************************************
********* Instructions which use Global addresses *****************************
*******************************************************************************/

MCD_81:     /* LGA n */
    MFETCH(tmp)
    GLOBAL
    clr     tmpH
    lsl     tmp
    adc     tmpH,regZero
    add     tmp,ZL
    adc     tmpH,ZH
    rjmp    MCD_PushWord


MCD_2d:     /* LGW n */
    MFETCH(tmp)
    ldi     tmpH,5
    lsl     tmp
    adc     tmpH,regZero
    GLOBAL
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeLOAD

MCD_42: /* LGW2 to LGW15 */
MCD_43:
MCD_44:
MCD_45:
MCD_46:
MCD_47:
MCD_48:
MCD_49:
MCD_4a:
MCD_4b:
MCD_4c:
MCD_4d:
MCD_4e:
MCD_4f:
    mov     tmp,ZL
    andi    tmp,0x0F
    lsl     tmp
    ldi     tmpH,5
    GLOBAL
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeLOAD

MCD_09:     // LGD n
    MFETCH(tmp)
    GLOBAL
MLOAD_idx_DW:
    ldi     tmpH,5
    lsl     tmp
    adc     tmpH,regZero
    rjmp    LoadDW_idx

MCD_3d:     /* SGW n */
    MFETCH(tmp)
    GLOBAL
    ldi     tmpH,5
    lsl     tmp
    adc     tmpH,regZero
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeSTORE

MCD_52: /* SGW2 to SGW15 */
MCD_53:
MCD_54:
MCD_55:
MCD_56:
MCD_57:
MCD_58:
MCD_59:
MCD_5a:
MCD_5b:
MCD_5c:
MCD_5d:
MCD_5e:
MCD_5f:
    mov     tmp,ZL
    andi    tmp,0x0F
    lsl     tmp
    ldi     tmpH,5
    GLOBAL
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeSTORE

MCD_19:     // SGD n
    MFETCH(tmp)
    GLOBAL
    SAVE_BC         // mimic TurboM2 side-effect
MSTORE_idx_DW:
    ldi     tmpH,5
    lsl     tmp
    adc     tmpH,regZero
    rjmp    MCodeSTORE_idx_DW

/******************************************************************************
********* Instructions which use address on stack *****************************
*******************************************************************************/

#define CHECKNIL(label)    subi ZL,0 $ sbci ZH,0 $ breq label

MCD_2e: /* LSW n */
    MFETCH(tmp)
    rjmp MCD_LoadStack

MCD_0d: // LXB
    Op_POP(tmp)
    STACK
    CHECKNIL(error7)
    subi    ZH,-5
    add     ZL,tmpL
    adc     ZH,tmpH
    ld      tmp,Z
    rjmp    MCD_PushByte

MCD_0e: // LXW
    Op_POP(tmp)
    lsl     tmpL
    rol     tmpH
    STACK
    CHECKNIL(error7)
    subi    ZH,-5
    add     ZL,tmpL
    adc     ZH,tmpH
    rjmp    MCodeLOAD

MCD_0f: // LXD
    Op_POP(tmp)
    lsl     tmpL
    rol     tmpH
    lsl     tmpL
    rol     tmpH
    STACK
    CHECKNIL(error7)
    subi    tmpH,-5
    rjmp    LoadDW_idx

MCD_60: /* LSW0 to LSW15 */
MCD_61:
MCD_62:
MCD_63:
MCD_64:
MCD_65:
MCD_66:
MCD_67:
MCD_68:
MCD_69:
MCD_6a:
MCD_6b:
MCD_6c:
MCD_6d:
MCD_6e:
MCD_6f:
    mov     tmp,ZL
    andi    tmp,0x0F
MCD_LoadStack:
    lsl     tmp
    ldi     tmpH,5
    STACK
    CHECKNIL(error7)
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeLOAD

MCD_82: /* LSA n */
    MFETCH(tmp)
    clr     tmpH
    lsl     tmp
    adc     tmpH,regZero
    STACK
    CHECKNIL(error7)
    add     tmp,ZL
    adc     tmpH,ZH
    rjmp    MCD_PushWord

error7: ldi tmp,7 $ rjmp error


MCD_70: /* SSW0 to SSW15 */
MCD_71:
MCD_72:
MCD_73:
MCD_74:
MCD_75:
MCD_76:
MCD_77:
MCD_78:
MCD_79:
MCD_7a:
MCD_7b:
MCD_7c:
MCD_7d:
MCD_7e:
MCD_7f:
    mov     tmp,ZL
    andi    tmp,0x0F
    lsl     tmp
    ldi     tmpH,5
    Op_POP(regHL)
    STACK
    CHECKNIL(error7)
    add     ZL,tmp
    adc     ZH,tmpH
    rjmp    MCodeSTORE2

MCD_1d: // SXB
    Op_POP(regHL)           // byte to write
    Op_POP(tmp)             // index
    STACK                   // address
    CHECKNIL(error7)
    subi    ZH,-5
    add     ZL,tmpL
    adc     ZH,tmpH
    st      Z,regL
    rjmp    MCodeFETCH

MCD_1e: // SXW
    Op_POP(regHL)           // word to write
    Op_POP(tmp)             // index
    lsl     tmpL
    rol     tmpH
    STACK                   // address
    CHECKNIL(error7)
    subi    ZH,-5
    add     ZL,tmpL
    adc     ZH,tmpH
    rjmp    MCodeSTORE2

MCD_1f: // SXD
    Op_POP(regHL)           // LSW of dword to write
    Op_POP(regHL2)          // MSW of dword to write
    Op_POP(tmp)             // index
    lsl     tmpL
    rol     tmpH
    lsl     tmpL
    rol     tmpH
    STACK                   // address
    CHECKNIL(error7)
    subi    ZH,-5
    add     ZL,tmpL
    adc     ZH,tmpH
    movw    tmp,regHL2
    rjmp    MCodePUSH_DW

error7bis: ldi tmp,7 $ rjmp error

MCD_0a: // LSD n
    MFETCH(tmp)     // beware: MFETCH uses Z, so it must come before STACK
    STACK           // Z = POP()
    CHECKNIL(error7bis)
    rjmp MLOAD_idx_DW

MCD_1a: // SSD n : double word to store is on top of stack
    MFETCH(tmp) // beware: MFETCH uses Z, so it must come before STACK
    ldi     tmpH,5
    lsl     tmp
    adc     tmpH,regZero
    ldd     ZL,regSP+4        // pointer is deeper in stack
    ldd     ZH,regSP+5
    CHECKNIL(error7bis)
    add     ZL,tmp
    adc     ZH,tmpH
    ld      tmp,regSP+
    st      Z+,tmp
    ld      tmp,regSP+
    st      Z+,tmp
    ld      tmp,regSP+
    st      Z+,tmp
    ld      tmp,regSP+
    st      Z,tmp
    adiw    regSP,2         // drop pointer
    rjmp    MCodeFETCH

/******************************************************************************
********* Instructions which use External addresses ***************************
*******************************************************************************/

MCD_83: /* LEA n m */
    EXTERNAL
    Op_PUSH(Z)
    rjmp    MCodeFETCH

MCD_2f: /* LEW n m */
    EXTERNAL
    subi    ZH,-5
    rjmp    MCodeLOAD

MCD_3f: /* SEW n m */
    EXTERNAL
    subi    ZH,-5
    rjmp    MCodeSTORE

MCD_0b: /* LED n m */
    EXTERNAL
    subi    ZH,-5
    rjmp    MCodeLOAD_DW

MCD_1b: /* SED n m */
    EXTERNAL
    subi    ZH,-5
    rjmp    MCodeSTORE_DW


/**************************************************************************
************* Arithmetic instructions *************************************
**************************************************************************/

MCD_a6: Op_POP(tmp) $ Op_POP(regHL) $ add regL,tmpL $ adc regH,tmpH $ rjmp MCodePUSH  /* ADD */
MCD_a7: Op_POP(tmp) $ Op_POP(regHL) $ sub regL,tmpL $ sbc regH,tmpH $ rjmp MCodePUSH  /* SUB */
MCD_e6: Op_POP(regHL) $ Op_POP(tmp) $ or  regL,tmpL $ or  regH,tmpH $ rjmp MCodePUSH  /* OR */
MCD_e8: Op_POP(regHL) $ Op_POP(tmp) $ and regL,tmpL $ and regH,tmpH $ rjmp MCodePUSH  /* AND */
MCD_e9: Op_POP(regHL) $ Op_POP(tmp) $ eor regL,tmpL $ eor regH,tmpH $ rjmp MCodePUSH  /* EOR */
MCD_ac: Op_POP(regHL) $ Incr(regHL)   $ rjmp MCodePUSH    /* INC */
MCD_ad: Op_POP(regHL) $ Decr(regHL)   $ rjmp MCodePUSH    /* DEC */
MCD_b6: ld tmp,regSP+ $ com tmp $ andi tmp,1 $ st -regSP,tmp $ rjmp MCodeFETCH  /* NOT */
MCD_b7: Op_POP(regHL) $ com regL $ com regH $ rjmp MCodePUSH    /* COMPLEMENT */
MCD_bc: Op_POP(regHL) $ tst regH $ brpl 1f $ neg regL $ com regH $1: rjmp MCodePUSH /* ABS (wrong for -2^15) */

MCD_ae: MFETCH(regC)  $ Op_POP(regHL) $ add regL,regC $ adc regH,regZero $ rjmp MCodePUSH   /* ADD n */
MCD_af: MFETCH(regC)  $ Op_POP(regHL) $ sub regL,regC $ sbc regH,regZero $ rjmp MCodePUSH   /* SUB n */
MCD_b0: MFETCH(regA) $ Op_POP(regHL) $1: lsl regL $ rol regH $ dec regA $ brne 1b $ rjmp MCodePUSH  /* SHL n */
MCD_b1: MFETCH(regA) $ Op_POP(regHL) $1: lsr regH $ ror regL $ dec regA $ brne 1b $ rjmp MCodePUSH  /* SHR n */

MCD_ea: /* POWER2 */
    Op_POP(tmp)
    inc     tmp
    clr     regH
    clr     regL
    sec
1:  rol     regL
    rol     regH
    dec     tmp
    brne    1b
    rjmp    MCodePUSH

MCD_a8: rcall Multiply16sx16s_32  $ Op_PUSH(Accu) $ rjmp MCodeFETCH // UMUL

;***************************************************************************
Multiply16sx16s_32:     // signed multiplication 16x16=32 bits
                        // from AVR Application Note #201
                        // result in Accu (LSW) and tmp (MSW)
    push    r0
    push    r1
    push    r20
    push    r21
    push    r22
    push    r23
    ld      r20,regSP+
    ld      r21,regSP+
    ld      r22,regSP+
    ld      r23,regSP+
    muls    r21,r23
    movw    tmp,r0
    mul     r20,r22
    movw    Accu,r0
    mulsu   r21,r22
    sbc     tmpH,regZero
    add     AccuH,r0
    adc     tmpL,r1
    adc     tmpH,regZero
    mulsu   r23,r20
    sbc     tmpH,regZero
    add     AccuH,r0
    adc     tmpL,r1
    adc     tmpH,regZero
    pop     r23
    pop     r22
    pop     r21
    pop     r20
    pop     r1
    pop     r0
    ret

;***************************************************************************
;*
;* "div16u" - 16/16 Bit Unsigned Division from AVR Application Note #200
;*
;* This subroutine divides the two 16-bit numbers 
;* "dd8uH:dd8uL" (dividend) and "dv16uH:dv16uL" (divisor). 
;* The result is placed in "dres16uH:dres16uL" and the remainder in
;* "drem16uH:drem16uL".
;*  
;* Number of words  :19
;* Number of cycles :235/251 (Min/Max)
;* Low registers used   :2 (drem16uL,drem16uH)
;* High registers used  :5 (dres16uL/dd16uL,dres16uH/dd16uH,dv16uL,dv16uH,
;*              dcnt16u)
;*
;***************************************************************************

;***** Subroutine Register Variables

#define drem16uL AccuL
#define drem16uH AccuH
#define dres16uL regL
#define dres16uH regH
#define dd16uL   regL
#define dd16uH   regH
#define dv16uL   tmpL
#define dv16uH   tmpH
#define dcnt16u  ZL

;***** Code

div16u:
    ld      dv16uL,regSP+
    ld      dv16uH,regSP+
    ld      dd16uL,regSP+
    ld      dd16uH,regSP+
    clr     drem16uL            ;clear remainder Low byte
    sub     drem16uH,drem16uH   ;clear remainder High byte and carry
    ldi     dcnt16u,17          ;init loop counter
d16u_1:
    rol     dd16uL              ;shift left dividend
    rol     dd16uH
    dec     dcnt16u             ;decrement counter
    brne    d16u_2              ;if done
    ret                         ;    return
d16u_2: 
    rol     drem16uL            ;shift dividend into remainder
    rol     drem16uH
    sub     drem16uL,dv16uL     ;remainder = remainder - divisor
    sbc     drem16uH,dv16uH     ;
    brcc    d16u_3              ;if result negative
    add     drem16uL,dv16uL     ;    restore remainder
    adc     drem16uH,dv16uH
    clc                         ;    clear carry to be shifted into result
    rjmp    d16u_1              ;else
d16u_3: 
    sec                         ;    set carry to be shifted into result
    rjmp    d16u_1
    
;***************************************************************************
;*
;* "div16s" - 16/16 Bit Signed Division from AVR Application Note #200
;*
;* This subroutine divides signed the two 16 bit numbers 
;* "dd16sH:dd16sL" (dividend) and "dv16sH:dv16sL" (divisor). 
;* The result is placed in "dres16sH:dres16sL" and the remainder in
;* "drem16sH:drem16sL".
;*  
;* Number of words  :39
;* Number of cycles :247/263 (Min/Max)
;* Low registers used   :3 (d16s,drem16sL,drem16sH)
;* High registers used  :7 (dres16sL/dd16sL,dres16sH/dd16sH,dv16sL,dv16sH,
;*              dcnt16sH)
;*
;***************************************************************************

;***** Subroutine Register Variables

#define    d16s     ZH
#define    drem16sL AccuL
#define    drem16sH AccuH
#define    dres16sL regL
#define    dres16sH regH
#define    dd16sL   regL
#define    dd16sH   regH
#define    dv16sL   tmpL
#define    dv16sH   tmpH
#define    dcnt16s  ZL

;***** Code

div16s:
    ld      dv16sL,regSP+
    ld      dv16sH,regSP+
    ld      dd16sL,regSP+
    ld      dd16sH,regSP+
    mov     d16s,dd16sH ;move dividend High to sign register
    eor     d16s,dv16sH ;xor divisor High with sign register
    sbrs    dd16sH,7    ;if MSB in dividend set
    rjmp    d16s_1
    com     dd16sH      ;    change sign of dividend
    com     dd16sL      
    add     dd16sL,regOne
    adc     dd16sL,regZero
d16s_1: 
    sbrs    dv16sH,7    ;if MSB in divisor set
    rjmp    d16s_2
    com     dv16sH      ;    change sign of divisor
    com     dv16sL      
    add     dv16sL,regOne
    adc     dv16sH,regZero
d16s_2: 
    clr     drem16sL    ;clear remainder Low byte
    sub     drem16sH,drem16sH;clear remainder High byte and carry
    ldi     dcnt16s,17  ;init loop counter

d16s_3: 
    rol     dd16sL      ;shift left dividend
    rol     dd16sH
    dec     dcnt16s     ;decrement counter
    brne    d16s_5      ;if done
    sbrs    d16s,7      ;    if MSB in sign register set
    rjmp    d16s_4
    com     dres16sH    ;        change sign of result
    com     dres16sL
    add     dres16sL,regOne
    adc     dres16sH,regZero
d16s_4: 
    ret         ;    return
d16s_5: 
    rol     drem16sL    ;shift dividend into remainder
    rol     drem16sH
    sub     drem16sL,dv16sL ;remainder = remainder - divisor
    sbc     drem16sH,dv16sH ;
    brcc    d16s_6      ;if result negative
    add     drem16sL,dv16sL ;    restore remainder
    adc     drem16sH,dv16sH
    clc         ;    clear carry to be shifted into result
    rjmp    d16s_3      ;else
d16s_6: 
    sec         ;    set carry to be shifted into result
    rjmp    d16s_3

;***************************************************************************

MCD_a9: rcall div16u $ rjmp MCodePUSH   // UDIV
MCD_aa: rcall div16u $ Op_PUSH(drem16u) $ rjmp MCodeFETCH   // UMOD
MCD_b9: rcall div16s $ rjmp MCodePUSH // IDIV  

MCD_c2: // UMUL_CHECK_OVF
    rcall   Multiply16sx16s_32
    Op_PUSH(Accu)
    rjmp    check_positive      // TODO: verify

MCD_b8: // IMUL : check overflows
    rcall   Multiply16sx16s_32
    Op_PUSH(Accu)
    tst     tmpH
    brmi    1f
; MSB is 0, check it fits in a positive 16-bit
    tst     AccuH
    brmi    error12
check_positive:
    or      tmpL,tmpH
    tst     tmpL
    brne    error12
    rjmp    MCodeFETCH
; MSW is non-0, check it is -1
1:  tst     AccuH
    brpl    error12
check_negative:
    and     tmpL,tmpH
    inc     tmpL
    brne    error12
    rjmp    MCodeFETCH

MCD_c0: // UADD (check overflow)
    Op_POP(tmp)
    Op_POP(regHL)
    add     regL,tmpL
    adc     regH,tmpH
    brcs    error12
    rjmp    MCodePUSH

MCD_c1: // USUB (check overflow)
    Op_POP(tmp)
    Op_POP(regHL)
    sub     regL,tmpL
    sbc     regH,tmpH
    brcs    error12
    rjmp    MCodePUSH

MCD_d0: // IADD (check overflow)
    Op_POP(tmp)
    Op_POP(regHL)
    add     regL,tmpL
    adc     regH,tmpL
    brvs    error12
    rjmp    MCodePUSH

MCD_d1: // ISUB (check overflow)
    Op_POP(tmp)
    Op_POP(regHL)
    sub     regL,tmpL
    sbc     regH,tmpH
    brvs    error12
    rjmp    MCodePUSH

error12:    // OVERFLOW
    ldi     tmp,12
    rjmp    error

/**************************************************************************
************* LONGINT Arithmetics *****************************************
**************************************************************************/

MCD_c6:  // LONGINT addition
    Op_POP(Z)       // LSW1
    Op_POP(tmp)     // MSW1
    Op_POP(regHL)   // LSW2
    Op_POP(Accu)    // MSW2
    add     regL,ZL
    adc     regH,ZH
    adc     AccuL,tmpL
    adc     AccuH,tmpH
    brvs    error12
    Op_PUSH(Accu)    // push MSW
    rjmp    MCodePUSH   // push LSW

MCD_c7: // LONGINT subtraction
    Op_POP(Z)       // LSW1
    Op_POP(tmp)     // MSW1
    Op_POP(regHL)   // LSW2
    Op_POP(Accu)    // MSW2
    sub     regL,ZL
    sbc     regH,ZH
    sbc     AccuL,tmpL
    sbc     AccuH,tmpH
    brvs    error12
    Op_PUSH(Accu)    // push MSW
    rjmp    MCodePUSH   // push LSW

MCD_ba: // LONG to CARD conversion
    Op_POP(regHL)
    Op_POP(tmp)
1:  or      tmpL,tmpH
    brne    error12
    rjmp    MCodePUSH
MCD_bb: // LONG to INT conversion
    Op_POP(regHL)
    Op_POP(tmp)
    tst     regH
    brpl    1b
    and     tmpL,tmpH
    inc     tmpL
    brne    error12
    rjmp    MCodePUSH
    
MCD_c5: // LONGINT COMPARE
    Op_POP(Z)       // LSW1
    Op_POP(tmp)     // MSW1
    Op_POP(regHL)   // LSW2
    Op_POP(Accu)    // MSW2
    sub     regL,ZL
    sbc     regH,ZH
    sbc     AccuL,tmpL
    sbc     AccuH,tmpH
    breq    long_equal
    brmi    long_inf
    mov     regL,regOne
    clr     regH
    Op_PUSH(regHL)
    clr     regL
    rjmp    MCodePUSH
long_inf:
    clr     regL
    clr     regH
    Op_PUSH(regHL)
    inc     regL
    rjmp    MCodePUSH
long_equal:
    clr     regL
    clr     regH
    Op_PUSH(regHL)
    rjmp    MCodePUSH
    
MCD_bd:  /* INT to LONG conversion */
    Op_POP(regHL)
    clr     AccuL
    clr     AccuH
    mov     tmp,regH
    lsl     tmp
    sbc     AccuL,regZero
    sbc     AccuH,regZero
    Op_PUSH(Accu)       // push MSW
    rjmp    MCodePUSH   // push LSW
    


/**************** Jumps ***************************************************************/

MCD_ce: Op_POP(tmp) $ movw regDE,tmp $ rjmp MCodeFETCH // JUMP_STACK
MCD_cf: MRELATIVE(regHL) $  add regL,regE $  adc regH,regD $ Incr(regDE) $ rjmp MCodePUSH // PUSH PC+nn
MCD_de: Op_POP(tmp) $  tst tmp $  breq 1f $  Incr(regDE)   $ rjmp MCodeFETCH /* ANDJP +n */
MCD_df: Op_POP(tmp) $  tst tmp $  brne 1f $  Incr(regDE)   $ rjmp MCodeFETCH /* ORJP +n */
1:  Op_PUSH(tmp)
MCD_e2: MFETCH(tmp)  $  add regE,tmp  $  adc regD,regZero  $ rjmp MCodeFETCH /* JPF +n */
MCD_e3: Op_POP(tmp)  $ tst tmp $ breq MCD_e2 $ Incr(regDE) $ rjmp MCodeFETCH /* JPFC +n */
MCD_e4: MFETCH(regL) $  sub regE,regL $  sbc regD,regZero  $ rjmp MCodeFETCH /* JPB -n */
MCD_e5: Op_POP(tmp)  $ tst tmp $ breq MCD_e4 $ Incr(regDE) $ rjmp MCodeFETCH /* JPBC -n */
MCD_8c: MFETCH(tmp)  $ Op_PUSH(regDE) $  add regE,tmp $  adc regD,regZero $ rjmp MCodeFETCH /* CALL +n */

MCD_ed: // PROC_CALL n
    MFETCH(tmp)
    rjmp    PROC_CALL
MCD_f1: // PROC_CALL 1
MCD_f2: // PROC_CALL 2
MCD_f3: // PROC_CALL 3
MCD_f4: // PROC_CALL 4
MCD_f5: // PROC_CALL 5
MCD_f6: // PROC_CALL 6
MCD_f7: // PROC_CALL 7
MCD_f8: // PROC_CALL 8
MCD_f9: // PROC_CALL 9
MCD_fa: // PROC_CALL 10
MCD_fb: // PROC_CALL 11
MCD_fc: // PROC_CALL 12
MCD_fd: // PROC_CALL 13
MCD_fe: // PROC_CALL 14
MCD_ff: // PROC_CALL 15
    mov     tmp,ZL      // get procedure number
    andi    tmp,0x0f     
PROC_CALL:
    clr     regC        // clear BC register
    clr     regB
    Op_PUSH(regDE)      // push return address
    GLOBAL              // get global pointer
    subi    ZH,-5
PROC_CALL_CONT:
    ld      regD,-Z     // get [GLOBAL-2] in regDE
    ld      regE,-Z
    lsl     tmp         // substract procedure number x2
    sub     regE,tmp
    sbc     regD,regZero
MCD_e0: MRELATIVE(regHL) $  add regE,regL $  adc regD,regH $ rjmp MCodeFETCH /* JP nn */
MCD_e1: Op_POP(tmp) $ tst tmp $ breq MCD_e0 $ Incr2(regDE) $ rjmp MCodeFETCH /* JPC nn */

MCD_ef: // EXTERN_PROC_CALL m n
    MFETCH(tmpH) // module number
    MFETCH(tmpL) // procedure number
    rjmp EXTERN_PROC_CALL

MCD_f0: // EXTERN_PROC_CALL mn
    MFETCH(tmp) // two nibbles: module number / procedure number
    mov     tmpH,tmp
    swap    tmpH
    andi    tmpH,0x0f
    andi    tmpL,0x0f
EXTERN_PROC_CALL: // tmpH=module number, tmpL=procedure number
    lsl     tmpH
    subi    tmpH,-0x12
    Op_PUSH(regDE)      // push return address
    GLOBAL              // get global pointer
    movw    regBC,Z     // and keep it in regBC
    subi    ZH,-5
    sub     ZL,tmpH     // prepare GLOBAL-18-2*m
    sbc     ZH,regZero
    ld      regL,Z+     // load [GLOBAL-18-2*m],ie new module addr
    ld      regH,Z
    movw    Z,regHL     // prepare to load module flags
    subi    ZH,-5
    ld      Accu,Z       // load module flags
    lsr     Accu
    brcs    enter_kernel// enter kernel mode if bit 0 set

    sts     0x0812,regL // save GLOBAL
    sts     0x0813,regH
    sbrs    Accu,0      // if bit 1 set, skip following jump
    rjmp    PROC_CALL_CONT
                        // bit 1 set means it's a Z80-compiled module:
    ld      regH,-Z     // load GLOBAL[-1]
    ld      regL,-Z
    lsl     tmpL        // multiply proc number by 2
    sub     regL,tmpL   // substract 2x proc number
    sbc     regH,regZero
    movw    Z,regHL     // prepare to get rel addr of routine
    subi    ZH,-5
    ld      regE,Z+     // get relative addr of routine in DE
    ld      regD,Z
    sec                 // increment HL
    adc     regL,regE   // add relative addr to get absolute addr
    adc     regH,regD
    movw    regPC,regHL // jump to Z80 code
    subi    regPCH,-5
    FETCH

enter_kernel:           // continue in Z80 emulation
    mov     regE,tmpL   // procedure number in E
    neg     regE        // negated procedure number
    ldi     regPCL,0x95
    ldi     regPCH,0x0a
    subi    regPCH,-5
    FETCH

        
MCD_d4: // ENTER n
    Op_PUSH(regIX)          // save frame pointer
    Op_PUSH(regBC)          // and BC
    movw    regIX,regSP
    subi    regIXH,5
    MFETCH(tmpL)            // get n (negative)
    ldi     tmpH,0xFF       //
    Op_PUSH(regDE)          // save instruction pointer
    sec                     // compute new stack pointer
    adc     tmpL,regSPL
    adc     tmpH,regSPH
    subi    tmpH,5
    lds     regA,0x0816     // and compare with top of heap
    sub     regA,tmpL
    lds     regA,0x0817
    sbc     regA,tmpH
    brsh    error6          // error if no more space for stack
    movw    regSP,tmp       // stack ok, update stack pointer
    subi    regSPH,-5
    rjmp    MCodeFETCH
error6:
    ldi     tmp,6
error:
    mov     regA,tmp        // error number
    ldi     regPCL,lo8(0x0cbe)
    ldi     regPCH,hi8(0x0cbe+0x0500)
    rjmp    ExecZ80

LEAVE:  // restore upper frame, expects param size/2 in ZL
    movw    regSP,regIX     // restore stack pointer from frame pointer
    subi    regSPH,-5
    Op_POP(regBC)           // pop BC
    Op_POP(regIX)           // pop frame pointer
    Op_POP(regDE)           // pop instruction pointer
    mov     tmp,ZL          // compute parameters size
    lsl     tmp            
    add     regSPL,tmp      // and add to stack pointer
    adc     regSPH,regZero
    ret

MCD_84: MFETCH(ZL)  $  rcall LEAVE  $ rjmp leaveCheck // LEAVE n
MCD_88: // LEAVE0
MCD_89: // LEAVE2
MCD_8a: // LEAVE4
MCD_8b: // LEAVE6
    andi    ZL,0x83
    rcall   LEAVE
leaveCheck:
    lsl     ZL
    brcc    leaveOk
    mov     regA,regB
    or      regA,regC
    brne    checkBC_1
leaveOk:
    rjmp    MCodeFETCH
checkBC_1:
    ldi     regPCL,lo8(0x0b90)
    ldi     regPCH,hi8(0x0b90+0x0500)
    rjmp    ExecZ80

MCD_85: // FCT_LEAVE n
    MFETCH(ZL)
    Op_POP(regHL)           // save result of function in HL
    rcall   LEAVE
    Op_PUSH(regHL)          // give result of function on stack
    rjmp    leaveCheck

MCD_86: // LONG_FCT_LEAVE n
    MFETCH(ZL)
    Op_POP(regHL2)          // save result of function
    Op_POP(regDE2)
    rcall   LEAVE
    Op_PUSH(regDE2)         // give result of function on stack
    Op_PUSH(regHL2)
    rjmp    leaveCheck

MCD_30: // copy block
    Op_POP(tmp)         // pop Size of block
    Op_POP(X)           // pop src pointer
    subi    XH,-5
    Op_POP(Z)           // pop dst pointer
    subi    ZH,-5
    adiw    tmp,1       // increment size before decrementing it
    rjmp    1f
0:  ld      Accu,X+     // copy one byte
    st      Z+,Accu
1:  sbiw    tmp,1       // decrement remaining size
    brne    0b          // and loop if not zero
    rjmp    MCodeFETCH

MCD_31: // copy string
    Op_POP(tmp)         // pop src size
    Op_POP(regHL)       // pop dst size
    Op_POP(X)           // pop src pointer
    Op_POP(Z)           // pop dst pointer
    subi    XL,0
    sbci    XH,0
    breq    error7ter
    subi    ZL,0
    sbci    ZH,0
    breq    error7ter
    subi    XH,-5       // prepare real memory pointers
    subi    ZH,-5
    adiw    tmp,1       // add 1 to sizes before decrementing them
    add     regL,regOne
    adc     regH,regZero
    rjmp    1f
copy_string_loop:
    ld      Accu,X+         // load src byte
    tst     Accu
    breq    end_copy_src    // src finished if byte 0
    sub     regL,regOne     // decrement dst size
    sbc     regH,regZero
    breq    error15         // no space left in destination
    st      Z+,Accu         // store byte in dest
1:  sbiw    tmp,1           // decrement src size
    brne    copy_string_loop// continue until src size == 0
end_copy_src:
    rjmp    1f
fill_with_zeroes:
    st      Z+,regZero
1:  sub     regL,regOne     // decrement dst size
    sbc     regH,regZero
    brne    fill_with_zeroes
    rjmp    MCodeFETCH
    
error7ter:  rjmp error7
error15:
    ldi     tmp,15
    rjmp    error
    

.global LastAlign
LastAlign:

/* RESERVE, RANGE_CHECK, REAL_ADD, EXT0,EXT4,EXT6,EXT9 :
   beware to RESTORE_BC at end */
