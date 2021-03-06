#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#include "stdio.h"
#include "clam_internal.h"

// Get the power-of-2 size larger than the input size, for use in array size
// allocations. Arrays are always a power-of-2 in size.
// Credit: Henry S. Warren, Jr.'s "Hacker's Delight.", and Larry Gritz from
// http://stackoverflow.com/questions/364985/algorithm-for-finding-the-smallest-power-of-two-thats-greater-or-equal-to-a-giv
unsigned long long getAllocSize(unsigned long long x)
{
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x |= x >> 32;
    return x+1;
}

void writeln(void* clamStr)
{
    printf("%s\n", (char*)(clamStr + STR_START_OFFSET));
}

void write(void* clamStr)
{
    printf("%s", (char*)(clamStr + STR_START_OFFSET));
}

struct MaybeFile* clam_fopen(void* str, struct FopenMode* mode)
{
    // Allocate space for a Maybe!File, which needs space for the ref-count, the
    // variant tag and space for the File ref in Some (File)
    struct MaybeFile* maybeFile =
        (struct MaybeFile*)malloc(sizeof(struct MaybeFile));
    FILE* file;
    switch (mode->mode)
    {
    case 0: file = fopen(str + STR_START_OFFSET, "r");  break;
    case 1: file = fopen(str + STR_START_OFFSET, "w");  break;
    case 2: file = fopen(str + STR_START_OFFSET, "a");  break;
    case 3: file = fopen(str + STR_START_OFFSET, "r+"); break;
    case 4: file = fopen(str + STR_START_OFFSET, "w+"); break;
    case 5: file = fopen(str + STR_START_OFFSET, "a+"); break;
    default:
        // It is a programming error to get here, as we are switching on the
        // possible variant tags
        assert(0);
    }
    if (file != NULL)
    {
        struct ClamFile* fileRef = (struct ClamFile*)
                                   malloc(sizeof(struct ClamFile));
        fileRef->refCount = 1;
        fileRef->openMode = mode->mode;
        fileRef->ptr = file;
        fileRef->isOpen = 1;
        // Set tag to Some
        maybeFile->variantTag = 0;
        // The File ref lives just after the variant tag, which is four bytes
        maybeFile->ptr = fileRef;
    }
    else
    {
        // Set tag to None
        maybeFile->variantTag = 1;
    }
    // Set ref-count to 0
    maybeFile->refCount = 0;
    return maybeFile;
}

void clam_fclose(struct ClamFile* file)
{
    if (file->isOpen)
    {
        fclose(file->ptr);
        file->isOpen = 0;
    }
}

struct MaybeStr* clam_freadln(struct ClamFile* file)
{
    struct MaybeStr* str = (struct MaybeStr*)malloc(sizeof(struct MaybeStr));
    str->refCount = 0;
    if (file->isOpen)
    {
        char* buffer = NULL;
        size_t linesize = 0;
        ssize_t bytesRead = getline(&buffer, &linesize, file->ptr);
        // Check if we outright failed to read a line, ie, EOF
        if (bytesRead == -1)
        {
            // Set tag to None
            str->variantTag = 1;
        }
        else
        {
            // Set tag to Some
            str->variantTag = 0;
            // Clam strings have power-of-2 space allocated for the characters
            // in the string, not including the null byte
            uint32_t allocSize = getAllocSize(bytesRead);
            // The 1 is for space for the null byte
            void* clamStr = malloc(
                REF_COUNT_SIZE + CLAM_STR_SIZE + allocSize + 1
            );
            // Set the ref count
            ((uint32_t*)clamStr)[0] = 1;
            // Set the string length
            ((uint32_t*)clamStr)[1] = bytesRead;
            memcpy(clamStr + STR_START_OFFSET, buffer, bytesRead + 1);
            str->str = clamStr;
        }
    }
    else
    {
        // Set tag to None
        str->variantTag = 1;
    }
    return str;
}
