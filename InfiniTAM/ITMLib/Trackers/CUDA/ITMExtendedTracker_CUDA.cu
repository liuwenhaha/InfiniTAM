// Copyright 2014-2015 Isis Innovation Limited and the authors of InfiniTAM

#include "ITMExtendedTracker_CUDA.h"
#include "../../Utils/ITMCUDAUtils.h"
#include "../Shared/ITMExtendedTracker_Shared.h"
#include "../../../ORUtils/CUDADefines.h"

using namespace ITMLib;

struct ITMExtendedTracker_CUDA::AccuCell {
	int numPoints;
	float f;
	float g[6];
	float h[6+5+4+3+2+1];
};

struct ITMExtendedTracker_KernelParameters_Depth {
	ITMExtendedTracker_CUDA::AccuCell *accu;
	float *depth;
	Matrix4f approxInvPose;
	Vector4f *pointsMap;
	Vector4f *normalsMap;
	Vector4f sceneIntrinsics;
	Vector2i sceneImageSize;
	Matrix4f scenePose;
	Vector4f viewIntrinsics;
	Vector2i viewImageSize;
	float spaceThresh;
	float viewFrustum_min, viewFrustum_max;
	int tukeyCutOff, framesToSkip, framesToWeight;
};

struct ITMExtendedTracker_KernelParameters_RGB {
	ITMExtendedTracker_CUDA::AccuCell *accu;
	Vector4f *pointsMap;
	Vector4s *gx;
	Vector4s *gy;
	Vector4u *rgb_live;
	Vector4f *rgb_model;
	Vector2i viewImageSize;
	Vector2i sceneImageSize;
	Matrix4f approxInvPose;
	Matrix4f approxPose;
	Matrix4f scenePose;
	Vector4f projParams;
};

template<bool shortIteration, bool rotationOnly, bool useWeights>
__global__ void exDepthTrackerOneLevel_g_rt_device(ITMExtendedTracker_KernelParameters_Depth para);

template<bool shortIteration, bool rotationOnly, bool useWeights>
__global__ void exRGBTrackerOneLevel_g_rt_device(ITMExtendedTracker_KernelParameters_RGB para);

__global__ void exRGBTrackerProjectPrevImage_device(Vector4f *out_rgb, Vector4u *in_rgb, Vector4f *in_points, Vector2i imageSize, Vector2i sceneSize, Vector4f intrinsics, Matrix4f scenePose);

// host methods

ITMExtendedTracker_CUDA::ITMExtendedTracker_CUDA(Vector2i imgSize_d, Vector2i imgSize_rgb, bool useDepth, bool useColour,
	float colourWeight, TrackerIterationType *trackingRegime, int noHierarchyLevels,
	float terminationThreshold, float failureDetectorThreshold, float viewFrustum_min, float viewFrustum_max, int tukeyCutOff, int framesToSkip, int framesToWeight,
	const ITMLowLevelEngine *lowLevelEngine)
	: ITMExtendedTracker(imgSize_d, imgSize_rgb, useDepth, useColour, colourWeight, trackingRegime, noHierarchyLevels, terminationThreshold, failureDetectorThreshold, viewFrustum_min, viewFrustum_max,
	tukeyCutOff, framesToSkip, framesToWeight, lowLevelEngine, MEMORYDEVICE_CUDA)
{
	ORcudaSafeCall(cudaMallocHost((void**)&accu_host, sizeof(AccuCell)));
	ORcudaSafeCall(cudaMalloc((void**)&accu_device, sizeof(AccuCell)));
}

ITMExtendedTracker_CUDA::~ITMExtendedTracker_CUDA(void)
{
	ORcudaSafeCall(cudaFreeHost(accu_host));
	ORcudaSafeCall(cudaFree(accu_device));
}

