// Copyright 2016 Isis Innovation Limited and the authors of InfiniTAM

#include "ITMFileBasedTracker.h"

#include <cstdio>
#include <fstream>

namespace ITMLib {
ITMFileBasedTracker::ITMFileBasedTracker(const std::string &poseMask_) :
		poseMask(poseMask_),
		frameCount(0)
{}

ITMFileBasedTracker::~ITMFileBasedTracker() {}

void ITMFileBasedTracker::TrackCamera(ITMTrackingState *trackingState, const ITMView *view)
{
	// Fill the mask
	static const int BUF_SIZE = 2048; // Same as InputSource
	char framePoseFilename[BUF_SIZE];
	sprintf(framePoseFilename, poseMask.c_str(), frameCount);

	// Always increment frameCount, this allows skipping missing files that could correspond
	// to frames where tracking failed during capture.
	++frameCount;

	trackingState->trackerResult = ITMTrackingState::TRACKING_FAILED;

	// Try to open the file
	std::ifstream poseFile(framePoseFilename);

	// File not found, signal tracking failure.
	if (!poseFile)
	{
		return;
	}

	Matrix4f invPose;

	// Matrix is column-major
	poseFile >> invPose.m00 >> invPose.m10 >> invPose.m20 >> invPose.m30;
	poseFile >> invPose.m01 >> invPose.m11 >> invPose.m21 >> invPose.m31;
	poseFile >> invPose.m02 >> invPose.m12 >> invPose.m22 >> invPose.m32;
	poseFile >> invPose.m03 >> invPose.m13 >> invPose.m23 >> invPose.m33;

	if (!poseFile.fail())
	{
		// No read errors, tracking is assumed good
		trackingState->trackerResult = ITMTrackingState::TRACKING_GOOD;
		trackingState->pose_d->SetInvM(invPose);
	}
}
}
