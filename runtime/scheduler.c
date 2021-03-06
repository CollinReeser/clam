#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h> // for sysconf and _SC_NPROCESSOR_ONLIN
#include "scheduler.h"

static GlobalThreadMem* g_threadManager = NULL;
#ifdef MULTITHREAD
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t numCores;
static uint32_t numThreads;
static pthread_t* kernelThreads;
static volatile SchedulerData* schedulerData;
static volatile uint64_t programDone = 0;
#endif

void printThreadData(ThreadData* curThread, int32_t v)
{
    printf("Print Thread Data:\n");
    printf("    ThreadData* curThread %d: %X\n", v, curThread);
    printf("    funcAddr              %d: %X\n", v, curThread->funcAddr);
    printf("    curFuncAddr           %d: %X\n", v, curThread->curFuncAddr);
    printf("    t_StackBot            %d: %X\n", v, curThread->t_StackBot);
    printf("    t_StackCur            %d: %X\n", v, curThread->t_StackCur);
    printf("    t_StackRaw            %d: %X\n", v, curThread->t_StackRaw);
    printf("    t_rbp                 %d: %X\n", v, curThread->t_rbp);
    printf("    stillValid            %d: %u\n", v, curThread->stillValid);
}

void callThreadFunc(ThreadData* thread)
{
    callFunc(thread);
}

void deallocThreadData(ThreadData* thread)
{
    // Unmap memory allocated for thread stack
    munmap(thread->t_StackRaw, THREAD_STACK_SIZE);
    // Dealloc memory for struct
    free(thread);
}

void initThreadManager()
{
    // Alloc space for struct
    g_threadManager = (GlobalThreadMem*)malloc(sizeof(GlobalThreadMem));
    // Alloc initial space for ThreadData* array
    g_threadManager->threadArr =
        (ThreadData**)malloc(sizeof(ThreadData*) * THREAD_DATA_ARR_START_LEN);
    // Init ThreadData* array length tracker
    g_threadManager->threadArrLen = THREAD_DATA_ARR_START_LEN;
    // Init ThreadData* array index tracker
    g_threadManager->threadArrIndex = 0;
}

void takedownThreadManager()
{
    uint32_t i;
    // Loop over all valid ThreadData* and dealloc them
    for (i = 0; i < g_threadManager->threadArrIndex; i++)
    {
        deallocThreadData(g_threadManager->threadArr[i]);
    }
    // Dealloc memory for ThreadData*
    free(g_threadManager->threadArr);
    // Dealloc memory for struct
    free(g_threadManager);
}

void newProc(uint32_t numArgs, void* funcAddr, int8_t* argLens, void* args)
{
    // Alloc new ThreadData
    ThreadData* newThread = (ThreadData*)malloc(sizeof(ThreadData));
    // Init the address of the function this green thread manages
    newThread->funcAddr = funcAddr;
    // Init the instruction position within the function. 0 means the
    // beginning of the function, and curFuncAddr will later take on the
    // role of remembering the eip instruction pointer
    newThread->curFuncAddr = 0;
    // Thread starts off 0, meaning curFuncAddr should also be checked
    // to see if the thread simply hasn't started yet
    newThread->stillValid = 0;
    // Thread starts off with unitialized stack frame pointer
    newThread->t_rbp = 0;
    // mmap thread stack
    newThread->t_StackRaw = (uint8_t*)mmap(NULL, THREAD_STACK_SIZE,
                                           PROT_READ|PROT_WRITE,
                                           MAP_PRIVATE|MAP_ANONYMOUS,
                                           -1, 0);
    // StackCur starts as a meaningless pointer
    newThread->t_StackCur = 0;
    // Make t_StackBot point to "bottom" of stack (highest address)
    newThread->t_StackBot = newThread->t_StackRaw + THREAD_STACK_SIZE;

    // TODO finish putting things on the stack. Note that this is tricky because
    // after the 6th (or 8th, in the case of floats) register is accounted for,
    // arguments are then supposed to appear on the stack backwards, as in
    // the last argument pushed first. So this isn't straightforward. We're
    // probably gonna need to go through the args once to figure out what needs
    // to be on the stack, and then go through them again backwards, actually
    // doing it

    // This is an overallocation for the stack vars
    void* stackVars = malloc(numArgs * 8);
    // 8 * 6 bytes for the int registers, and 8 * 8 bytes for the xmm registers
    void* regVars = malloc((8 * 6) + (8 * 8));
    // Place any int args past the sixth int arg and any float args past the
    // 8th float arg onto the stack
    uint32_t intArgsIndex = 0;
    uint32_t floatArgsIndex = 0;
    uint32_t i = 0;
    uint32_t onStack = 0;
    for (; i < numArgs; i++)
    {
        if (argLens[i] > 0)
        {
            // Put the argument on the stack
            if (intArgsIndex >= 6)
            {
                ((uint64_t*)stackVars)[onStack] = ((uint64_t*)args)[i];
                onStack++;
            }
            // Put the argument in the memory allocated for argument registers
            else
            {
                ((uint64_t*)regVars)[intArgsIndex] = ((uint64_t*)args)[i];
            }
            intArgsIndex++;
        }
        else
        {
            // Put the argument on the stack
            if (floatArgsIndex >= 8)
            {
                ((double*)stackVars)[onStack] = ((double*)args)[i];
                onStack++;
            }
            // Put the argument in the memory allocated for argument registers
            else
            {
                // Jump the pointer forward 48 bytes, past where the int reg
                // stuff goes
                ((double*)regVars + (8 * 6))[floatArgsIndex]
                    = ((double*)args)[i];
            }
            floatArgsIndex++;
        }
    }
    if (onStack > 0)
    {
        for (i = onStack - 1; i >= 0; i--)
        {
            ((uint64_t*)newThread->t_StackBot - i * 8)[0]
                = ((uint64_t*)stackVars)[i];
        }
    }
    free(stackVars);
    newThread->regVars = regVars;
    // Number of bytes allocated for arguments on stack
    newThread->stackArgsSize = onStack * 8;
#ifdef MULTITHREAD
    pthread_mutex_lock(&mutex);
#endif
    // Put newThread into global thread manager, allocating space for the
    // pointer if necessary. Check first if we need to allocate more memory
    if (g_threadManager->threadArrIndex >= g_threadManager->threadArrLen)
    {
        // Allocate more space for thread manager
        g_threadManager->threadArr = (ThreadData**)realloc(
            g_threadManager->threadArr,
            sizeof(ThreadData*) * g_threadManager->threadArrLen *
                THREAD_DATA_ARR_MUL_INCREASE);
        g_threadManager->threadArrLen =
            g_threadManager->threadArrLen * THREAD_DATA_ARR_MUL_INCREASE;
    }
    // Place pointer into ThreadData* array
    g_threadManager->threadArr[g_threadManager->threadArrIndex] = newThread;
    // Increment index
    g_threadManager->threadArrIndex++;
#ifdef MULTITHREAD
    pthread_mutex_unlock(&mutex);
#endif
}