int ITMExtendedTracker_CUDA::ComputeGandH_Depth(float &f, float *nabla, float *hessian, Matrix4f approxInvPose)
{
	Vector2i sceneImageSize = sceneHierarchyLevel_Depth->pointsMap->noDims;
	Vector2i viewImageSize = viewHierarchyLevel_Depth->depth->noDims;

	if (iterationType == TRACKER_ITERATION_NONE) return 0;

	bool shortIteration = (iterationType == TRACKER_ITERATION_ROTATION) || (iterationType == TRACKER_ITERATION_TRANSLATION);

	int noPara = shortIteration ? 3 : 6;

	dim3 blockSize(16, 16);
	dim3 gridSize((int)ceil((float)viewImageSize.x / (float)blockSize.x), (int)ceil((float)viewImageSize.y / (float)blockSize.y));

	ORcudaSafeCall(cudaMemset(accu_device, 0, sizeof(AccuCell)));

	struct ITMExtendedTracker_KernelParameters_Depth args;
	args.accu = accu_device;
	args.depth = viewHierarchyLevel_Depth->depth->GetData(MEMORYDEVICE_CUDA);
	args.approxInvPose = approxInvPose;
	args.pointsMap = sceneHierarchyLevel_Depth->pointsMap->GetData(MEMORYDEVICE_CUDA);
	args.normalsMap = sceneHierarchyLevel_Depth->normalsMap->GetData(MEMORYDEVICE_CUDA);
	args.sceneIntrinsics = sceneHierarchyLevel_Depth->intrinsics;
	args.sceneImageSize = sceneImageSize;
	args.scenePose = scenePose;
	args.viewIntrinsics = viewHierarchyLevel_Depth->intrinsics;
	args.viewImageSize = viewHierarchyLevel_Depth->depth->noDims;
	args.spaceThresh = spaceThresh[levelId];
	args.viewFrustum_min = viewFrustum_min;
	args.viewFrustum_max = viewFrustum_max;
	args.tukeyCutOff = tukeyCutOff;
	args.framesToSkip = framesToSkip;
	args.framesToWeight = framesToWeight;

	//printf("%f %f\n", viewFrustum_min, viewFrustum_max);

	if (currentFrameNo < 100)
	{
		switch (iterationType)
		{
		case TRACKER_ITERATION_ROTATION:
			exDepthTrackerOneLevel_g_rt_device<true, true, false> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		case TRACKER_ITERATION_TRANSLATION:
			exDepthTrackerOneLevel_g_rt_device<true, false, false> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		case TRACKER_ITERATION_BOTH:
			exDepthTrackerOneLevel_g_rt_device<false, false, false> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		default: break;
		}
	}
	else
	{
		switch (iterationType)
		{
		case TRACKER_ITERATION_ROTATION:
			exDepthTrackerOneLevel_g_rt_device<true, true, true> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		case TRACKER_ITERATION_TRANSLATION:
			exDepthTrackerOneLevel_g_rt_device<true, false, true> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		case TRACKER_ITERATION_BOTH:
			exDepthTrackerOneLevel_g_rt_device<false, false, true> << <gridSize, blockSize >> >(args);
			ORcudaKernelCheck;
			break;
		default: break;
		}
	}

	ORcudaSafeCall(cudaMemcpy(accu_host, accu_device, sizeof(AccuCell), cudaMemcpyDeviceToHost));

	for (int r = 0, counter = 0; r < noPara; r++) for (int c = 0; c <= r; c++, counter++) hessian[r + c * 6] = accu_host->h[counter];
	for (int r = 0; r < noPara; ++r) for (int c = r + 1; c < noPara; c++) hessian[r + c * 6] = hessian[c + r * 6];

	memcpy(nabla, accu_host->g, noPara * sizeof(float));
	f = (accu_host->numPoints > 100) ? accu_host->f / accu_host->numPoints : 1e5f;

	return accu_host->numPoints;
}

