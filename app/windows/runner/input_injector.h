// Synthetic input injection for the RemoteDesk *target* side (M2).
//
// The controller sends pointer positions normalised to [0,1] of the video
// picture; this is the only place those become screen coordinates. That has to
// happen natively because Windows reports a *virtual* desktop that can start at
// a negative offset and span monitors with different scale factors — geometry
// Dart cannot see through MediaQuery.
//
// Registration is explicit (see RegisterInputInjector) rather than a plugin, so
// the runner owns the channel lifetime and there is no pubspec-level plugin to
// keep in sync.

#ifndef RUNNER_INPUT_INJECTOR_H_
#define RUNNER_INPUT_INJECTOR_H_

#include <flutter/binary_messenger.h>

namespace remotedesk {

// Registers the `remotedesk/input` method channel on the given messenger.
// Safe to call once per engine; a second call is ignored.
void RegisterInputInjector(flutter::BinaryMessenger* messenger);

}  // namespace remotedesk

#endif  // RUNNER_INPUT_INJECTOR_H_
