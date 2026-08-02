#include "ABONNXRuntime.h"

#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wstrict-prototypes"
#include "onnxruntime_c_api.h"
#pragma clang diagnostic pop

typedef struct {
    const OrtApi *api;
    OrtEnv *environment;
    OrtSessionOptions *options;
    OrtSession *session;
    OrtMemoryInfo *memoryInfo;
    OrtAllocator *allocator;
    char *inputName;
    char *outputName;
} ABONNXSession;

static void ABSetError(
    const char *message,
    char *destination,
    size_t capacity
) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    const char *source = message != NULL ? message : "Unknown ONNX Runtime error";
    size_t length = strlen(source);
    if (length >= capacity) {
        length = capacity - 1;
    }
    memcpy(destination, source, length);
    destination[length] = '\0';
}

static int ABCheckStatus(
    ABONNXSession *session,
    OrtStatus *status,
    char *errorMessage,
    size_t errorMessageCapacity
) {
    if (status == NULL) {
        return 1;
    }
    ABSetError(
        session->api->GetErrorMessage(status),
        errorMessage,
        errorMessageCapacity
    );
    session->api->ReleaseStatus(status);
    return 0;
}

void ABONNXReleaseSession(ABONNXSessionRef sessionReference) {
    ABONNXSession *session = (ABONNXSession *)sessionReference;
    if (session == NULL) {
        return;
    }
    if (session->allocator != NULL) {
        if (session->inputName != NULL) {
            session->allocator->Free(session->allocator, session->inputName);
        }
        if (session->outputName != NULL) {
            session->allocator->Free(session->allocator, session->outputName);
        }
    }
    if (session->api != NULL) {
        if (session->memoryInfo != NULL) {
            session->api->ReleaseMemoryInfo(session->memoryInfo);
        }
        if (session->session != NULL) {
            session->api->ReleaseSession(session->session);
        }
        if (session->options != NULL) {
            session->api->ReleaseSessionOptions(session->options);
        }
        if (session->environment != NULL) {
            session->api->ReleaseEnv(session->environment);
        }
    }
    free(session);
}

ABONNXSessionRef ABONNXCreateSession(
    const char *modelPath,
    char *errorMessage,
    size_t errorMessageCapacity
) {
    if (modelPath == NULL) {
        ABSetError("Missing ONNX model path", errorMessage, errorMessageCapacity);
        return NULL;
    }

    ABONNXSession *session = (ABONNXSession *)calloc(1, sizeof(ABONNXSession));
    if (session == NULL) {
        ABSetError("Unable to allocate ONNX session", errorMessage, errorMessageCapacity);
        return NULL;
    }
    session->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (session->api == NULL) {
        ABSetError("Unsupported ONNX Runtime API version", errorMessage, errorMessageCapacity);
        ABONNXReleaseSession(session);
        return NULL;
    }

    if (!ABCheckStatus(
        session,
        session->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "AutoBuffOCR", &session->environment),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->CreateSessionOptions(&session->options),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->SetSessionGraphOptimizationLevel(session->options, ORT_ENABLE_ALL),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->SetIntraOpNumThreads(session->options, 2),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->SetInterOpNumThreads(session->options, 1),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->CreateSession(
            session->environment,
            modelPath,
            session->options,
            &session->session
        ),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->GetAllocatorWithDefaultOptions(&session->allocator),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->SessionGetInputName(
            session->session,
            0,
            session->allocator,
            &session->inputName
        ),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->SessionGetOutputName(
            session->session,
            0,
            session->allocator,
            &session->outputName
        ),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->CreateCpuMemoryInfo(
            OrtArenaAllocator,
            OrtMemTypeDefault,
            &session->memoryInfo
        ),
        errorMessage,
        errorMessageCapacity
    )) {
        ABONNXReleaseSession(session);
        return NULL;
    }

    return session;
}