int ITMExtendedTracker_CUDA::ComputeGandH_RGB(float &f, float *nabla, float *hessian, Matrix4f approxInvPose)
{
	Vector2i sceneImageSize = sceneHierarchyLevel_RGB->pointsMap->noDims;
	Vector2i viewImageSize = viewHierarchyLevel_RGB->rgb_current->noDims;

	if (iterationType == TRACKER_ITERATION_NONE) return 0;

	Matrix4f approxPose;
	approxInvPose.inv(approxPose);
	approxPose = depthToRGBTransform * approxPose;

	bool shortIteration = (iterationType == TRACKER_ITERATION_ROTATION) || (iterationType == TRACKER_ITERATION_TRANSLATION);

	int noPara = shortIteration ? 3 : 6;

	dim3 blockSize(16, 16);
	dim3 gridSize((int)ceil((float)sceneImageSize.x / (float)blockSize.x), (int)ceil((float)sceneImageSize.y / (float)blockSize.y));

	ORcudaSafeCall(cudaMemset(accu_device, 0, sizeof(AccuCell)));

	struct ITMExtendedTracker_KernelParameters_RGB args;
	args.accu = accu_device;
	args.rgb_live = viewHierarchyLevel_RGB->rgb_current->GetData(MEMORYDEVICE_CUDA);
	args.rgb_model = previousProjectedRGBLevel->depth->GetData(MEMORYDEVICE_CUDA);
	args.gx = viewHierarchyLevel_RGB->gX->GetData(MEMORYDEVICE_CUDA);
	args.gy = viewHierarchyLevel_RGB->gY->GetData(MEMORYDEVICE_CUDA);
	args.pointsMap = sceneHierarchyLevel_RGB->pointsMap->GetData(MEMORYDEVICE_CUDA);
	args.viewImageSize = viewImageSize;
	args.sceneImageSize = sceneImageSize;
	args.approxInvPose = approxInvPose;
	args.approxPose = approxPose;
	args.scenePose = scenePose;
	args.projParams = viewHierarchyLevel_RGB->intrinsics;

	switch (iterationType)
	{
	case TRACKER_ITERATION_ROTATION:
		exRGBTrackerOneLevel_g_rt_device<true, true, false> << <gridSize, blockSize >> >(args);
		ORcudaKernelCheck;
		break;
	case TRACKER_ITERATION_TRANSLATION:
		exRGBTrackerOneLevel_g_rt_device<true, false, false> << <gridSize, blockSize >> >(args);
		ORcudaKernelCheck;
		break;
	case TRACKER_ITERATION_BOTH:
		exRGBTrackerOneLevel_g_rt_device<false, false, false> << <gridSize, blockSize >> >(args);
		ORcudaKernelCheck;
		break;
	default: break;
	}

	ORcudaSafeCall(cudaMemcpy(accu_host, accu_device, sizeof(AccuCell), cudaMemcpyDeviceToHost));

	for (int r = 0, counter = 0; r < noPara; r++) for (int c = 0; c <= r; c++, counter++) hessian[r + c * 6] = accu_host->h[counter];
	for (int r = 0; r < noPara; ++r) for (int c = r + 1; c < noPara; c++) hessian[r + c * 6] = hessian[c + r * 6];

	memcpy(nabla, accu_host->g, noPara * sizeof(float));
	f = (accu_host->numPoints > 100) ? accu_host->f / accu_host->numPoints : 1e5f;

	return accu_host->numPoints;
}

void ITMExtendedTracker_CUDA::ProjectPreviousRGBFrame(const Matrix4f &scenePose)
{
	Vector2i imageSize = viewHierarchyLevel_RGB->rgb_prev->noDims;
	Vector2i sceneSize = sceneHierarchyLevel_RGB->pointsMap->noDims;

	previousProjectedRGBLevel->depth->ChangeDims(sceneSize);

	Vector4f projParams = viewHierarchyLevel_RGB->intrinsics;
	Vector4f *pointsMap = sceneHierarchyLevel_RGB->pointsMap->GetData(MEMORYDEVICE_CUDA);
	Vector4u *rgbIn = viewHierarchyLevel_RGB->rgb_prev->GetData(MEMORYDEVICE_CUDA);
	Vector4f *rgbOut = previousProjectedRGBLevel->depth->GetData(MEMORYDEVICE_CUDA);

	dim3 blockSize(16, 16);
	dim3 gridSize((int)ceil((float)sceneSize.x / (float)blockSize.x), (int)ceil((float)sceneSize.y / (float)blockSize.y));

	exRGBTrackerProjectPrevImage_device<<<gridSize, blockSize>>>(rgbOut, rgbIn, pointsMap, imageSize, sceneSize, projParams, scenePose);
	ORcudaKernelCheck;
}

// device functions

// huber norm

__device__ float rho(float r, float huber_b)
{
	float tmp = fabs(r) - huber_b;
	tmp = MAX(tmp, 0.0f);
	return r*r - tmp*tmp;
}

__device__ float rho_deriv(float r, float huber_b)
{
	return 2.0f * CLAMP(r, -huber_b, huber_b);
}

__device__ float rho_deriv2(float r, float huber_b)
{
	if (fabs(r) < huber_b) return 2.0f;
	return 0.0f;
}