void execScheduler()
{
    // This is a blindingly terrible scheduler
#ifdef MULTITHREAD
    numCores = sysconf(_SC_NPROCESSORS_ONLN);
    numThreads = numCores;
    kernelThreads = (pthread_t*)malloc(numThreads * sizeof(pthread_t));
    schedulerData = (SchedulerData*)malloc(numThreads * sizeof(SchedulerData));
    uint64_t i;
    for (i = 0; i < numThreads; i++)
    {
        schedulerData[i].valid = 0;
        schedulerData[i].threadData = NULL;
        int resCode = pthread_create(
            (kernelThreads + i), NULL, awaitTask, (void*)i
        );
        assert(0 == resCode);
    }
    scheduler();
#else
    uint32_t i = 0;
    uint8_t stillValid = 0;
    for (i = 0; i < g_threadManager->threadArrIndex; i++)
    {
        ThreadData* curThread = g_threadManager->threadArr[i];
        if (curThread->stillValid != 0 || curThread->curFuncAddr == 0)
        {
            stillValid = 1;
            callThreadFunc(curThread);
        }
        if (i + 1 >= g_threadManager->threadArrIndex && stillValid != 0)
        {
            i = -1;
            stillValid = 0;
        }
    }
#endif
}

#ifdef MULTITHREAD
void scheduler()
{
    int64_t i = 0;
    uint8_t stillValid = 0;
    uint64_t kthreadExecuting = 0;
    for (i = 0; i < numThreads; i++)
    {
        if (schedulerData[i].valid != 0)
        {
            kthreadExecuting = i + 1;
            goto SKIP_WORKER;
        }
        if (schedulerData[i].valid == 0 && schedulerData[i].threadData != NULL)
        {
            schedulerData[i].threadData = 0;
        }
        pthread_mutex_lock(&mutex);
        int64_t j = 0;
        for (j = 0; j < g_threadManager->threadArrIndex; j++)
        {
            if (j == 0)
            {
                pthread_mutex_unlock(&mutex);
            }
            ThreadData* curThread = g_threadManager->threadArr[j];
            // Try to find the green thread in the scheduler list
            uint64_t m;
            uint64_t isScheduled = 0;
            for (m = 0; m < numThreads; m++)
            {
                if (curThread == schedulerData[m].threadData)
                {
                    isScheduled++;
                }
            }
            if (isScheduled != 0)
            {
                assert(isScheduled == 1);
                stillValid = 1;
            }
            else if (curThread->stillValid != 0 || curThread->curFuncAddr == 0)
            {
                schedulerData[i].threadData = curThread;
                schedulerData[i].valid = 1;
                stillValid = 1;
                // We've scheduled a gthread for this worker thread
                break;
            }
        }
SKIP_WORKER:
        // At least one worker thread is still executing
        if (i + 1 >= numThreads)
        {
            if (kthreadExecuting != 0)
            {
                kthreadExecuting = 0;
                i = -1;
            }
            else if (stillValid != 0)
            {
                stillValid = 0;
                i = -1;
            }
        }
    }
    programDone = 1;
    for (i = 0; i < numThreads; i++)
    {
        pthread_join(kernelThreads[i], NULL);
    }
}

void* awaitTask(void* arg)
{
    uint64_t index = (uint64_t)arg;
    while (programDone == 0)
    {
        if (schedulerData[index].valid == 1)
        {
            ThreadData* curThread = schedulerData[index].threadData;
            callThreadFunc(curThread);
            schedulerData[index].valid = 0;
        }
    }
    return NULL;
}
#endif