int ABONNXRun(
    ABONNXSessionRef sessionReference,
    float *inputValues,
    const int64_t *inputDimensions,
    size_t inputDimensionCount,
    ABONNXOutput *output,
    char *errorMessage,
    size_t errorMessageCapacity
) {
    ABONNXSession *session = (ABONNXSession *)sessionReference;
    if (session == NULL || inputValues == NULL || inputDimensions == NULL ||
        inputDimensionCount == 0 || output == NULL) {
        ABSetError("Invalid ONNX inference arguments", errorMessage, errorMessageCapacity);
        return 0;
    }
    memset(output, 0, sizeof(ABONNXOutput));

    size_t inputValueCount = 1;
    for (size_t index = 0; index < inputDimensionCount; index++) {
        if (inputDimensions[index] <= 0 ||
            inputValueCount > SIZE_MAX / (size_t)inputDimensions[index]) {
            ABSetError("Invalid ONNX input dimensions", errorMessage, errorMessageCapacity);
            return 0;
        }
        inputValueCount *= (size_t)inputDimensions[index];
    }

    OrtValue *inputTensor = NULL;
    OrtValue *outputTensor = NULL;
    OrtTensorTypeAndShapeInfo *shapeInfo = NULL;
    int success = 0;

    if (!ABCheckStatus(
        session,
        session->api->CreateTensorWithDataAsOrtValue(
            session->memoryInfo,
            inputValues,
            inputValueCount * sizeof(float),
            inputDimensions,
            inputDimensionCount,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &inputTensor
        ),
        errorMessage,
        errorMessageCapacity
    )) {
        goto cleanup;
    }

    const char *inputNames[] = {session->inputName};
    const char *outputNames[] = {session->outputName};
    const OrtValue *inputs[] = {inputTensor};
    if (!ABCheckStatus(
        session,
        session->api->Run(
            session->session,
            NULL,
            inputNames,
            inputs,
            1,
            outputNames,
            1,
            &outputTensor
        ),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->GetTensorTypeAndShape(outputTensor, &shapeInfo),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->GetDimensionsCount(shapeInfo, &output->dimensionCount),
        errorMessage,
        errorMessageCapacity
    ) || !ABCheckStatus(
        session,
        session->api->GetTensorShapeElementCount(shapeInfo, &output->valueCount),
        errorMessage,
        errorMessageCapacity
    )) {
        goto cleanup;
    }

    output->dimensions = (int64_t *)malloc(output->dimensionCount * sizeof(int64_t));
    output->values = (float *)malloc(output->valueCount * sizeof(float));
    if (output->dimensions == NULL || output->values == NULL) {
        ABSetError("Unable to allocate ONNX output", errorMessage, errorMessageCapacity);
        goto cleanup;
    }
    if (!ABCheckStatus(
        session,
        session->api->GetDimensions(
            shapeInfo,
            output->dimensions,
            output->dimensionCount
        ),
        errorMessage,
        errorMessageCapacity
    )) {
        goto cleanup;
    }
    void *rawOutput = NULL;
    if (!ABCheckStatus(
        session,
        session->api->GetTensorMutableData(outputTensor, &rawOutput),
        errorMessage,
        errorMessageCapacity
    )) {
        goto cleanup;
    }
    memcpy(output->values, rawOutput, output->valueCount * sizeof(float));
    success = 1;

cleanup:
    if (shapeInfo != NULL) {
        session->api->ReleaseTensorTypeAndShapeInfo(shapeInfo);
    }
    if (outputTensor != NULL) {
        session->api->ReleaseValue(outputTensor);
    }
    if (inputTensor != NULL) {
        session->api->ReleaseValue(inputTensor);
    }
    if (!success) {
        ABONNXFreeOutput(output);
    }
    return success;
}

void ABONNXFreeOutput(ABONNXOutput *output) {
    if (output == NULL) {
        return;
    }
    free(output->values);
    free(output->dimensions);
    memset(output, 0, sizeof(ABONNXOutput));
}