template<bool shortIteration, bool rotationOnly, bool useWeights>
__device__ void exDepthTrackerOneLevel_g_rt_device_main(ITMExtendedTracker_CUDA::AccuCell *accu, float *depth,
	Matrix4f approxInvPose, Vector4f *pointsMap, Vector4f *normalsMap, Vector4f sceneIntrinsics, Vector2i sceneImageSize, Matrix4f scenePose,
	Vector4f viewIntrinsics, Vector2i viewImageSize, float spaceThresh, float viewFrustum_min, float viewFrustum_max,
	int tukeyCutOff, int framesToSkip, int framesToWeight)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x, y = threadIdx.y + blockIdx.y * blockDim.y;

	int locId_local = threadIdx.x + threadIdx.y * blockDim.x;

	__shared__ float dim_shared1[256];
	__shared__ float dim_shared2[256];
	__shared__ float dim_shared3[256];
	__shared__ bool should_prefix;

	should_prefix = false;
	__syncthreads();

	const int noPara = shortIteration ? 3 : 6;
	const int noParaSQ = shortIteration ? 3 + 2 + 1 : 6 + 5 + 4 + 3 + 2 + 1;
	float A[noPara]; float b; float depthWeight = 1.0f;

	bool isValidPoint = false;

	if (x < viewImageSize.x && y < viewImageSize.y)
	{
		isValidPoint = computePerPointGH_exDepth_Ab<shortIteration, rotationOnly, useWeights>(A, b, x, y, depth[x + y * viewImageSize.x], depthWeight,
			viewImageSize, viewIntrinsics, sceneImageSize, sceneIntrinsics, approxInvPose, scenePose, pointsMap, normalsMap, spaceThresh,
			viewFrustum_min, viewFrustum_max, tukeyCutOff, framesToSkip, framesToWeight);

		if (isValidPoint) should_prefix = true;
	}

	if (!isValidPoint) {
		for (int i = 0; i < noPara; i++) A[i] = 0.0f;
		b = 0.0f;
	}

	__syncthreads();

	if (!should_prefix) return;

	{ //reduction for noValidPoints
		dim_shared1[locId_local] = isValidPoint;
		__syncthreads();

		if (locId_local < 128) dim_shared1[locId_local] += dim_shared1[locId_local + 128];
		__syncthreads();
		if (locId_local < 64) dim_shared1[locId_local] += dim_shared1[locId_local + 64];
		__syncthreads();

		if (locId_local < 32) warpReduce(dim_shared1, locId_local);

		if (locId_local == 0) atomicAdd(&(accu->numPoints), (int)dim_shared1[locId_local]);
	}

	__syncthreads();

	{ //reduction for energy function value
		dim_shared1[locId_local] = rho(b, spaceThresh) * depthWeight;
		__syncthreads();

		if (locId_local < 128) dim_shared1[locId_local] += dim_shared1[locId_local + 128];
		__syncthreads();
		if (locId_local < 64) dim_shared1[locId_local] += dim_shared1[locId_local + 64];
		__syncthreads();

		if (locId_local < 32) warpReduce(dim_shared1, locId_local);

		if (locId_local == 0) atomicAdd(&(accu->f), dim_shared1[locId_local]);
	}

	__syncthreads();

	//reduction for nabla
	for (unsigned char paraId = 0; paraId < noPara; paraId+=3)
	{
		dim_shared1[locId_local] = rho_deriv(b, spaceThresh) * depthWeight * A[paraId + 0];
		dim_shared2[locId_local] = rho_deriv(b, spaceThresh) * depthWeight * A[paraId + 1];
		dim_shared3[locId_local] = rho_deriv(b, spaceThresh) * depthWeight * A[paraId + 2];
		__syncthreads();

		if (locId_local < 128) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 128];
			dim_shared2[locId_local] += dim_shared2[locId_local + 128];
			dim_shared3[locId_local] += dim_shared3[locId_local + 128];
		}
		__syncthreads();
		if (locId_local < 64) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 64];
			dim_shared2[locId_local] += dim_shared2[locId_local + 64];
			dim_shared3[locId_local] += dim_shared3[locId_local + 64];
		}
		__syncthreads();

		if (locId_local < 32) {
			warpReduce(dim_shared1, locId_local);
			warpReduce(dim_shared2, locId_local);
			warpReduce(dim_shared3, locId_local);
		}
		__syncthreads();

		if (locId_local == 0) {
			atomicAdd(&(accu->g[paraId+0]), dim_shared1[0]);
			atomicAdd(&(accu->g[paraId+1]), dim_shared2[0]);
			atomicAdd(&(accu->g[paraId+2]), dim_shared3[0]);
		}
	}

	__syncthreads();

	float localHessian[noParaSQ];
