// Copyright 2026 Solara. Apache-2.0.

#ifndef SOLARA_CORE_AC_DEVTOOLS_CALL_H_
#define SOLARA_CORE_AC_DEVTOOLS_CALL_H_

#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/time/time.h"
#include "base/values.h"

namespace content {
class WebContents;
}

namespace solaracore {

using DevToolsReply = base::OnceCallback<void(std::optional<base::DictValue> result,
                                              std::optional<std::string> error)>;
void CallDevTools(content::WebContents* contents,
                  const std::string& method,
                  base::DictValue params,
                  std::optional<base::TimeDelta> timeout,
                  DevToolsReply reply);

}

#endif
