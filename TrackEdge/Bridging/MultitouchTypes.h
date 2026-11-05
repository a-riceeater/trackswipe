//
//  MultitouchTypes.h
//  TrackEdge
//
//  Memory layout of the per-contact record delivered by Apple's PRIVATE
//  MultitouchSupport.framework contact-frame callback. The framework is not
//  linked; its symbols are resolved at runtime with dlopen/dlsym in
//  MultitouchBridge.swift, so a missing or changed framework degrades to an
//  "Unavailable" status instead of a launch crash.
//
//  The layout below matches the long-standing, community-documented
//  structure (see OpenMultitouchSupport, Apache-2.0) and is verified at
//  runtime against an expected stride of 96 bytes.
//

#ifndef MultitouchTypes_h
#define MultitouchTypes_h

#include <stdint.h>

typedef struct {
    float x;
    float y;
} TEMTPoint;

typedef struct {
    TEMTPoint position;
    TEMTPoint velocity;
} TEMTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;          // stable per-contact identifier while touching
    int32_t state;              // TEMTTouchState
    int32_t fingerID;
    int32_t handID;
    TEMTVector normalizedVector; // position in 0...1, origin bottom-left (verified with the Touch Inspector)
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    TEMTVector absoluteVector;   // millimetres
    int32_t field14;
    int32_t field15;
    float zDensity;
} TEMTTouch;

typedef enum {
    TEMTTouchStateNotTracking = 0,
    TEMTTouchStateStartInRange = 1,
    TEMTTouchStateHoverInRange = 2,
    TEMTTouchStateMakeTouch = 3,
    TEMTTouchStateTouching = 4,
    TEMTTouchStateBreakTouch = 5,
    TEMTTouchStateLingerInRange = 6,
    TEMTTouchStateOutOfRange = 7
} TEMTTouchState;

#endif /* MultitouchTypes_h */