#if (defined(__CUDACC__) && defined(__CUDA_ARCH__)) || (defined(__METALC__))
#pragma unroll
#endif
	for (unsigned char r = 0, counter = 0; r < noPara; r++)
	{
#if (defined(__CUDACC__) && defined(__CUDA_ARCH__)) || (defined(__METALC__))
#pragma unroll
#endif
		for (int c = 0; c <= r; c++, counter++) localHessian[counter] = rho_deriv2(b, spaceThresh) * depthWeight * A[r] * A[c];
	}

	//reduction for hessian
	for (unsigned char paraId = 0; paraId < noParaSQ; paraId+=3)
	{
		dim_shared1[locId_local] = localHessian[paraId+0];
		dim_shared2[locId_local] = localHessian[paraId+1];
		dim_shared3[locId_local] = localHessian[paraId+2];
		__syncthreads();

		if (locId_local < 128) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 128];
			dim_shared2[locId_local] += dim_shared2[locId_local + 128];
			dim_shared3[locId_local] += dim_shared3[locId_local + 128];
		}
		__syncthreads();
		if (locId_local < 64) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 64];
			dim_shared2[locId_local] += dim_shared2[locId_local + 64];
			dim_shared3[locId_local] += dim_shared3[locId_local + 64];
		}
		__syncthreads();

		if (locId_local < 32) {
			warpReduce(dim_shared1, locId_local);
			warpReduce(dim_shared2, locId_local);
			warpReduce(dim_shared3, locId_local);
		}
		__syncthreads();

		if (locId_local == 0) {
			atomicAdd(&(accu->h[paraId+0]), dim_shared1[0]);
			atomicAdd(&(accu->h[paraId+1]), dim_shared2[0]);
			atomicAdd(&(accu->h[paraId+2]), dim_shared3[0]);
		}
	}
}

template<bool shortIteration, bool rotationOnly, bool useWeights>
__device__ void exRGBTrackerOneLevel_g_rt_device_main(ITMExtendedTracker_CUDA::AccuCell *accu,
	Vector4f *locations, Vector4f *rgb_model, Vector4s *gx, Vector4s *gy, Vector4u *rgb,
	Matrix4f approxPose, Matrix4f approxInvPose, Matrix4f scenePose, Vector4f projParams, Vector2i imgSize, Vector2i sceneSize)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x, y = threadIdx.y + blockIdx.y * blockDim.y;

	int locId_local = threadIdx.x + threadIdx.y * blockDim.x;

	__shared__ float dim_shared1[256];
	__shared__ float dim_shared2[256];
	__shared__ float dim_shared3[256];
	__shared__ bool should_prefix;

	should_prefix = false;
	__syncthreads();

	const int noPara = shortIteration ? 3 : 6;
	const int noParaSQ = shortIteration ? 3 + 2 + 1 : 6 + 5 + 4 + 3 + 2 + 1;
	float localHessian[noParaSQ];
	float A[noPara];
	float b;

	bool isValidPoint = false;

	if (x < sceneSize.x && y < sceneSize.y)
	{
		// FIXME Translation only not implemented yet
		if(!shortIteration || rotationOnly)
		{
			isValidPoint = computePerPointGH_exRGB_Ab(A, b, localHessian, locations[x + y * sceneSize.x], rgb_model[x + y * sceneSize.x], rgb, imgSize, x, y,
					projParams, approxPose, approxInvPose, scenePose, gx, gy, noPara);
		}

		if (isValidPoint) should_prefix = true;
	}

	if (!isValidPoint)
	{
		for (int i = 0; i < noParaSQ; i++) localHessian[i] = 0.0f;
		for (int i = 0; i < noPara; i++) A[i] = 0.0f;
		b = 0.0f;
	}

	__syncthreads();

	if (!should_prefix) return;

	{ //reduction for noValidPoints
		dim_shared1[locId_local] = isValidPoint;
		__syncthreads();

		if (locId_local < 128) dim_shared1[locId_local] += dim_shared1[locId_local + 128];
		__syncthreads();

		if (locId_local < 64) dim_shared1[locId_local] += dim_shared1[locId_local + 64];
		__syncthreads();

		if (locId_local < 32) warpReduce(dim_shared1, locId_local);

		if (locId_local == 0) atomicAdd(&(accu->numPoints), (int)dim_shared1[locId_local]);
	}

	__syncthreads();

	{ //reduction for energy function value
		dim_shared1[locId_local] = b;
		__syncthreads();

		if (locId_local < 128) dim_shared1[locId_local] += dim_shared1[locId_local + 128];
		__syncthreads();
		if (locId_local < 64) dim_shared1[locId_local] += dim_shared1[locId_local + 64];
		__syncthreads();

		if (locId_local < 32) warpReduce(dim_shared1, locId_local);

		if (locId_local == 0) atomicAdd(&(accu->f), dim_shared1[locId_local]);
	}

	__syncthreads();

	//reduction for nabla
	for (unsigned char paraId = 0; paraId < noPara; paraId += 3)
	{
		dim_shared1[locId_local] = A[paraId + 0];
		dim_shared2[locId_local] = A[paraId + 1];
		dim_shared3[locId_local] = A[paraId + 2];
		__syncthreads();

		if (locId_local < 128) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 128];
			dim_shared2[locId_local] += dim_shared2[locId_local + 128];
			dim_shared3[locId_local] += dim_shared3[locId_local + 128];
		}
		__syncthreads();
		if (locId_local < 64) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 64];
			dim_shared2[locId_local] += dim_shared2[locId_local + 64];
			dim_shared3[locId_local] += dim_shared3[locId_local + 64];
		}
		__syncthreads();

		if (locId_local < 32) {
			warpReduce(dim_shared1, locId_local);
			warpReduce(dim_shared2, locId_local);
			warpReduce(dim_shared3, locId_local);
		}
		__syncthreads();

		if (locId_local == 0) {
			atomicAdd(&(accu->g[paraId + 0]), dim_shared1[0]);
			atomicAdd(&(accu->g[paraId + 1]), dim_shared2[0]);
			atomicAdd(&(accu->g[paraId + 2]), dim_shared3[0]);
		}
	}

	__syncthreads();

	//reduction for hessian
	for (unsigned char paraId = 0; paraId < noParaSQ; paraId += 3)
	{
		dim_shared1[locId_local] = localHessian[paraId + 0];
		dim_shared2[locId_local] = localHessian[paraId + 1];
		dim_shared3[locId_local] = localHessian[paraId + 2];
		__syncthreads();

		if (locId_local < 128) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 128];
			dim_shared2[locId_local] += dim_shared2[locId_local + 128];
			dim_shared3[locId_local] += dim_shared3[locId_local + 128];
		}
		__syncthreads();
		if (locId_local < 64) {
			dim_shared1[locId_local] += dim_shared1[locId_local + 64];
			dim_shared2[locId_local] += dim_shared2[locId_local + 64];
			dim_shared3[locId_local] += dim_shared3[locId_local + 64];
		}
		__syncthreads();

		if (locId_local < 32) {
			warpReduce(dim_shared1, locId_local);
			warpReduce(dim_shared2, locId_local);
			warpReduce(dim_shared3, locId_local);
		}
		__syncthreads();

		if (locId_local == 0) {
			atomicAdd(&(accu->h[paraId + 0]), dim_shared1[0]);
			atomicAdd(&(accu->h[paraId + 1]), dim_shared2[0]);
			atomicAdd(&(accu->h[paraId + 2]), dim_shared3[0]);
		}
	}
}

