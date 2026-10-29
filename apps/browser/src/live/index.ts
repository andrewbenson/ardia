import { startLiveEngine } from "./engine";
import { startGoogleAuth } from "./googleAuth";
import { startMeetingGroups } from "./meetingGroups";

export function startLive() {
  startGoogleAuth();
  startLiveEngine();
  startMeetingGroups();
}
