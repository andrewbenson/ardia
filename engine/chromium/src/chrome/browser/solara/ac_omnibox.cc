// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/ac_omnibox.h"

#include "base/values.h"

AC_ENGINE_CALL(ac_omnibox_opened) {
  solara::Call call(profile_dir, args_json, reply, context);
  if (!call) {
    return;
  }
  call.TakeReply().Send(base::DictValue().Set("prewarm", 2));
}