template<bool shortIteration, bool rotationOnly, bool useWeights>
__global__ void exDepthTrackerOneLevel_g_rt_device(ITMExtendedTracker_KernelParameters_Depth para)
{
	exDepthTrackerOneLevel_g_rt_device_main<shortIteration, rotationOnly, useWeights>(para.accu, para.depth,
		para.approxInvPose, para.pointsMap, para.normalsMap, para.sceneIntrinsics, para.sceneImageSize, para.scenePose,
		para.viewIntrinsics, para.viewImageSize, para.spaceThresh, para.viewFrustum_min, para.viewFrustum_max,
		para.tukeyCutOff, para.framesToSkip, para.framesToWeight);
}

template<bool shortIteration, bool rotationOnly, bool useWeights>
__global__ void exRGBTrackerOneLevel_g_rt_device(ITMExtendedTracker_KernelParameters_RGB para)
{
	exRGBTrackerOneLevel_g_rt_device_main<shortIteration, rotationOnly, useWeights>(para.accu, para.pointsMap,
		para.rgb_model, para.gx, para.gy, para.rgb_live, para.approxPose, para.approxInvPose, para.scenePose, para.projParams, para.viewImageSize, para.sceneImageSize);
}

__global__ void exRGBTrackerProjectPrevImage_device(Vector4f *out_rgb, Vector4u *in_rgb, Vector4f *in_points, Vector2i imageSize, Vector2i sceneSize, Vector4f intrinsics, Matrix4f scenePose)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;

	projectPreviousPoint_exRGB(x, y, out_rgb, in_rgb, in_points, imageSize, sceneSize, intrinsics, scenePose);
}
