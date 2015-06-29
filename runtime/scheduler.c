#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <stddef.h>
#include <sys/mman.h>

#include <execinfo.h>
#include <signal.h>

#include <unistd.h> // for sysconf and _SC_NPROCESSOR_ONLIN
#include "scheduler.h"

static GlobalThreadMem* g_threadManager = NULL;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t numCores;
static uint32_t numThreads;
static pthread_t* kernelThreads;
static volatile SchedulerData* schedulerData;
static volatile uint64_t programDone = 0;
__thread uint64_t mainstack;
__thread uint64_t currentthread;


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
    printf("    isExecuting           %d: %u\n", v, curThread->isExecuting);
}

void callThreadFunc(ThreadData* thread, uint32_t index)
{
    callFunc(thread, schedulerData, index);
}

void deallocThreadData(ThreadData* thread)
{
    // Unmap memory allocated for thread stack
    munmap(thread->t_StackRaw, THREAD_STACK_SIZE);
    // Dealloc memory for struct
    free(thread);
    thread = 0;
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
    g_threadManager = 0;
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
    // Set newThread to not be currently executing
    newThread->isExecuting = 0;
    pthread_mutex_lock(&mutex);
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
    pthread_mutex_unlock(&mutex);
}

void execScheduler()
{

    printf("sizeof            : %d\n", sizeof(SchedulerData));
    printf("valid offset      : %d\n", offsetof(SchedulerData, valid));
    printf("isExecuting offset: %d\n", offsetof(ThreadData, isExecuting));

    numCores = sysconf(_SC_NPROCESSORS_ONLN);
    numThreads = numCores;
    kernelThreads = (pthread_t*)malloc(numThreads * sizeof(pthread_t));
    schedulerData = (SchedulerData*)malloc(numThreads * sizeof(SchedulerData));
    unsigned long i;
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
}

void handler(int sig) {
    void *array[10];
    size_t size;

    // get void*'s for all entries on the stack
    size = backtrace(array, 10);

    // print out all the frames to stderr
    fprintf(stderr, "Error: signal %d:\n", sig);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
    exit(1);
}


void scheduler()
{

    signal(SIGSEGV, handler);

    // This is a blindingly terrible scheduler
    uint32_t i = 0;
    uint8_t stillValid = 0;
    uint32_t gthreadIndex = g_threadManager->threadArrIndex;
    for (i = 0; i < gthreadIndex; i++)
    {

        printf("TAI: %d\n", gthreadIndex);
        // printf("Begin %d: ", i);
        // for (k = 0; k < numThreads; k++)
        // {
        //     printf("%d", schedulerData[k].valid);
        // }
        // printf("\n");

        pthread_mutex_lock(&mutex);

        printf("Reading from thread manager: %d of 0:%d (%d)\n", i, (gthreadIndex-1), (g_threadManager->threadArrIndex-1));

        usleep(1);
        ThreadData* curThread = g_threadManager->threadArr[i];
        uint8_t threadStillValid = curThread->stillValid;
        void* threadCurFuncAddr = curThread->curFuncAddr;
        uint8_t threadIsExecuting = curThread->isExecuting;

        printf("Read from thread manager!\n");
        printThreadData(curThread, i);

        pthread_mutex_unlock(&mutex);
        if (threadStillValid != 0 || threadCurFuncAddr == NULL)
        {

            // Debugging: We get here, because the worker thread has not yet
            // started executing the green thread, so curFuncAddr is 0. We
            // rely on isExecuting to be 1, but, in the space of time it takes
            // to make that check, the worker thread finished the green thread,
            // and sets isExecuting to 0. So even though curFuncAddr != 0, and
            // stillValid == 0, isExecuting is 0, so here we are!

            printf("Found GT to check: %d\n", i);
            if (threadIsExecuting == 0)
            {
                printf("Found GT to exec: %d\n", i);
                // Find a worker thread to exec this green thread
                uint32_t j = 0;
                // Find a worker thread that is idling
                while (1)
                {
                    if (schedulerData[j].valid == 0)
                    {

                        printf("Found KT to exec: %d\n", j);

                        curThread->isExecuting = 1;

                        printThreadData(curThread, i);

                        // Place the green thread info in a worker thread
                        // mailbox
                        schedulerData[j].threadData = curThread;
                        schedulerData[j].valid = 1;
                        break;
                    }
                    j++;
                    if (j >= numThreads)
                    {
                        j = 0;
                        usleep(1);
                    }
                }
            }
            stillValid = 1;
        }
        else if (curThread->isExecuting == 1)
        {
            stillValid = 1;
        }

        uint32_t newIndex = g_threadManager->threadArrIndex;
        if (newIndex != gthreadIndex)
        {
            gthreadIndex = newIndex;
            stillValid = 1;
        }

        printf("i: [%d], gthreadIndex: [%d], stillValid: [%d]\n",
            i, gthreadIndex, stillValid
        );

        if (i + 1 >= gthreadIndex)
        {
            if (stillValid == 0)
            {
                printf("Breaking from main scheduler loop!\n");
                break;
            }
            else
            {
                printf("Scheduler looping at max index...\n");
                i = -1;
                stillValid = 0;
            }
        }

        // usleep(1);

    }
    printf("Scheduler exiting...\n");
    programDone = 1;
    for (i = 0; i < numThreads; i++)
    {
        pthread_join(kernelThreads[i], NULL);
    }
}

void* awaitTask(void* arg)
{
    signal(SIGSEGV, handler);
    uint32_t index = (uint32_t)(uint64_t)arg;
    while (1)
    {
        while (schedulerData[index].valid != 1)
        {
            printf("Thread %d inner-looping... 0\n", index);
            if (programDone == 1)
            {
                printf("GOTO'ing!\n");
                goto TERM_THREAD;
            }
            printf("Thread %d inner-looping... 1\n", index);
            usleep(1);
        }
        ThreadData* threadData = schedulerData[index].threadData;
        printf("Setting valid to 0: %d\n", index);
        schedulerData[index].valid = 0;

        printf("About to call into green thread! %d\n", index);
        printThreadData(threadData, index);

        callThreadFunc(threadData, index);

        printf("Returned from green thread call! %d\n", index);

        pthread_mutex_lock(&mutex);
        threadData->isExecuting = 0;
        printThreadData(threadData, index);
        pthread_mutex_unlock(&mutex);


    }
TERM_THREAD:
    return NULL;
}
