
    SECTION .bss

mainstack:      resq 1 ; Stored mainstack rsp
currentthread:  resq 1 ; Pointer to current thread
schedulerdata:  resq 1 ; Pointer to current worker thread SchedulerData

    SECTION .text

    ; extern void yield();
    global yield
yield:
    ; Note that we have not set up the normal stack frame, so [rsp] is the the
    ; return address on the stack, and rbp is whatever it is from the function
    ; that called yield()

    ; Set worker thread to non-executing
    add     r10, qword [schedulerdata]
    add     r10, 8
    mov     byte [r10], 0
    ; Get curThread pointer
    mov     rdx, qword [currentthread]
    ; Get return address
    mov     rax, [rsp]
    ; Pop return address off the stack
    add     rsp, 8
    ; Set validity of thread
    mov     byte [rdx+48], 1 ; ThreadData->stillValid
    ; Set return address to continue execution
    mov     [rdx+8], rax  ; ThreadData->curFuncAddr
    ; Set curThread StackCur value, now that rsp is pointing to the top of
    ; the stack of the function that just yielded
    mov     [rdx+24], rsp   ; ThreadData->t_StackCur
    ; Save rbp for thread
    mov     [rdx+40], rbp ; ThreadData->t_rbp

    jmp     schedulerReturn


    ; extern void callFunc(ThreadData*, SchedulerData* data, uint32_t index);
    global callFunc
callFunc:
    push    rbp                     ; set up stack frame
    mov     rbp, rsp

    ; Have r10 point to the address of data[index].valid
    mov     r10, rsi            ; Do all the work in r10
    imul    rdx, 9              ; sizeof(SchedulerData)
    add     r10, rdx            ; r10 now points to data[index]
    mov     qword [schedulerdata], r10 ; Store in case of a yield
    add     r10, 8              ; r10 now points to data[index].valid
    ; Set data[index].valid to 0, telling the scheduler it can now assign new
    ; work to this worker thread (while it actually performs _this_ work)
    mov     byte [r10], 0

    ; Populate registers for operation. ThreadData* thread is initially in rdi
    mov     rcx, rdi            ; ThreadData* thread
    xor     rdi, rdi
    mov     edi, dword [rcx+52] ; ThreadData->stackArgsSize
    mov     r11, qword [rcx]    ; ThreadData->funcAddr
    mov     rdx, qword [rcx+16] ; ThreadData->t_StackBot
    mov     rax, qword [rcx+56] ; ThreadData->regVars
    ; First set the currentthread value
    mov     qword [currentthread], rcx ; ThreadData* thread

    ; Determine if we are starting a new thread, or if we're continuing
    ; execution
    mov     r8, qword [rcx+8] ; ThreadData->curFuncAddr (0 if start of thread)
    test    r8, r8
    ; If not zero, then continue where we left off
    jne     continueThread

    ; If we get here, we're starting the execution of a new thread

    mov     qword [rcx+8], r11  ; ThreadData->curFuncAddr, init to start of func

    ; Set stack pointer to be before arguments
    sub     rdx, rdi            ; Note that we're using the value in edi here
    ; Allocate 8 bytes on stack for return address
    sub     rdx, 8
    mov     qword [rdx], schedulerReturn

    ; Store the value of the main stack pointer, and store rbp as top value
    push    rbp
    mov     qword [mainstack], rsp
    mov     rsp, rdx

    ; Move the register function arguments into the relevant registers
    mov     rdi, qword [rax]
    mov     rsi, qword [rax+8]
    mov     rdx, qword [rax+16]
    mov     rcx, qword [rax+24]
    mov     r8, qword [rax+32]
    mov     r9, qword [rax+40]
    movsd   xmm0, qword [rax+48]
    movsd   xmm1, qword [rax+56]
    movsd   xmm2, qword [rax+64]
    movsd   xmm3, qword [rax+72]
    movsd   xmm4, qword [rax+80]
    movsd   xmm5, qword [rax+88]
    movsd   xmm6, qword [rax+96]
    movsd   xmm7, qword [rax+104]

    jmp     r11                     ; Call function


continueThread:
    ; ThreadData* thread is in rcx
    ; In order to restart execution, we need to set rsp to correct value,
    ; and then "return" to the previous stage of execution. As part of setting
    ; up for a clean return, push rbp as the last thing on the mainstack
    push    rbp
    ; Save mainstack rsp
    mov     qword [mainstack], rsp
    ; Set rsp to StackCur of current thread
    mov     rsp, qword [rcx+24] ; ThreadData->t_StackCur
    ; Set rbp to t_rbp of current thread
    mov     rbp, qword [rcx+40] ; ThreadData->t_rbp
    ; Set stillValid to 0, to account for possibly naturally returning from
    ; the function at the end of its execution. A thread is still valid if
    ; stillValid != 0 OR curFuncAddr == 0 (meaning thread hasn't started yet)
    mov     byte [rcx+48], 0    ; ThreadData->stillValid
    ; Get "return" address to return to thread execution point
    mov     rcx, qword [rcx+8] ; ThreadData->curFuncAddr
    ; Jump back into function
    jmp     rcx


schedulerReturn:
    ; Restore the value of the main stack pointer
    mov     rsp, qword [mainstack]
    ; Restore current rbp
    pop     rbp

    mov     rsp, rbp                ; takedown stack frame
    pop     rbp
    ret
