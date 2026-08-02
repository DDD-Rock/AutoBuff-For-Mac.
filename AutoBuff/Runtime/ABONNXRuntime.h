#ifndef ABONNXRuntime_h
#define ABONNXRuntime_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *ABONNXSessionRef;

typedef struct {
    float *values;
    int64_t *dimensions;
    size_t dimensionCount;
    size_t valueCount;
} ABONNXOutput;

ABONNXSessionRef ABONNXCreateSession(
    const char *modelPath,
    char *errorMessage,
    size_t errorMessageCapacity
);

int ABONNXRun(
    ABONNXSessionRef session,
    float *inputValues,
    const int64_t *inputDimensions,
    size_t inputDimensionCount,
    ABONNXOutput *output,
    char *errorMessage,
    size_t errorMessageCapacity
);

void ABONNXFreeOutput(ABONNXOutput *output);
void ABONNXReleaseSession(ABONNXSessionRef session);

#ifdef __cplusplus
}
#endif

#endif
